#!/usr/bin/env bash
# Single-node RKE2 on the Hetzner AX41. Ubuntu 26.04 LTS, cgroup v2.
#
# RKE2 over k3s: etcd is the datastore with no way to accidentally get SQLite,
# the control plane runs as static pods, and SUSE positions it for production
# datacenter use rather than edge/CI. On one box neither gives HA -- same
# kernel, same disk array, same PSU -- but this removes the "your ledger's
# control plane is a SQLite file" conversation entirely.
set -euo pipefail

: "${PUBLIC_IP:?set PUBLIC_IP to the public IPv4 of the AX41}"
RKE2_VERSION="${RKE2_VERSION:-v1.36.4+rke2r1}"

# --- config BEFORE install: rke2-server reads this on first start -----------
install -d -m 0755 /etc/rancher/rke2
cat > /etc/rancher/rke2/config.yaml <<EOF
# Cluster-admin credentials on a public IP. Root-only; we tunnel over SSH
# rather than opening 6443 to the world.
write-kubeconfig-mode: "0600"

tls-san:
  - "${PUBLIC_IP}"

# Both bundled ingress controllers are disabled. RKE2 v1.36 ships Traefik by
# default (it switched after ingress-nginx went EOL in March 2026), and older
# versions ship ingress-nginx -- disabling both means this file does the same
# thing regardless of which version is pinned above. OUR Traefik comes from
# Argo CD with the Gateway API provider turned on. Two Traefiks contending for
# :80 is a genuinely miserable afternoon.
disable:
  - rke2-traefik
  - rke2-ingress-nginx
  # rke2-traefik-crd is a SEPARATE component from rke2-traefik and is NOT
  # covered by disabling it. Left on, it installs 26 Traefik CRDs (18 of them
  # for Traefik Hub, a commercial product) AND the Gateway API CRDs -- which
  # would then be owned by an RKE2 helm release at whatever version its bundled
  # Traefik wants, rather than the version pinned in clusters/prod/00-crds.yaml.
  - rke2-traefik-crd

# Unlike k3s, RKE2 does not run ServiceLB unless asked. Without it a Service of
# type LoadBalancer sits in Pending forever, because nothing on a bare-metal
# box assigns it an external IP. This is what binds the node's real :80/:443.
enable-servicelb: true

# NOT set: profile: "cis". See the note at the end of this script -- it is one
# line to add later, but it enforces restricted PodSecurity cluster-wide and
# default-deny NetworkPolicies, which would break Traefik, cert-manager and
# Argo on day one. Harden after the stack is up and verified, not during.
EOF

# --- CIS prerequisite, done now so enabling the profile later is one line ---
# Harmless on its own: a system account that owns the etcd data directory.
if ! id -u etcd >/dev/null 2>&1; then
  useradd -r -c "etcd user" -s /sbin/nologin -M etcd -U
fi

# --- install ----------------------------------------------------------------
curl -sfL https://get.rke2.io | INSTALL_RKE2_VERSION="${RKE2_VERSION}" sh -
systemctl enable --now rke2-server.service

# --- make kubectl usable ----------------------------------------------------
# RKE2 puts its binaries somewhere not on anyone's PATH.
ln -sf /var/lib/rancher/rke2/bin/kubectl /usr/local/bin/kubectl
ln -sf /var/lib/rancher/rke2/bin/crictl  /usr/local/bin/crictl
export KUBECONFIG=/etc/rancher/rke2/rke2.yaml
grep -q 'rke2.yaml' /root/.bashrc 2>/dev/null \
  || echo 'export KUBECONFIG=/etc/rancher/rke2/rke2.yaml' >> /root/.bashrc

# RKE2 takes noticeably longer than k3s to come up: it pulls and starts etcd,
# kube-apiserver, controller-manager and scheduler as static pods first.
echo "waiting for the node to register (this takes a few minutes on first run)..."
for i in $(seq 1 60); do
  kubectl get nodes >/dev/null 2>&1 && break
  sleep 10
done
kubectl wait --for=condition=Ready node --all --timeout=300s

# --- report -----------------------------------------------------------------
kubectl get nodes -o wide
kubectl version
echo
echo "=== datastore (expect etcd, NOT sqlite) ==="
kubectl -n kube-system get pods -l component=etcd -o name || true
echo
echo "=== bundled ingress must be absent ==="
kubectl -n kube-system get pods 2>/dev/null | grep -iE 'traefik|ingress-nginx' \
  && echo "!! a bundled ingress is running - check the disable list" \
  || echo "clean: no bundled ingress"
echo
echo "RKE2 up. Note: ufw's cni0 rule from 00-host.sh does nothing here -- RKE2's"
echo "default CNI is Canal, whose pod interfaces are cali*, not cni0. The"
echo "10.42.0.0/16 and 10.43.0.0/16 rules are what actually matter and they"
echo "already cover it; RKE2 uses the same pod/service CIDRs as k3s."
echo
echo "To enable the CIS profile LATER (after the stack is verified):"
echo "  cp /usr/local/share/rke2/rke2-cis-sysctl.conf /etc/sysctl.d/60-rke2-cis.conf"
echo "  systemctl restart systemd-sysctl"
echo "  echo 'profile: \"cis\"' >> /etc/rancher/rke2/config.yaml"
echo "  systemctl restart rke2-server"
echo "Expect to add PodSecurity labels and NetworkPolicies per namespace after that."
