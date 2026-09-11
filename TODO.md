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

- [ ] **Flip the certificate from staging to production.** Only after a
      `letsencrypt-staging` cert has issued cleanly. Change the annotation in
      `clusters/prod/traefik.yaml` to `letsencrypt-prod`, then delete the
      staging secret so a fresh one is requested:
      ```sh
      kubectl -n traefik delete secret vaullet-dev-tls
      ```
      Let's Encrypt production allows 5 duplicate certs per week. Do not flip
      this to debug a problem.

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
