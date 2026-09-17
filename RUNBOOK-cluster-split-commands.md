# Cluster split — exact commands

Companion to [RUNBOOK-cluster-split.md](RUNBOOK-cluster-split.md), which explains *why*. This file is
only *what to type*. Every value is resolved — nothing to fill in.

Unless a block says otherwise, **run as root on the host** (`ssh vaullet`).

`⛔ STOP` marks a point where you check something before continuing.

---

## 0 — Record the current state

```sh
export KUBECONFIG=/etc/rancher/rke2/rke2.yaml
export PATH=$PATH:/var/lib/rancher/rke2/bin
mkdir -p /root/pre-split && cd /root/pre-split

kubectl get nodes -o wide                 > nodes.txt
kubectl get all -A                        > all.txt
kubectl get applications -n argocd        > argo.txt
kubectl get pvc -A                        > pvc.txt
kubectl get certificate -A                > certs.txt

umask 077
kubectl -n traefik get secret vaullet-dev-tls -o yaml \
  | grep -vE '^\s*(creationTimestamp|resourceVersion|uid|namespace):' > tls.yaml

rke2 etcd-snapshot save --name pre-split
ls -la /var/lib/rancher/rke2/server/db/snapshots/ | tail -3
```

⛔ **STOP** — verify it **without printing it**. `tls.yaml` contains the private key for
`vaullet.dev`; anything that echoes it puts the key in a scrollback, a log, or a transcript.

```sh
grep -c 'tls.crt:\|tls.key:' tls.yaml     # must print 2
wc -c tls.yaml                            # ~10 KB
chmod 600 tls.yaml
```

**Never `cat`, `head` or `less` this file.** Same rule as the OpenBao unseal keys: a secret that
reaches a terminal has reached everything recording that terminal.

---

## 1 — libvirt

```sh
apt update
# qemu-kvm is a DROPPED transitional package on modern Ubuntu — apt fails with
# "no installation candidate". The real one is qemu-system-x86.
apt install -y qemu-system-x86 libvirt-daemon-system libvirt-clients virtinst \
               cloud-image-utils
systemctl enable --now libvirtd
virsh list --all
virsh net-list --all
```

⛔ **STOP** — `virsh list --all` prints an empty table with no error.

---

## 2 — Network ⚠️ — arm the timer in step 1, not here

**Installing `libvirt-daemon-system` starts the `default` network by itself.** `virbr0` comes up,
`default` is `active` with `autostart yes`, and ~7 NAT + ~23 filter rules appear — so the risky part
of this phase happens during step 1. **Arm the panic timer and open the second SSH session before
running `apt install`.**

This phase is therefore a *verification*, not an action:

```sh
virsh net-list --all          # default | active | yes
ip addr show virbr0
iptables -S FORWARD | head -6
```

The FORWARD chain should read: `cali-FORWARD` first, then `LIBVIRT_FWX/FWI/FWO`, then
`KUBE-PROXY-FIREWALL`, policy ACCEPT. libvirt confines itself to its own chains and sits after
calico, and `LIBVIRT_FWI/FWO` only match traffic crossing `virbr0`. Nothing to untangle.

**Verify the cluster functionally — not by reading rules.** Use a throwaway pod with a known
toolset; do not exec into whatever happens to be running (coredns resolves via the host, and
distroless images have no `wget`):

```sh
kubectl run netcheck --rm -i --restart=Never --image=busybox:1.36 -- sh -c '
  nslookup kubernetes.default.svc.cluster.local >/dev/null 2>&1 && echo "cluster DNS OK"
  nslookup github.com >/dev/null 2>&1 && echo "external DNS OK"
  wget -q -T8 -O /dev/null https://github.com && echo "pod egress OK"'
curl -s -o /dev/null -w "%{http_code}\n" https://vaullet.dev/
```

⛔ **STOP** — from the **second session**, confirm the host still responds:
`ssh vaullet 'echo alive'`

```sh
systemctl stop panic-reboot.timer
systemctl reset-failed panic-reboot.service 2>/dev/null || true
```

---

## 3 — Three VMs

### 3a — a key the host can use to reach its own VMs

```sh
test -f /root/.ssh/id_ed25519 || ssh-keygen -t ed25519 -N '' -f /root/.ssh/id_ed25519
cat /root/.ssh/id_ed25519.pub
```

### 3b — fixed MAC → fixed IP

```sh
for i in 1 2 3; do
  virsh net-update default add ip-dhcp-host \
    "<host mac='52:54:00:00:00:0$i' name='k8s-$i' ip='192.168.122.1$i'/>" \
    --live --config
done
virsh net-dumpxml default | grep host
```

### 3c — base image and thin per-VM disks

```sh
cd /var/lib/libvirt/images
curl -fsSLO https://cloud-images.ubuntu.com/resolute/current/resolute-server-cloudimg-amd64.img
for i in 1 2 3; do
  qemu-img create -f qcow2 -F qcow2 \
    -b resolute-server-cloudimg-amd64.img k8s-$i.qcow2 60G
done
ls -la k8s-*.qcow2
```

### 3d — cloud-init, both keys

```sh
LAPTOP_KEY="$(head -1 /root/.ssh/authorized_keys)"
HOST_KEY="$(cat /root/.ssh/id_ed25519.pub)"
for i in 1 2 3; do
cat > /var/lib/libvirt/images/ci-k8s-$i.yaml <<EOF
#cloud-config
hostname: k8s-$i
fqdn: k8s-$i
users:
  - name: root
    lock_passwd: true
    ssh_authorized_keys:
      - $LAPTOP_KEY
      - $HOST_KEY
disable_root: false
ssh_pwauth: false
package_update: true
packages: [ curl ]
EOF
done
grep -c ssh-  /var/lib/libvirt/images/ci-k8s-1.yaml
```

⛔ **STOP** — that last command must print `2`.

### 3e — build the seed, then create them (12 GiB during the overlap)

**Do not use `virt-install --cloud-init`.** It builds a seed that **cloud-init 26.1 rejects** —
`DataSourceNoCloud: device /dev/sr0 with label=cidata not a valid seed` — and silently falls back to
the DMI datasource, so the VMs boot fine with an **empty `/root/.ssh/authorized_keys`**. It also
unlinks the ISO after boot, which later breaks `virt-cat -d`.

Build the seed explicitly and attach it as an ordinary CD-ROM:

```sh
cd /var/lib/libvirt/images
for i in 1 2 3; do
  cat > md-k8s-$i.yaml <<EOF
instance-id: k8s-$i-$(date +%s)
local-hostname: k8s-$i
EOF
  cloud-localds seed-k8s-$i.iso ci-k8s-$i.yaml md-k8s-$i.yaml
done

# verify BEFORE booting: real filenames and the cidata label
mkdir -p /mnt/seed && mount -o loop,ro seed-k8s-1.iso /mnt/seed
ls /mnt/seed                                    # meta-data  user-data
blkid -o value -s LABEL seed-k8s-1.iso          # cidata
umount /mnt/seed
```

```sh
for i in 1 2 3; do
  virt-install --name k8s-$i --memory 12288 --vcpus 4 \
    --cpu host-passthrough --machine q35 \
    --disk /var/lib/libvirt/images/k8s-$i.qcow2,bus=virtio,format=qcow2 \
    --disk /var/lib/libvirt/images/seed-k8s-$i.iso,device=cdrom \
    --network network=default,mac=52:54:00:00:00:0$i,model=virtio \
    --os-variant detect=on,require=off \
    --graphics none --import --noautoconsole
  virsh autostart k8s-$i
done
virsh list --all
```

⛔ **STOP** — three hostnames printed: `k8s-1`, `k8s-2`, `k8s-3`.

---

## 4 — RKE2, pinned to the version already running

### 4a — k8s-1, alone

```sh
ssh root@192.168.122.11 'mkdir -p /etc/rancher/rke2 && cat > /etc/rancher/rke2/config.yaml <<EOF
tls-san:
  - 192.168.122.11
  - 65.109.58.119
  - k8s-1
kubelet-arg:
  - "system-reserved=cpu=200m,memory=1Gi"
node-taint: []
EOF'

ssh root@192.168.122.11 'curl -sfL https://get.rke2.io | INSTALL_RKE2_VERSION=v1.36.4+rke2r1 sh -'
ssh root@192.168.122.11 'systemctl enable --now rke2-server'
```

Wait for it (two to three minutes):

```sh
ssh root@192.168.122.11 'export KUBECONFIG=/etc/rancher/rke2/rke2.yaml; \
  export PATH=$PATH:/var/lib/rancher/rke2/bin; kubectl get node -w'
```

⛔ **STOP** — `k8s-1` is `Ready`. Ctrl-C out of the watch.

### 4b — k8s-2, then k8s-3, one at a time

```sh
# The join token is equivalent to cluster admin. Capture it; never echo it.
TOKEN="$(ssh root@192.168.122.11 cat /var/lib/rancher/rke2/server/node-token)"
echo "${#TOKEN} chars"        # 108 — length only, never the value

# If you rebuilt the VMs, clear stale host keys or every ssh call warns loudly:
for i in 1 2 3; do ssh-keygen -f /root/.ssh/known_hosts -R 192.168.122.1$i; done
```

```sh
for i in 2 3; do
  ssh root@192.168.122.1$i "mkdir -p /etc/rancher/rke2 && cat > /etc/rancher/rke2/config.yaml <<EOF
server: https://192.168.122.11:9345
token: $TOKEN
tls-san:
  - 192.168.122.1$i
  - 65.109.58.119
  - k8s-$i
kubelet-arg:
  - \"system-reserved=cpu=200m,memory=1Gi\"
node-taint: []
EOF"
  ssh root@192.168.122.1$i 'curl -sfL https://get.rke2.io | INSTALL_RKE2_VERSION=v1.36.4+rke2r1 sh -'
  ssh root@192.168.122.1$i 'systemctl enable --now rke2-server'
  echo ">>> waiting for k8s-$i to join"
  until ssh root@192.168.122.11 'export KUBECONFIG=/etc/rancher/rke2/rke2.yaml; \
        /var/lib/rancher/rke2/bin/kubectl get node k8s-'"$i"' 2>/dev/null | grep -q " Ready"'; do
    sleep 10; printf '.'
  done
  echo " k8s-$i Ready"
done
```

---

## 5 — Verify before any traffic

```sh
ssh root@192.168.122.11
export KUBECONFIG=/etc/rancher/rke2/rke2.yaml
export PATH=$PATH:/var/lib/rancher/rke2/bin

kubectl get nodes -o wide
kubectl get pods -n kube-system -l component=etcd
kubectl describe node k8s-1 | grep -A6 "Allocated resources"

kubectl -n kube-system exec etcd-k8s-1 -- etcdctl \
  --cacert=/var/lib/rancher/rke2/server/tls/etcd/server-ca.crt \
  --cert=/var/lib/rancher/rke2/server/tls/etcd/server-client.crt \
  --key=/var/lib/rancher/rke2/server/tls/etcd/server-client.key \
  member list -w table
```

⛔ **STOP — do not continue unless all four are true:**
three nodes `Ready` with roles `control-plane,etcd` · three etcd pods · **three etcd members, all
`started`** · allocatable now lower than capacity.

---

## 6 — Platform, on the new cluster

Still on `k8s-1`. Clone gitops and run the existing scripts — they work unchanged inside a VM:

```sh
cd /root && git clone https://github.com/vaullet-dev/gitops.git && cd gitops
bootstrap/02-argocd.sh
```

**OpenBao — your own session, never through an assistant terminal:**

```sh
bootstrap/03-openbao.sh init
bootstrap/03-openbao.sh unseal
bootstrap/03-openbao.sh configure
```

⛔ **STOP** — write the three new unseal shares and the root token to three separate offline places.
These replace the ones exposed on 2026-09-15.

Carry the certificate over — http01 cannot issue until port 80 already points here, and `.dev` is
HSTS-preloaded:

```sh
# from your laptop
scp vaullet:/root/pre-split/tls.yaml /tmp/tls.yaml
scp /tmp/tls.yaml vaullet:/root/tls.yaml
ssh vaullet 'scp /root/tls.yaml root@192.168.122.11:/root/tls.yaml'
ssh vaullet 'ssh root@192.168.122.11 "KUBECONFIG=/etc/rancher/rke2/rke2.yaml \
  /var/lib/rancher/rke2/bin/kubectl -n traefik apply -f /root/tls.yaml"'
```

Test the new cluster on a spare port — the old one keeps serving 80/443:

```sh
iptables -t nat -I PREROUTING 1 -p tcp --dport 8443 -j DNAT --to 192.168.122.11:443
curl -k --resolve vaullet.dev:8443:65.109.58.119 https://vaullet.dev:8443/ -I
iptables -t nat -D PREROUTING -p tcp --dport 8443 -j DNAT --to 192.168.122.11:443
```

⛔ **STOP** — that `curl` returns `HTTP/2 200`. If not, do **not** cut over.

---

## 7 — Cutover

Pin Traefik to `k8s-1`:

```sh
ssh root@192.168.122.11 'KUBECONFIG=/etc/rancher/rke2/rke2.yaml \
  /var/lib/rancher/rke2/bin/kubectl -n traefik patch deployment traefik --type=merge \
  -p "{\"spec\":{\"template\":{\"spec\":{\"nodeSelector\":{\"kubernetes.io/hostname\":\"k8s-1\"}}}}}"'
```

The only user-visible moment:

```sh
systemd-run --on-active=5min --unit=panic-reboot systemctl reboot

# -I PREROUTING 1, NOT -A. Nothing listens on 80/443 on the host (`ss -ltnp` shows
# only the apiserver): Traefik is reached by CNI hostPort DNAT rules already sitting
# in PREROUTING. An APPENDED rule lands after those, so the packet reaches the OLD
# cluster and the cutover silently does nothing. Inserting at position 1 wins.
iptables -t nat -I PREROUTING 1 -p tcp --dport 443 -j DNAT --to 192.168.122.11:443
iptables -t nat -I PREROUTING 1 -p tcp --dport 80  -j DNAT --to 192.168.122.11:80

# verify ours are first:
iptables -t nat -S PREROUTING | head -3
```

From your **laptop**:

```sh
curl -I https://vaullet.dev/
```

⛔ **STOP** — `HTTP/2 200` and a valid certificate.

**If it works:**

```sh
systemctl stop panic-reboot.timer
systemctl reset-failed panic-reboot.service 2>/dev/null || true
apt install -y iptables-persistent
netfilter-persistent save
```

**If it does not — rollback, immediately:**

```sh
iptables -t nat -D PREROUTING -p tcp --dport 80  -j DNAT --to 192.168.122.11:80
iptables -t nat -D PREROUTING -p tcp --dport 443 -j DNAT --to 192.168.122.11:443
curl -I https://vaullet.dev/
```

---

## 8 — Reclaim, after a day of watching

```sh
systemctl disable --now rke2-server
curl -I https://vaullet.dev/
```

After another day:

```sh
/usr/local/bin/rke2-uninstall.sh
```

Grow the VMs and pin their vCPUs:

```sh
for i in 1 2 3; do
  virsh shutdown k8s-$i
done
sleep 45
for i in 1 2 3; do
  virsh setmaxmem k8s-$i 16G --config
  virsh setmem    k8s-$i 16G --config
  virsh start k8s-$i
done

virsh vcpupin k8s-1 0 0 --config; virsh vcpupin k8s-1 1 1 --config
virsh vcpupin k8s-1 2 2 --config; virsh vcpupin k8s-1 3 3 --config
virsh vcpupin k8s-2 0 4 --config; virsh vcpupin k8s-2 1 5 --config
virsh vcpupin k8s-2 2 6 --config; virsh vcpupin k8s-2 3 7 --config
virsh vcpupin k8s-3 0 8 --config; virsh vcpupin k8s-3 1 9 --config
virsh vcpupin k8s-3 2 10 --config; virsh vcpupin k8s-3 3 11 --config
```

---

## Full teardown, at any point before step 7

```sh
for i in 1 2 3; do
  virsh destroy k8s-$i 2>/dev/null
  virsh undefine k8s-$i --remove-all-storage 2>/dev/null
done
virsh net-destroy default
virsh net-autostart --disable default
```

The old cluster was never modified and is still serving.
