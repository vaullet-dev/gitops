# gitops

The whole cluster, as git. Three scripts run once on the box; everything after
that is a commit here and Argo CD converges it.

Target: one Hetzner AX41 (Ryzen 5 3600, 64 GB ECC, 2x512 GB NVMe), Ubuntu 26.04
LTS, single-node RKE2. **Production topology, not production grade** — one PSU,
one board, one node. That is deliberate and it is stated rather than hidden.

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

`00-host.sh` refuses to run if `/root/.ssh/authorized_keys` has no key in it,
because its next act is to switch password auth off. **Open a second SSH session
and confirm it works before closing the first one.**

## Sync waves

Argo waits for each wave to go Healthy before starting the next.

```
-2  crds          Gateway API CRDs (traefik-crds chart, standard channel)
-1  cert-manager  with config.gatewayAPI.enabled -- see below
 0  traefik       GatewayClass + the shared Gateway "vaullet"
 1  cluster-issuers  letsencrypt-staging / -prod, http01 via gatewayHTTPRoute
 2  hello         the walking skeleton
```

The wave -1/0 order matters and is not cosmetic. cert-manager's gateway-shim
reacts to the `cert-manager.io/cluster-issuer` annotation on the Gateway that
Traefik creates in wave 0. A cert-manager that came up *without*
`config.gatewayAPI.enabled` ignores that annotation **silently** — no event, no
error, no Certificate, nothing in the logs to tell you why.

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

Nothing administrative is exposed. The Kubernetes API (6443) and the Argo CD and
Traefik dashboards are all closed at the firewall; reach them over SSH.

```sh
# Argo CD
ssh -L 8080:localhost:8080 root@<IP> \
  'KUBECONFIG=/etc/rancher/rke2/rke2.yaml kubectl -n argocd port-forward --address 0.0.0.0 svc/argocd-server 8080:443'

# Traefik dashboard
ssh -L 9000:localhost:9000 root@<IP> \
  'KUBECONFIG=/etc/rancher/rke2/rke2.yaml kubectl -n traefik port-forward --address 0.0.0.0 deploy/traefik 9000:8080'
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
