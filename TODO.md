# TODO

Deferred deliberately, not forgotten. Ordered by when it starts to matter.

## Before calling the cluster done

- [ ] **Rotate the Argo CD admin password, then delete the bootstrap secret.**
      `02-argocd.sh` prints an initial password on first run; it stays in the
      cluster as a Secret afterwards, and in whatever terminal scrollback or
      transcript it was printed into. Log in, set a real password, then:
      ```sh
      kubectl -n argocd delete secret argocd-initial-admin-secret
      ```
      Not urgent — Argo is only reachable through an SSH tunnel, port 6443 and
      the UI are both closed at the firewall. It is the kind of thing that is
      still sitting there in six months.

- [x] ~~Flip the certificate from staging to production.~~ Done 2026-09-11.
      `vaullet-dev-tls-4`, issuer `letsencrypt-prod`, SANs `vaullet.dev` and
      `www.vaullet.dev`, verified from outside with a clean chain.
      Lesson worth keeping: **`root` is the only app that reads git.**
      Refreshing the `traefik` app just re-pulls Helm chart 41.5.0 and finds
      nothing changed, because the annotation lives in the Application CR that
      `root` owns. Refresh `root`, not the leaf.

- [ ] **Untrack `.idea/`.** Six files are on `main`; `git add .` ran before the
      `.gitignore` existed, and a `.gitignore` does not untrack what is already
      committed.
      ```sh
      git rm -r --cached .idea && git commit -m "Untrack .idea" && git push
      ```

- [ ] **Delete the stale `../wallet-gitops/` directory.** It holds the
      pre-move copies of every manifest in this repo. Two sources of truth for
      the same files is how a fix gets applied to the wrong one.

## Once the stack is verified

- [ ] **Enable the RKE2 CIS profile.** Deliberately off at bootstrap because it
      enforces restricted PodSecurity cluster-wide and default-deny
      NetworkPolicies, which breaks Traefik, cert-manager and Argo on day one.
      The `etcd` user prerequisite is already done by `01-rke2.sh`.
      ```sh
      cp /usr/local/share/rke2/rke2-cis-sysctl.conf /etc/sysctl.d/60-rke2-cis.conf
      systemctl restart systemd-sysctl
      echo 'profile: "cis"' >> /etc/rancher/rke2/config.yaml
      systemctl restart rke2-server
      ```
      Budget time afterwards for PodSecurity labels and NetworkPolicies on every
      namespace we add.

- [ ] **Raise the DNS TTL.** Currently 300s at Spaceship, kept low so a mistake
      costs five minutes. Once the address is stable, put it back to an hour.

- [ ] **Prove an etcd restore, don't assume it.** RKE2 takes scheduled etcd
      snapshots. A snapshot nobody has ever restored is not a backup. Do the
      drill once and write down how long it took.

## Known rough edges

- [ ] **The request split is manifest-correct but has never actually run.** The
      `web` Rollout now weights `web-stable` / `web-canary` on the HTTPRoute
      through the Gateway API plugin. Two things are unproven on this cluster:
      that the plugin loads at all, and that Traefik honours `weight: 0` on a
      backendRef the way Gateway API specifies (no traffic; an all-zero rule is a
      503). Check on the first canary, while it sits at the pause:
      ```sh
      kubectl -n argo-rollouts logs deploy/argo-rollouts | grep -i gatewayapi
      kubectl -n web get httproute web \
        -o jsonpath='{.spec.rules[0].backendRefs[*].weight}{"\n"}'   # expect 50 50
      # then, with this streaming, curl the site ~20 times and watch the split
      kubectl -n web logs -l app=web --prefix --tail=0 -f
      ```
      If the weights never change, the plugin is missing and the canary silently
      degraded to a pod-count split — the failure mode to recognise, because
      everything else still reports Healthy.

- [ ] **`hello-nginx-conf` is not hash-suffixed.** It is a plain ConfigMap
      inside `apps/hello/deployment.yaml`, not part of the
      `configMapGenerator`, so editing the nginx config will *not* roll the
      Deployment the way editing `index.html` does. Fold it into the generator
      or expect a stale pod.

- [ ] **`apps/hello/redirect.yaml` is the first thing to delete** if a
      certificate ever hangs in a challenge loop. A catch-all `:80` redirect is
      the classic way to break HTTP-01. Gateway API precedence should rank
      cert-manager's exact-path solver route above it, but verify rather than
      trust that when debugging.

## Deferred by decision, 2026-09-11

- [ ] **Cluster topology: revisit when the first stateful service lands.**
      Reviewed at 8% CPU / 3% memory actual usage, where nearly all consumption
      is the control plane running itself. Adding worker nodes was rejected:
      capacity is not the constraint, and workers leave `etcd members: 1`
      untouched, so they buy no resilience at all.

      The thing that is genuinely weak is quorum of one and
      `PodDisruptionBudgets defined: 0`. Fixing that means **three RKE2 server
      VMs on this box via libvirt** — the original T630 design, at no extra
      cost — not more machines. Capacity fits: 3 x 4 vCPU / 16 GiB = 48 GiB,
      leaving ~14 GiB for the host. What does not fit is the second 24 GiB
      stage cluster, and this box has half the T630's cores.

      Revisit at the first stateful service, because that is when RF=3, PDBs
      and live drains stop being decoration.

- [ ] **`local-path` is node-local.** Invisible on one node. The moment a
      second node exists, a rescheduled pod cannot reach its volume. Decide
      then between node affinity for stateful workloads or real replicated
      storage — Longhorn on a single node is theatre, so it only becomes a real
      option alongside the topology decision above.

## Planned subdomains

Decided 2026-09-11. `argo.vaullet.dev` ships now; `devops.vaullet.dev` is
reserved and deliberately not wired up yet.

| Host | Serves | Status |
|---|---|---|
| `vaullet.dev`, `www` | the app | live |
| `argo.vaullet.dev` | Argo CD | ready to push |
| `devops.vaullet.dev` | Argo Rollouts UI | **blocked — see below** |

- [ ] **Put an authenticating proxy in front of the Rollouts UI before exposing
      it.** The dashboard cannot go on a subdomain as it stands:
      **CVE-2026-82277 (CVSS 9.8, 2026-08-28)** — through v1.10.0 it binds all
      interfaces and serves `PromoteRollout`, `AbortRollout` and
      `SetRolloutImage` with no authentication, no authorization and no CSRF
      protection. `SetRolloutImage` means anyone who loads the page runs an
      arbitrary container in this cluster. Upstream guidance is explicit: do not
      expose it via a LoadBalancer Service or public Ingress.

      Two ways forward, in order of preference:
      1. **oauth2-proxy in front of it**, GitHub OAuth restricted to the
         `vaullet-dev` org, with the HTTPRoute pointing at the proxy rather than
         the dashboard. The dashboard Service stays ClusterIP.
      2. **Wait for a fixed release** and re-check the CVE status first — but
         still put auth in front, because even patched it has no user model.

      Until then the promote/abort/retry buttons live in the Argo CD UI via its
      built-in Rollout resource actions, which is the same functionality behind
      real authentication.

## Architecture, not operations

- [ ] **ADR-010's nightly CI matrix probably no longer fits.** The reasoning
      behind it assumed a 12c/24t, 96 GB box where CI was effectively free. The
      AX41 is 6c/12t with 64 GB and is now also carrying prod. Nine k3d configs
      plus 14 Java repos with Testcontainers against that, on the same machine
      serving the demo, needs re-costing rather than re-asserting.

- [ ] **Say "production topology, not production grade" in the README of the
      public-facing repos too.** One node, one PSU, one board, one etcd member.
      The three-VM prod cluster that made etcd quorum, Kafka RF=3 and live node
      drains *real* does not exist on this box. Better a reviewer reads it from
      you than discovers it.
