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

## OpenBao

- [x] ~~First bring-up.~~ Done 2026-09-14: initialised, unsealed, configured.

- [x] ~~Prove the seal once.~~ Done 2026-09-14: pod deleted, came back
      sealed, unsealed again.

- [ ] **Back it up off the box.** Losing OpenBao's volume loses every
      credential. The chart ships a snapshot CronJob (`snapshotAgent`), but it
      needs an S3 target, and Hetzner Object Storage is a new paid service.
      Decide on it before the first real credential is stored. An etcd snapshot
      is not a substitute: it holds the Secrets ESO copied, not OpenBao.

- [ ] **Certificate renewal, around August 2027.** cert-manager renews
      `openbao-tls` 30 days before expiry, but OpenBao only reads the cert at
      start and on SIGHUP. After the renewal:
      ```sh
      kubectl -n openbao exec openbao-0 -- kill -HUP 1   # dumb-init passes it on
      ```
      Or automate it before then. The failure mode is every ESO sync failing
      on an expired cert while OpenBao itself looks healthy.

- [ ] **Stop using the root token.** `configure` and `onboard` take it today.
      Once there is an admin identity (userpass or GitHub OIDC with a
      narrow policy), revoke the root token and use
      `bao operator generate-root` with the key shares for emergencies only.

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

- [ ] **Sync waves do not wait for child apps to be Healthy.** The README says
      they do. Argo CD removed health assessment of `Application` resources in
      1.8, so `root` applies wave 0 as soon as the wave -1 Application objects
      *exist*, not when cert-manager is running. The cert-manager-before-Traefik
      ordering has held by timing, not by guarantee. The fix is the documented
      `resource.customizations.health.argoproj.io_Application` key in
      `argocd-cm`. When adding it, remember that a sealed `openbao` then reports
      Progressing and **holds every later wave** until someone unseals it. That
      is right for services that need secrets, but not for `web`.

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

- [x] **Cluster topology — DECIDED 2026-09-17, see
      [ADR-015](../architecture/docs/adr/015-cluster-topology-three-servers-on-one-machine.md).**
      The trigger named here was "the first stateful service"; PostgreSQL is it.

      Three RKE2 **server** VMs via libvirt, left schedulable, no worker agents.
      Measured rather than estimated: a control-plane node costs ~2.75 GiB
      (`kube-apiserver` 1187 Mi dominates; etcd is 88 Mi), so the tax is ~11.75
      GiB — **19%**, not the ~40% first guessed — leaving ~51 GiB against a
      ~25 GiB core deployment.

      Not yet executed. The runbook is the next artefact; the ADR deliberately
      contains no commands.

- [ ] **`local-path` is node-local — and ADR-015 makes this live.** With three
      nodes a rescheduled pod can no longer reach its volume. Decided alongside
      the topology: **stateful workloads keep their own per-instance volume and
      stay pinned.** CloudNativePG works this way by design and recommends local
      storage; Kafka behaves the same. **Longhorn is rejected** — replicating
      three ways onto one RAID1 array is write amplification for no durability.

      Still open: anything that expects a volume to follow a pod will break, and
      there is **no `VolumeSnapshotClass`** in this cluster (the snapshot
      controller runs, but `local-path` is not a CSI driver that supports them).
      That removes volume-snapshot backups as an option and forces PostgreSQL's
      PITR onto an object store — the next decision.

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
