#!/usr/bin/env bash
# Single-node k3s on the Hetzner AX41. Ubuntu 26.04 LTS.
#
# 26.04 is cgroup v2 only; k3s v1.36's bundled containerd handles that natively,
# so there is nothing to configure for it.
#
# Traefik is DISABLED here and reinstalled by Argo CD from gitops
# instead. k3s's bundled Traefik is deployed from an on-disk manifest the
# cluster owns, which would sit outside git and drift -- and the bundled version
# is not configured for Gateway API. servicelb (klipper) is KEPT: it is what
# lets a LoadBalancer Service bind the node's :80/:443 with no cloud LB.
set -euo pipefail

: "${PUBLIC_IP:?set PUBLIC_IP to the public IPv4 of the AX41}"
K3S_VERSION="${K3S_VERSION:-v1.36.4+k3s1}"

curl -sfL https://get.k3s.io \
  | INSTALL_K3S_VERSION="${K3S_VERSION}" \
    INSTALL_K3S_EXEC="\
      --disable=traefik \
      --write-kubeconfig-mode=0600 \
      --tls-san=${PUBLIC_IP} \
    " sh -

# 0600, not 0644: this file is cluster-admin. Run kubectl as root, or copy it
# to your workstation over ssh -- do not make it world-readable on a public IP.
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
kubectl wait --for=condition=Ready node --all --timeout=180s
kubectl get nodes -o wide
kubectl version
