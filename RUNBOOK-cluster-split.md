# Runbook — one node to three, on the same machine

Executes [ADR-015](../architecture/docs/adr/015-cluster-topology-three-servers-on-one-machine.md).
One-off. Read it through before starting.

**It is not a migration.** A new three-node cluster is built alongside the running one, verified, and
traffic is moved with two firewall rules. The old cluster keeps serving until the last moment and is
the rollback.

```
now       AX41 ── RKE2 (bare metal)                       serving vaullet.dev
build     AX41 ── RKE2 (bare metal)                       still serving
               └─ libvirt ── k8s-1 / k8s-2 / k8s-3        new cluster, verified on spare ports
cut over  three rules on the host: DNAT :80 :443 → 192.168.122.11,
          a LIBVIRT_FWI accept, and a hairpin MASQUERADE
rollback  delete the two DNAT rules
reclaim   stop rke2-server on the host, grow the VMs
```

## Before anything

| | |
|---|---|
| **Two SSH sessions open.** | Every network step is verified from the *second* one before the first is closed. |
| **Hetzner rescue access confirmed** | If the host's routing breaks, this is the way back. Confirm you can reach it *before* you need it. |
| **~50 GiB free** | Both clusters run at once. VMs are built at **12 GiB**, grown to 16 after the old node is reclaimed. |
| **Nothing valuable in the cluster** | One PVC, OpenBao's 5 Gi holding 236 KB. Confirm that is still true: `kubectl get pvc -A`. |

**The safety pattern, used at every step that touches networking:**

```sh
# arm before the change, cancel after verifying from the second session
systemd-run --on-active=5min --unit=panic-reboot systemctl reboot
#   … make the change, verify from session 2 …
systemctl stop panic-reboot.timer          # cancel
```

If you lose the connection, the box reboots in five minutes into a known-good state, because nothing
here is persisted until the final phase.

---

## Phase 0 — Record the current state

```sh
export KUBECONFIG=/etc/rancher/rke2/rke2.yaml
mkdir -p /root/pre-split && cd /root/pre-split
kubectl get nodes -o wide                          > nodes.txt
kubectl get all -A                                 > all.txt
kubectl get applications -n argocd                 > argo.txt
kubectl get pvc -A                                 > pvc.txt
kubectl get externalsecret,clustersecretstore,secretstore -A > secretstores.txt
kubectl -n traefik get secret vaullet-dev-tls -o yaml > tls.yaml   # needed in Phase 6
chmod 600 tls.yaml                                 # it holds the private key
rke2 etcd-snapshot save --name pre-split

# THE PART THAT IS NOT IN GIT, and the easiest to forget:
cp /etc/rancher/rke2/config.yaml                     rke2-config.yaml
```

`rke2 etcd-snapshot` writes to `/var/lib/rancher/rke2/server/db/snapshots/`. It is insurance for the
*old* cluster, not a migration path — the new cluster starts empty by design.

**Read `rke2-config.yaml` and carry every line of it to the new nodes.** `bootstrap/01-rke2.sh`
writes this file, but the running node may have drifted from it, and nothing reconciles the two.
On the live split the old node carried three settings the new ones were built without:

| Setting | What happens without it |
|---|---|
| `disable: [rke2-traefik, rke2-ingress-nginx, rke2-traefik-crd]` | RKE2's own bundled Traefik runs alongside ours and fights for :80/:443 |
| `enable-servicelb: true` | no `svclb` pods, so the Traefik Service never gets an external address and the DNAT has nothing to reach |
| `write-kubeconfig-mode: "0600"` | the kubeconfig is world-readable |

The first two would each have broken the cutover, and neither is visible from `kubectl`.

`tls.yaml` contains a private key. Never `cat`, `head` or `less` it — check it with `grep -c`,
`wc -c` and `openssl x509 -noout`.

**Rollback:** nothing has changed.

---

## Phase 1 — libvirt

```sh
apt update
apt install -y qemu-kvm libvirt-daemon-system libvirt-clients virtinst \
               cloud-image-utils genisoimage
systemctl enable --now libvirtd
virsh list --all          # expect: empty table, no error
```

**Rollback:** `systemctl disable --now libvirtd && apt purge -y libvirt-daemon-system qemu-kvm`

---

## Phase 2 — Network  ⚠️ the step that can cost you SSH

libvirt ships a predefined NAT network, `default`, on `virbr0` / `192.168.122.0/24`. **Use it as-is.**
It creates its own bridge and its own iptables chains (`LIBVIRT_FWD`, `LIBVIRT_INP`) and **does not
touch `enp41s0`** — which is the entire reason this phase is survivable. Do not be tempted to bridge
onto the public interface: the single IPv4 is routed as a `/32` with an off-subnet gateway, so there
is no address for a bridged guest to take.

```sh
systemd-run --on-active=5min --unit=panic-reboot systemctl reboot   # arm

virsh net-start default
virsh net-autostart default
ip addr show virbr0                      # 192.168.122.1/24
sysctl net.ipv4.ip_forward               # already 1 — RKE2 needs it for pod networking
```

**Verify from the second SSH session** that the host is still reachable, then:

```sh
systemctl stop panic-reboot.timer        # cancel
```

`iptables -L -n | grep -c LIBVIRT` should be non-zero, and canal's rules should be untouched —
libvirt confines itself to its own chains.

**Rollback:** `virsh net-destroy default && virsh net-autostart --disable default`

---

## Phase 3 — Three VMs

Fixed MAC → fixed IP, via libvirt's own dnsmasq. Cleaner than configuring static addresses inside
each guest, and it keeps addressing in one place.

```sh
for i in 1 2 3; do
  virsh net-update default add ip-dhcp-host \
    "<host mac='52:54:00:00:00:0$i' name='k8s-$i' ip='192.168.122.1$i'/>" \
    --live --config
done
```

Base image and per-VM disks. **Backing files keep the three disks thin** — each holds only its own
writes:

```sh
mkdir -p /var/lib/libvirt/images
cd /var/lib/libvirt/images
curl -fsSLO https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img
for i in 1 2 3; do
  qemu-img create -f qcow2 -F qcow2 -b noble-server-cloudimg-amd64.img k8s-$i.qcow2 60G
done
```

cloud-init, one file per VM — SSH key only, no password:

```sh
for i in 1 2 3; do
cat > /var/lib/libvirt/images/ci-k8s-$i.yaml <<EOF
#cloud-config
hostname: k8s-$i
users:
  - name: root
    ssh_authorized_keys: [ "$(cat /root/.ssh/authorized_keys | head -1)" ]
package_update: true
packages: [ curl, nfs-common ]
EOF
done
```

Create them at **12 GiB** for the overlap:

```sh
for i in 1 2 3; do
  virt-install --name k8s-$i --memory 12288 --vcpus 4 \
    --cpu host-passthrough --machine q35 \
    --disk /var/lib/libvirt/images/k8s-$i.qcow2,bus=virtio \
    --network network=default,mac=52:54:00:00:00:0$i,model=virtio \
    --cloud-init user-data=/var/lib/libvirt/images/ci-k8s-$i.yaml \
    --os-variant ubuntu24.04 --graphics none --import --noautoconsole
  virsh autostart k8s-$i
done
virsh list --all
for i in 1 2 3; do ssh -o StrictHostKeyChecking=no root@192.168.122.1$i hostname; done
```

`--cpu host-passthrough` matters: the guests see the real Ryzen feature set, and **etcd is sensitive
to CPU behaviour**. Pin the vCPUs once the cluster is up (Phase 8) so etcd is not competing with the
old node's control plane during the overlap.

**Rollback:** `for i in 1 2 3; do virsh destroy k8s-$i; virsh undefine k8s-$i --remove-all-storage; done`

---

## Phase 4 — RKE2 on three servers

**`k8s-1` first**, alone, so etcd has a cluster to form:

```sh
ssh root@192.168.122.11
mkdir -p /etc/rancher/rke2
cat > /etc/rancher/rke2/config.yaml <<'EOF'
# Reachable as any of these. 192.168.122.11 is what the other servers join on;
# 127.0.0.1 is for kubectl on the box; the host address is for the DNAT later.
tls-san:
  - 192.168.122.11
  - 65.109.58.119
  - k8s-1

# ADR-015 §6. The current bare-metal node reserves NOTHING — allocatable equals
# capacity — so the scheduler will happily place pods claiming the whole machine
# and leave the OOM killer choosing between containerd and etcd.
kubelet-arg:
  - "system-reserved=cpu=200m,memory=1Gi"

# Servers stay schedulable. ADR-015 §1: three servers are three usable nodes,
# not three reserved control planes. Explicit so nobody adds a taint by habit.
node-taint: []
EOF
curl -sfL https://get.rke2.io | sh -
systemctl enable --now rke2-server
```

Wait for it, then take the token:

```sh
export KUBECONFIG=/etc/rancher/rke2/rke2.yaml
export PATH=$PATH:/var/lib/rancher/rke2/bin
kubectl get node                                  # k8s-1 Ready
cat /var/lib/rancher/rke2/server/node-token       # copy this
```

**`k8s-2` and `k8s-3`**, one at a time — let each become Ready before starting the next, so etcd
grows 1 → 2 → 3 rather than racing:

```sh
ssh root@192.168.122.1{2,3}
mkdir -p /etc/rancher/rke2
cat > /etc/rancher/rke2/config.yaml <<'EOF'
server: https://192.168.122.11:9345      # 9345 is RKE2's supervisor port, NOT 6443
token:  <node-token from k8s-1>
tls-san: [ 192.168.122.1X, 65.109.58.119 ]
kubelet-arg: [ "system-reserved=cpu=200m,memory=1Gi" ]
node-taint: []
EOF
curl -sfL https://get.rke2.io | sh -
systemctl enable --now rke2-server
```

**Rollback:** `rke2-uninstall.sh` on each VM, or destroy the VMs.

---

## Phase 5 — Verify the cluster before it gets any traffic

```sh
kubectl get nodes -o wide                         # 3 x Ready, roles control-plane,etcd
kubectl get pods -n kube-system -l component=etcd  # 3 pods
kubectl describe node | grep -A3 "Allocated resources"   # allocatable < capacity now

# the point of the whole exercise:
kubectl get node -o json | jq -r '.items[].metadata.name'   # three names
```

etcd membership, from inside a member:

```sh
kubectl -n kube-system exec etcd-k8s-1 -- etcdctl \
  --cacert=/var/lib/rancher/rke2/server/tls/etcd/server-ca.crt \
  --cert=/var/lib/rancher/rke2/server/tls/etcd/server-client.crt \
  --key=/var/lib/rancher/rke2/server/tls/etcd/server-client.key \
  member list -w table
```

**Three members, all `started`.** If not, stop here — everything downstream assumes quorum.

---

## Phase 6 — Platform, on the new cluster

From `k8s-1`, the existing bootstrap scripts do this unchanged — they run *inside* a node and do not
care that the node is now a VM:

```sh
bootstrap/02-argocd.sh          # Argo CD, then root-app converges the platform wave
```

**OpenBao is initialised fresh.** New unseal shares, new root token:

```sh
bootstrap/03-openbao.sh init    # ONCE. Run it in your own session, not through an assistant.
bootstrap/03-openbao.sh unseal
bootstrap/03-openbao.sh configure
```

This is the side benefit ADR-015 records: it retires the shares exposed in a plaintext file on
2026-09-15 without a rekey on a live instance, where a mis-copied share means permanent loss.

**The TLS certificate — do this before cutover, not after.** The ClusterIssuers use an **http01**
solver, so cert-manager on the new cluster cannot answer a challenge until port 80 already points at
it. And `.dev` is HSTS-preloaded: a missing certificate is a hard failure with no click-through. So
carry the existing cert across and let cert-manager renew it later:

```sh
# on the OLD cluster — the secret lives in the Traefik namespace, not web
kubectl -n traefik get secret vaullet-dev-tls -o yaml \
  | grep -v '^\s*\(creationTimestamp\|resourceVersion\|uid\|namespace\):' > /root/pre-split/tls.yaml
# on the NEW cluster
kubectl -n traefik apply -f tls.yaml
```

Never `cat`, `head` or `less` that file — it contains the private key. Check it with
`grep -c`, `wc -c` and `openssl x509 -noout` only.

**Carrying the secret across does not cancel the issuance already in flight.** cert-manager will
have started one the moment its Application synced and the Secret did not yet exist, and the
`Issuing` condition is *latched*: it clears when an issuance completes, not when a valid Secret
appears. Deleting the CertificateRequest only restarts it. So expect the challenges to complete
shortly after cutover and a **new certificate with a new fingerprint** to replace the carried one.
That is harmless — and one more key rotation — but verify the fingerprint afterwards rather than
being surprised by it.

Verify the new cluster serves the site on a spare port, **without touching 80/443**. This needs
*two* rules, not one: libvirt's network will not pass a new inbound connection to a guest on the
strength of a DNAT alone.

```sh
# on the host — spare port, so the old cluster keeps serving the real ones
iptables -I LIBVIRT_FWI 1 -d 192.168.122.11/32 -o virbr0 -p tcp --dport 443 -j ACCEPT
iptables -t nat -I PREROUTING 1 -d 65.109.58.119/32 -p tcp --dport 8443 \
  -j DNAT --to-destination 192.168.122.11:443

# FROM YOUR LAPTOP. Traffic this box originates to its own address goes through
# OUTPUT, never PREROUTING, so running the curl on the host tests nothing.
curl -k --resolve vaullet.dev:8443:65.109.58.119 https://vaullet.dev:8443/ -I

iptables -t nat -D PREROUTING -d 65.109.58.119/32 -p tcp --dport 8443 \
  -j DNAT --to-destination 192.168.122.11:443
```

**If that returns `000` in about 50 ms**, the missing piece is the `LIBVIRT_FWI` accept, not the
cluster. libvirt's default network is outbound-only: it accepts `RELATED,ESTABLISHED` and ends the
chain with `REJECT --reject-with icmp-port-unreachable`. The host accepts the connection and then
refuses it internally, which looks exactly like a dead service. The instant failure is the tell — a
`DROP` would hang until curl's timeout.

**Do not DNAT 6443 during the overlap** — the host's own apiserver is on it. Use 6444 if you want
kubectl from your laptop before cutover, or just tunnel over SSH.

**Rollback:** delete the test rule. Nothing user-facing has moved.

---

## Phase 7 — Cutover

**Do not pin Traefik to a node.** `enable-servicelb` puts a klipper-lb (`svclb`) pod on *every*
node, each forwarding into the Traefik Service, so any node address is a valid entry point no
matter where the Traefik pod is scheduled. On the live cutover the DNAT pointed at `k8s-1` while
Traefik ran on `k8s-3` and it served correctly throughout. Pinning buys nothing and costs
scheduling freedom.

Publishing the cluster on the host's address takes **three rules across two tables**. Only the
first is obvious, and each of the other two fails in a way that reads as something else entirely:

```sh
systemd-run --on-active=5min --unit=panic-reboot systemctl reboot   # arm

# 1. rewrite the destination. -I PREROUTING 1, NOT -A: Calico's cali-PREROUTING and
#    RKE2's CNI-HOSTPORT-DNAT are in this chain already, and an APPENDED rule lands
#    after them -- the packet reaches the OLD cluster and the cutover silently does
#    nothing. And -d <public ip> is load-bearing, see the warning below.
iptables -t nat -I PREROUTING 1 -d 65.109.58.119/32 -p tcp --dport 443 \
  -j DNAT --to-destination 192.168.122.11:443
iptables -t nat -I PREROUTING 1 -d 65.109.58.119/32 -p tcp --dport 80 \
  -j DNAT --to-destination 192.168.122.11:80

# 2. let the connection actually reach the guest. libvirt's network accepts only
#    RELATED,ESTABLISHED inbound and REJECTs the rest.
iptables -I LIBVIRT_FWI 1 -d 192.168.122.11/32 -o virbr0 -p tcp \
  -m multiport --dports 80,443 -j ACCEPT

# 3. NAT loopback. Without it a guest that resolves the public hostname is DNAT-ed
#    to a neighbour on the same bridge, which replies directly, outside conntrack.
iptables -t nat -I POSTROUTING 1 -s 192.168.122.0/24 -d 192.168.122.11/32 \
  -p tcp -m multiport --dports 80,443 -j MASQUERADE

# verify the DNAT rules are above cali-PREROUTING and CNI-HOSTPORT-DNAT:
iptables -t nat -S PREROUTING | head -4

curl -I https://vaullet.dev/          # from your laptop, not the box
```

> ⚠️ **The `-d <public ip>` on the DNAT rules is not a refinement — leaving it off breaks all
> outbound HTTPS from the cluster.** Traffic *leaving* the guests is forwarded traffic, so it
> traverses `PREROUTING` too. An unscoped `--dport 443 -j DNAT` matches it and bends every
> outbound call back into your own ingress. The symptom is a TLS error naming Traefik's default
> certificate — `x509: certificate is valid for ...traefik.default, not
> acme-v02.api.letsencrypt.org` — and it takes ACME, registry pulls over 443 and Argo's git
> fetches with it. A spare-port test cannot catch this, because the spare port matches nothing
> outbound.

Confirm the rules are matching rather than assuming it. Packet counters are the only honest
check, because the response body is identical from either cluster:

```sh
iptables -t nat -L PREROUTING -n -v --line-numbers | head -6   # before
# …a few requests from your laptop…
iptables -t nat -L PREROUTING -n -v --line-numbers | head -6   # the counter must move
```

If it serves: `systemctl stop panic-reboot.timer`, then make the rules survive a reboot with
`bootstrap/04-ingress.sh`, which installs them as an idempotent script plus a systemd unit and a
libvirt network hook.

**Do not use `iptables-persistent`.** `netfilter-persistent save` snapshots the *whole* table —
Calico's chains, RKE2's, everything — and replays it at boot before either is running.

**Rollback — the whole point of the shape:**

```sh
iptables -t nat -D PREROUTING -d 65.109.58.119/32 -p tcp --dport 80 \
  -j DNAT --to-destination 192.168.122.11:80
iptables -t nat -D PREROUTING -d 65.109.58.119/32 -p tcp --dport 443 \
  -j DNAT --to-destination 192.168.122.11:443
```

The old cluster never stopped running. Traffic returns to it immediately.

---

## Phase 8 — Reclaim, only once you are happy

Leave the old cluster running for a day. When you are done:

```sh
systemctl disable --now rke2-server           # on the HOST

# stopping the unit does NOT stop its containers -- KillMode leaves containerd's
# children running, so the RAM you came for is not returned until:
/usr/local/bin/rke2-killall.sh

# killall pipes iptables-save through `grep -v KUBE-/CNI-/cali-/flannel` into
# iptables-restore. Our rules survive that filter, but re-assert them anyway:
/usr/local/sbin/vaullet-ingress-rules.sh
curl -I https://vaullet.dev/                  # from your laptop

# the host's kubeconfig now points at a dead apiserver. Repoint it, and keep a
# kubectl that outlives the uninstall:
cp /var/lib/rancher/rke2/bin/kubectl /usr/local/bin/kubectl
umask 077 && mkdir -p /root/.kube
ssh root@192.168.122.11 'cat /etc/rancher/rke2/rke2.yaml' \
  | sed 's|https://127.0.0.1:6443|https://192.168.122.11:6443|' > /root/.kube/config
chmod 600 /root/.kube/config

# AND the export that overrides it. bootstrap/01-rke2.sh appended this to
# /root/.bashrc back when RKE2 ran on the host; it now names a dead apiserver,
# and KUBECONFIG beats ~/.kube/config outright rather than falling back to it.
sed -i 's|^export KUBECONFIG=/etc/rancher/rke2/rke2.yaml$|export KUBECONFIG=/root/.kube/config|' \
  /root/.bashrc
```

Verify it with `bash -ic 'kubectl get nodes'`, not `bash -lc`. A login non-interactive shell does
not read `.bashrc`, so `-lc` passes while your own terminal still fails — the asymmetry hides this
exact class of leftover.

`rke2-killall.sh` deletes network interfaces, but only named CNI ones — `cni0`, `flannel.*`,
`vxlan.calico`, `cilium_*`, `kube-ipvs0`, `nodelocaldns` — plus anything mastered by `cni0`. The
guests' `vnet*` are mastered by `virbr0`, so they are untouched. Worth re-reading the script before
running it rather than trusting that.

Only after another day, and only once you accept losing the rollback:

```sh
/usr/local/bin/rke2-uninstall.sh
```

> ⚠️ **Uninstall destroys the old cluster's etcd data and its `local-path` PVCs, including
> OpenBao's.** Check `kubectl get externalsecret,clustersecretstore,secretstore -A` on the old
> cluster first: if that is empty, nothing consumed those credentials and re-initialising OpenBao
> on the new cluster costs nothing. If it is not empty, decide how the data moves *before* you
> run this.

Then grow the VMs to their ADR-015 size and pin their vCPUs:

```sh
for i in 1 2 3; do
  virsh shutdown k8s-$i && sleep 30
  virsh setmaxmem k8s-$i 16G --config
  virsh setmem    k8s-$i 16G --config
  virsh start k8s-$i
done
```

vCPU pinning — **etcd's worst failure mode on a virtualised host is CPU steal causing spurious
leader elections.** Pin each VM to its own pair of threads:

```sh
virsh vcpupin k8s-1 0 0 --config ; virsh vcpupin k8s-1 1 1 --config   # …and so on
```

---

## After

- **HAProxy on the host**, TCP passthrough to all three nodes, replacing the single-target DNAT.
  Until then, `k8s-1` going down takes ingress with it — not because Traefik lives there, but
  because the DNAT names it. Do not reach for `-m statistic --mode nth` across the three addresses
  instead: with no health checking it black-holes a third of requests the moment a node goes down,
  which is worse than one honest point of failure.
- **Split-horizon DNS for the public hostnames.** The DNAT target cannot reach the public address
  through the host: the packet is DNAT-ed to itself, never gets SNAT-ed, and arrives with
  `src == dst`, where the kernel drops it as a martian. The other two nodes hairpin fine. Nothing
  is broken today because cert-manager happens to run elsewhere, but a pod scheduled onto the
  target node that calls the site by name will fail, and cert-manager's HTTP-01 self-check is
  exactly such a call. Resolving the hostnames to the in-cluster Traefik Service removes the
  hairpin for all three nodes and drops a host round-trip.
- **Move this to a script** under `bootstrap/`. Phases 1–3 are the reusable part and belong there;
  phases 6–8 are one-off. The host-side ingress rules are already done — `bootstrap/04-ingress.sh`. ADR-015 flags that the hypervisor layer sits outside GitOps, which is a
  real departure from "the whole cluster, as git" and should not stay hand-run.
- **`gitops/README.md`** — update "single-node RKE2" to describe what now exists.

## Known limits

Three VMs share one PSU, one board, one host kernel and one RAID1 array. This buys etcd quorum,
working PodDisruptionBudgets, live drains and Kafka RF=3. **It buys no hardware resilience**, and
`README.md`'s "production topology, not production grade" stays true.
