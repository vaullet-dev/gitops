# gitops

The whole cluster, as git. Three scripts run once on the box; everything after
that is a commit here and Argo CD converges it.

Target: one Hetzner AX41 (Ryzen 5 3600, 64 GB ECC, 2x512 GB NVMe), Ubuntu 26.04
LTS, single-node RKE2. **Production topology, not production grade** — one PSU,
one board, one node. That is deliberate and it is stated rather than hidden.

**Moving to three RKE2 server VMs on this same box**, decided 2026-09-17 in
[ADR-015](../architecture/docs/adr/015-cluster-topology-three-servers-on-one-machine.md)
and not yet executed. That buys etcd quorum, working PodDisruptionBudgets, live
drains and Kafka RF=3. It buys **no** hardware resilience: three VMs still share
one PSU, one board and one disk array, so the line above stays true — and
becomes more accurate rather than less.

## Why RKE2, not k3s

etcd is the datastore with no flag to forget, the control plane runs as static
pods, and SUSE positions RKE2 for production datacenter use where k3s is aimed
at edge, IoT and CI. A single-server k3s defaults to **SQLite** — fine for a
demo, hard to defend as the control plane of a ledger, and with no path to HA
without rebuilding.

On one box neither distribution gives high availability: same kernel, same disk
array, same PSU. The difference RKE2 buys here is durability of cluster state,
hardened defaults, and the option of `profile: "cis"` once the stack is up.

`profile: "cis"` is deliberately **not** enabled at bootstrap. It enforces
restricted PodSecurity cluster-wide and default-deny NetworkPolicies, which
breaks Traefik, cert-manager and Argo on day one. The prerequisites (the `etcd`
system user) are done by `01-rke2.sh`; enabling it is four lines, printed at the
end of that script.

## Routing: Gateway API only

There is no `Ingress` object in this cluster and no `IngressClass`. Upstream
Kubernetes retired `ingress-nginx` in March 2026 — no releases, no bugfixes, no
CVE patches — and its intended successor InGate was abandoned. Traefik is the
Gateway API implementation; routes are `HTTPRoute`, attached to one shared
`Gateway` in the `traefik` namespace.

## Order of operations

| Step | What | Idempotent |
|---|---|---|
| `bootstrap/00-host.sh` | ufw, fail2ban, keys-only SSH, unattended security updates | yes |
| DNS | `A` record for `vaullet.dev` and `www` at the AX41's IPv4 | — |
| `bootstrap/01-rke2.sh` | RKE2 v1.36.4+rke2r1, bundled ingress disabled, servicelb enabled | yes |
| `bootstrap/02-argocd.sh` | Argo CD v3.5.2 + the root app | yes |
| everything else | commits to this repo | — |
| `bootstrap/03-openbao.sh` | after Argo has synced OpenBao: `init` once, `unseal`, `configure` | all but `init` |

`00-host.sh` refuses to run if `/root/.ssh/authorized_keys` has no key in it,
because its next act is to switch password auth off. **Open a second SSH session
and confirm it works before closing the first one.**

## Storage

RKE2 ships **no storage provisioner** — unlike k3s, which bundles
local-path-provisioner. A fresh RKE2 cluster has zero StorageClasses, and every
PVC sits `Pending` forever with nothing useful in its events. `local-path` is
installed explicitly in wave -1 and marked the cluster default.

Volumes live at `/opt/local-path-provisioner`, on `/`, which is `md2` — a RAID1
mirror across both NVMe drives, so a single disk failure does not lose data.

**It is node-local.** `volumeBindingMode: WaitForFirstConsumer` means a PV is
bound only once a pod is scheduled, and it is then pinned to that node. On one
node this is invisible; [ADR-015](../architecture/docs/adr/015-cluster-topology-three-servers-on-one-machine.md)
makes it visible by moving to three.

The answer chosen there is **per-instance volumes, pinned** — not replicated
storage. CloudNativePG gives each PostgreSQL instance its own volume and
recommends local disks; Kafka behaves the same way. Longhorn was rejected:
replicating three ways onto one RAID1 array multiplies writes without adding
durability, because there is only ever one array underneath.

**There is no `VolumeSnapshotClass`.** `rke2-snapshot-controller` runs, but
`local-path` is not a CSI driver that supports snapshots, so `kubectl get
volumesnapshotclass` returns nothing. Anything planning to back up by snapshot —
CloudNativePG can — has to use an object store here instead.

## Project groups

Applications are split across three Argo `AppProject`s rather than the built-in
`default`, which permits any repo to deploy any kind into any namespace. They are
also how the Argo CD UI groups the applications: pick one under *Projects* in the
left panel, and the filter goes into the URL (`/applications?proj=infra`).

| Project | Holds | May create cluster-scoped objects |
|---|---|---|
| `infra` | crds, cert-manager, traefik, local-path-provisioner, external-secrets, cloudnative-pg, argo-rollouts, argocd | yes — CRDs, ClusterIssuers, GatewayClass, StorageClass |
| `platform` | openbao, openbao-ui, secret-stores, postgres, keycloak, keycloak-config, pgadmin | yes, for now — ClusterSecretStores, the charts' cluster RBAC |
| `apps` | web, wallet-auth, wallet-ledger, wallet-transaction, and every `wallet-*` service to come | **no**, except `Namespace` |

`apps` (called `services` until 2026-09-30) is also restricted by source (`github.com/vaullet-dev/*`) and by
destination namespace (`web`, `wallet-*`), so a service cannot deploy into
`kube-system` or `traefik` even by accident.

`root` deliberately stays in `default`: it is applied by hand at bootstrap,
before any AppProject exists, so it cannot depend on one.

## Progressive delivery

`web` is a `Rollout` with a **blue-green** strategy. A new image starts a full
second set of pods. When all of them are Ready, the controller switches the
`web` Service to them in one step, and removes the old pods 30 seconds later.
Every visitor sees one version, and there is no manual Promote.

It was a 50% canary that paused for Promote. The pause was never clicked, so
the site served old and new content side by side. Canary stays the right tool
for services where a bad version can be measured on part of the traffic. For a
presentation page it only produced inconsistency.

The Gateway API traffic-router plugin is still installed in
`clusters/prod/argo-rollouts.yaml`, for a future canary on a real service. No
Rollout uses it today.

With GitOps, the actions differ in whether they survive `selfHeal`:

| Action | Works with `selfHeal: true`? | Why |
|---|---|---|
| Promote / Abort / Retry | **yes** | acts on an in-flight rollout, changes no spec |
| Rollback to revision N | no | edits the spec; Argo drift-corrects it back within ~3 min |

A permanent rollback is `git revert` of the deploy commit.

## Sync waves

Argo waits for each wave to go Healthy before starting the next.

```
-3  projects      AppProjects -- must exist before any Application names one
-2  crds          Gateway API CRDs (traefik-crds chart, standard channel)
-1  cert-manager  with config.gatewayAPI.enabled -- see below
-1  local-path-provisioner  the cluster's only StorageClass, and its default
-1  argo-rollouts           progressive delivery (dashboard off: CVE-2026-82277)
-1  external-secrets        copies OpenBao values into Kubernetes Secrets
 0  traefik       GatewayClass + the shared Gateway "vaullet"
 0  openbao       credential store; sealed until bootstrap/03-openbao.sh
 1  cluster-issuers  letsencrypt-staging / -prod, http01 via gatewayHTTPRoute
 2  web           the public site, from the vaullet-dev/web repo (blue-green)
```

The wave -1/0 order matters and is not cosmetic. cert-manager's gateway-shim
reacts to the `cert-manager.io/cluster-issuer` annotation on the Gateway that
Traefik creates in wave 0. A cert-manager that came up *without*
`config.gatewayAPI.enabled` ignores that annotation **silently** — no event, no
error, no Certificate, nothing in the logs to tell you why.

## Secrets

OpenBao holds every credential. External Secrets Operator (ESO) copies them into
ordinary Kubernetes Secrets, so a service reads environment variables and has no
OpenBao client. Nothing secret is committed here, not even encrypted.

**The seal.** OpenBao starts sealed and stays sealed until two of its three
unseal keys are entered. There is no cloud KMS on Hetzner to do that
automatically, so after every restart of `openbao-0` (reboot, upgrade, eviction):

```sh
bootstrap/03-openbao.sh unseal
```

Until then `openbao-0` is Running but not Ready. Running services are not
affected: the Secrets ESO already wrote stay in place, and pods restart with
them. Only a *changed* secret waits for the unseal.

Upgrades need the same: the chart's StatefulSet uses `updateStrategy: OnDelete`,
so a new OpenBao version lands only when you delete the pod, and then you unseal.

**The boundary.** Each service namespace reads `kv/<namespace>/*` and nothing
else. Onboarding a service is three things:

1. `bootstrap/03-openbao.sh onboard wallet-ledger` creates the OpenBao policy
   and role, both named after the namespace.
2. The service's own repo ships a ServiceAccount named `secrets-reader` and its
   `ExternalSecret`s.
3. This repo gets a ClusterSecretStore that only the namespaces it names may
   use: the service's own, plus `postgres` when CloudNativePG sets the
   service's database passwords, and `keycloak` when the realm import sets its
   client secret. wallet-ledger's, `apps/secret-stores/wallet-ledger.yaml`,
   says why for each:

```yaml
apiVersion: external-secrets.io/v1
kind: ClusterSecretStore
metadata:
  name: openbao-wallet-ledger
spec:
  conditions:
    - namespaces: [ wallet-ledger, postgres, keycloak ]
  provider:
    vault:                                   # OpenBao speaks the Vault API
      server: https://openbao.openbao.svc:8200
      path: kv
      version: v2
      caProvider:
        type: Secret
        name: openbao-ca
        namespace: openbao
        key: ca.crt
      auth:
        kubernetes:
          mountPath: kubernetes
          role: wallet-ledger
          serviceAccountRef:
            name: secrets-reader
            namespace: wallet-ledger
```

The store is cluster-scoped, and the `apps` project cannot create
cluster-scoped objects. That is on purpose: a service cannot point itself at
another service's secrets. The service's database roles live here too, in
`apps/db/postgres`.

**wallet-ledger** is onboarded exactly this way. Once, before its Application
first syncs (`clusters/prod/wallet-ledger.yaml` has the order, and why it
matters):

```sh
bootstrap/03-openbao.sh onboard wallet-ledger
bao kv put kv/wallet-ledger/db-migrator     password="$(openssl rand -base64 24)"
bao kv put kv/wallet-ledger/db-app          password="$(openssl rand -base64 24)"
bao kv put kv/wallet-ledger/keycloak-client secret="$(openssl rand -base64 32)"
```

The first two are the passwords of `ledger_migrator` and `ledger_app`, the
ledger's roles in `vaullet_db` on the `money` cluster: its Flyway Job and the
running ledger connect with them, and CloudNativePG sets the roles to the same
values. The third is the secret of client `ledger-ops`, which is how a person
gets a token for the ledger (see "Reaching things").

**wallet-transaction** is onboarded the same way, and also before its Application
first syncs (`clusters/prod/wallet-transaction.yaml` has the order):

```sh
bootstrap/03-openbao.sh onboard wallet-transaction
bao kv put kv/wallet-transaction/db-migrator     password="$(openssl rand -base64 24)"
bao kv put kv/wallet-transaction/db-app          password="$(openssl rand -base64 24)"
bao kv put kv/wallet-transaction/keycloak-client secret="$(openssl rand -base64 32)"
```

The first two are the passwords of `transaction_migrator` and `transaction_app`,
its roles in `transactions_db` on the `money` cluster, used and set exactly as the
ledger's are. `transaction_migrator` is a member of `transactions`, the role that
owns `transactions_db`, whose own password is `kv/postgres/transactions`
(`apps/db/postgres/credentials.yaml`). CloudNativePG cannot add a member to a role
that does not exist yet, so `bao kv metadata get kv/postgres/transactions` should
find it first. The third is the secret of client `wallet-transaction-service`.
Unlike `ledger-ops`'s, the service itself authenticates with it: it is how the
service gets the `ledger:reserve` token that holds each debit's money.

**pgadmin** needs no onboarding. It holds no OpenBao secrets: External Secrets generates
its two passwords once, on the first sync, and nothing else connects with them. pgAdmin's
login is `admin@vaullet.dev` with the password from Secret `pgadmin-admin` in `pgadmin`.
pgAdmin reads it only on its first start, so change it in pgAdmin after that. The database
password is `dba_rw`'s, from Secret `dba-rw-db-credentials` in `postgres`. `dba_rw` is the
role pgAdmin connects as on `money`, `platform` and `analytics`. It reads and writes every
table and can do nothing else: no DDL, no roles.

**TLS.** OpenBao serves a certificate from a private CA in its own namespace
(`apps/openbao/tls.yaml`). Clients trust `ca.crt` from the `openbao-tls` Secret.

**Audit.** Every request goes to `openbao-0`'s stdout, declared in the server
config. `kubectl -n openbao logs openbao-0` is the audit trail until logs are
shipped somewhere durable.

## The certificate

Both HTTPS listeners (`vaullet.dev`, `www.vaullet.dev`) reference the same
secret, `vaullet-dev-tls`. cert-manager groups listeners by secret name, so that
is **one** certificate with two SANs, not two certificates.

Issuance starts on **`letsencrypt-staging`**. Let's Encrypt production allows 5
duplicate certificates per week and a broken HTTP-01 loop burns that in an
afternoon, locking the name out for days. Only after a staging cert has issued
cleanly, change the annotation in `clusters/prod/traefik.yaml`:

```yaml
cert-manager.io/cluster-issuer: letsencrypt-prod
```

then delete the staging secret so a fresh one is requested:

```sh
kubectl -n traefik delete secret vaullet-dev-tls
kubectl -n traefik get certificate,certificaterequest,order,challenge
```

The staging cert is signed by a CA no browser trusts. A cert warning at that
stage is the system working, not failing.

## `.dev` is HSTS-preloaded

`vaullet.dev` is on the HSTS preload list baked into browsers. A browser
rewrites `http://vaullet.dev` to `https://` before a packet leaves the machine,
so **you cannot test this over plain HTTP in a browser at all** — and you cannot
click through the staging-CA warning either, because preload disallows the
override. Use `curl` while bootstrapping:

```sh
curl -sv http://vaullet.dev/            # redirect route
curl -sv https://vaullet.dev/ -k        # -k while still on staging
curl -sI https://vaullet.dev/ --resolve vaullet.dev:443:<IP>
```

Let's Encrypt's validation servers do not honour HSTS preload, so the HTTP-01
challenge over port 80 is unaffected.

## IPv4 only

The cluster here is single-stack IPv4. Publish an **`A` record only**. If you also
publish `AAAA`, browsers that prefer IPv6 will reach the AX41's v6 address,
find nothing listening, and the site will look broken for exactly the users
whose networks work best.

## Reaching things

| What | Where | Auth |
|---|---|---|
| The app | `https://vaullet.dev`, `https://www.vaullet.dev` | none, it's a public page |
| Argo CD | `https://argo.vaullet.dev` | Argo CD login |
| Kubernetes API (6443) | closed at the firewall | SSH only |
| Traefik dashboard | not exposed | SSH tunnel |
| OpenBao UI and API | `https://bao.vaullet.dev` | GitHub login (one allowed account, oauth2-proxy), then an OpenBao token |
| The ledger (wallet-ledger-service) | **no route**: ClusterIP `ledger-service` in `wallet-ledger` | SSH tunnel, then a token from client `ledger-ops` |
| Transactions (wallet-transaction-service) | `https://vaullet.dev/api/transactions`, Swagger UI at `/api/transactions/swagger-ui.html` | an end user's token from `swagger-ui` or `bruno` (`transaction:self`); no client holds the operator scopes yet |
| pgAdmin (all three Postgres clusters, read/write) | **no route**: ClusterIP `pgadmin` in `pgadmin` | SSH tunnel, then pgAdmin's login (`admin@vaullet.dev`), then `dba_rw`'s password; both generated, see below |
| Argo Rollouts UI | **not deployed** | see TODO.md |

Argo CD and OpenBao are the only administrative UIs on the internet, and only because they
actually authenticate. Anyone who logs in to Argo CD can change what the cluster runs, so the
admin password matters and SSO is worth it as soon as more than one person needs access.

OpenBao sits behind two locks in series: oauth2-proxy lets through one GitHub account and nothing
else, and OpenBao then asks for its own token. The SSH tunnel below still works and is the
break-glass path, for when GitHub or the proxy is down.

The Argo Rollouts dashboard is **switched off**, not merely unexposed:
CVE-2026-82277 (CVSS 9.8) means it serves `PromoteRollout`, `AbortRollout` and
`SetRolloutImage` with no authentication at all. Promote and abort live in the
Argo CD UI instead, via its built-in Rollout resource actions — same buttons,
behind a login.

```sh
# Traefik dashboard
ssh -L 9000:localhost:9000 root@<IP> \
  'kubectl -n traefik port-forward --address 0.0.0.0 deploy/traefik 9000:8080'

# OpenBao UI at https://localhost:8200/ui. Expect a certificate warning: the
# cert is from the private CA. localhost is not HSTS-preloaded, so you can click through.
ssh -L 8200:localhost:8200 root@<IP> \
  'kubectl -n openbao port-forward svc/openbao 8200:8200'

# The ledger at http://localhost:18081 (18081 is also what the ledger's Bruno
# collection expects). It is not on vaullet.dev at all: ADR-008
# admits service tokens only, from inside the cluster. With the tunnel open, call
# it with a token from client ledger-ops (apps/keycloak-config/realm/27-*), which
# carries ledger:read, ledger:write and ledger:reserve and names the client, not
# you. A token expires in minutes: fetch a new one rather than keeping it.
ssh -L 18081:localhost:18081 root@<IP> \
  'kubectl -n wallet-ledger port-forward svc/ledger-service 18081:80'
TOKEN=$(curl -s https://vaullet.dev/auth/realms/vaullet/protocol/openid-connect/token \
  -d grant_type=client_credentials -d client_id=ledger-ops \
  --data-urlencode client_secret="$(bao kv get -field=secret kv/wallet-ledger/keycloak-client)" \
  | jq -r .access_token)
curl -H "Authorization: Bearer $TOKEN" http://localhost:18081/v1/wallets

# Transactions at https://vaullet.dev/api/transactions, with Swagger UI under it, where
# Authorize signs in through client swagger-ui. Only an end user gets through today: the
# token carries transaction:self, END_USER and the user's account_id, and debits that
# account alone. No client offers transaction:read or transaction:write yet
# (apps/keycloak-config/realm/15-* says why), so a staff token, which names no account, is
# refused. On a demo cluster, test-end-user's token from client bruno, and a 1.00 hold. Until
# money can be deposited, its wallets are empty, so the answer is 409 INSUFFICIENT_FUNDS and
# the transaction is recorded DECLINED; the 201 needs CASH in the ledger first:
TOKEN=$(curl -s https://vaullet.dev/auth/realms/vaullet/protocol/openid-connect/token \
  -d grant_type=password -d client_id=bruno -d username=test-end-user \
  --data-urlencode password="$(bao kv get -field=password kv/keycloak/test-users)" \
  | jq -r .access_token)
curl https://vaullet.dev/api/transactions/v1/transactions \
  -H "Authorization: Bearer $TOKEN" -H "Idempotency-Key: $(uuidgen)" \
  -H 'Content-Type: application/json' -d '{"type": "DEBIT", "amount": "1.00", "currency": "EUR"}'

# pgAdmin at http://localhost:5050. The three clusters are already listed under
# "vaullet". Its rights are table data only, but that includes the money database, so
# close the tunnel when you're done. There is no public db.vaullet.dev on purpose; see TODO.md.
# The login, then dba_rw's password (asked once per server):
ssh vaullet ssh root@192.168.122.11 'export KUBECONFIG=/etc/rancher/rke2/rke2.yaml PATH=$PATH:/var/lib/rancher/rke2/bin
  kubectl -n pgadmin  get secret pgadmin-admin         -o jsonpath="{.data.password}" | base64 -d; echo
  kubectl -n postgres get secret dba-rw-db-credentials -o jsonpath="{.data.password}" | base64 -d; echo'
ssh -L 5050:localhost:5050 vaullet ssh -L 5050:localhost:5050 root@192.168.122.11 \
  'KUBECONFIG=/etc/rancher/rke2/rke2.yaml /var/lib/rancher/rke2/bin/kubectl -n pgadmin port-forward svc/pgadmin 5050:80'

# Anything else: kubeconfig is at /root/.kube/config, so plain `kubectl` works
ssh root@<IP> 'kubectl get pods -A'
```

## When a route does not route

```sh
kubectl -n traefik get gateway vaullet -o wide          # listeners Programmed?
kubectl -n hello   get httproute -o wide                # Accepted + ResolvedRefs?
kubectl -n traefik get certificate,order,challenge
kubectl -n cert-manager logs deploy/cert-manager --tail=100
```

`HTTPRoute` failing to attach is nearly always one of: the Gateway listener's
`allowedRoutes.namespaces.from` is not `All` (routes live in `hello`, the
Gateway in `traefik`), or `sectionName` names a listener that does not exist.

If a certificate hangs in a challenge loop, `apps/hello/redirect.yaml` is the
first thing to delete while diagnosing — a catch-all `:80` redirect is the
classic way to break HTTP-01, even though Gateway API precedence should rank
the solver's exact path match above it.
