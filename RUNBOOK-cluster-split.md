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
cut over  DNAT :80 :443 → 192.168.122.11
rollback  delete the two rules
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
kubectl -n web get secret -o yaml                  > web-secrets.yaml   # the TLS cert, needed in Phase 6
rke2 etcd-snapshot save --name pre-split
```

`rke2 etcd-snapshot` writes to `/var/lib/rancher/rke2/server/db/snapshots/`. It is insurance for the
*old* cluster, not a migration path — the new cluster starts empty by design.

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
# on the OLD cluster
kubectl -n web get secret <tls-secret> -o yaml \
  | grep -v '^\s*\(creationTimestamp\|resourceVersion\|uid\|namespace\):' > /root/pre-split/tls.yaml
# on the NEW cluster
kubectl -n web apply -f tls.yaml
```

Verify the new cluster serves the site on a spare port, **without touching 80/443**:

```sh
# on the host — spare ports, so the old cluster keeps serving the real ones
iptables -t nat -I PREROUTING 1 -p tcp --dport 8443 -j DNAT --to 192.168.122.11:443
curl -k --resolve vaullet.dev:8443:65.109.58.119 https://vaullet.dev:8443/ -I
iptables -t nat -D PREROUTING -p tcp --dport 8443 -j DNAT --to 192.168.122.11:443
```

**Do not DNAT 6443 during the overlap** — the host's own apiserver is on it. Use 6444 if you want
kubectl from your laptop before cutover, or just tunnel over SSH.

**Rollback:** delete the test rule. Nothing user-facing has moved.

---

## Phase 7 — Cutover

Traefik pinned to `k8s-1` (ADR-015 §4, stage one — HAProxy across all three comes later):

```sh
kubectl -n traefik patch deployment traefik --type=merge \
  -p '{"spec":{"template":{"spec":{"nodeSelector":{"kubernetes.io/hostname":"k8s-1"}}}}}'
```

Then, on the host — **this is the only user-visible moment**:

```sh
systemd-run --on-active=5min --unit=panic-reboot systemctl reboot   # arm

# -I PREROUTING 1, NOT -A. Nothing listens on 80/443 on the host (`ss -ltnp` shows
# only the apiserver): Traefik is reached by CNI hostPort DNAT rules already sitting
# in PREROUTING. An APPENDED rule lands after those, so the packet reaches the OLD
# cluster and the cutover silently does nothing. Inserting at position 1 wins.
iptables -t nat -I PREROUTING 1 -p tcp --dport 443 -j DNAT --to 192.168.122.11:443
iptables -t nat -I PREROUTING 1 -p tcp --dport 80  -j DNAT --to 192.168.122.11:80

# verify ours are first:
iptables -t nat -S PREROUTING | head -3

curl -I https://vaullet.dev/            # from your laptop, not the box
```

If it serves: `systemctl stop panic-reboot.timer`, then persist the rules
(`apt install iptables-persistent` / `netfilter-persistent save`).

**Rollback — the whole point of the shape:**

```sh
iptables -t nat -D PREROUTING -p tcp --dport 80  -j DNAT --to 192.168.122.11:80
iptables -t nat -D PREROUTING -p tcp --dport 443 -j DNAT --to 192.168.122.11:443
```

The old cluster never stopped running. Traffic returns to it immediately.

---

## Phase 8 — Reclaim, only once you are happy

Leave the old cluster running for a day. When you are done:

```sh
systemctl disable --now rke2-server           # on the HOST
# after another day, and only then:
/usr/local/bin/rke2-uninstall.sh
```

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

- **HAProxy on the host**, TCP passthrough to all three nodes, replacing the pinned-Traefik DNAT.
  Until then, `k8s-1` going down takes ingress with it.
- **Move this to a script** under `bootstrap/`. Phases 1–3 are the reusable part and belong there;
  phases 6–8 are one-off. ADR-015 flags that the hypervisor layer sits outside GitOps, which is a
  real departure from "the whole cluster, as git" and should not stay hand-run.
- **`gitops/README.md`** — update "single-node RKE2" to describe what now exists.

## Known limits

Three VMs share one PSU, one board, one host kernel and one RAID1 array. This buys etcd quorum,
working PodDisruptionBudgets, live drains and Kafka RF=3. **It buys no hardware resilience**, and
`README.md`'s "production topology, not production grade" stays true.
