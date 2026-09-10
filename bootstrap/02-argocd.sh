#!/usr/bin/env bash
# Argo CD, then hand the cluster over to git. This is the LAST imperative step:
# everything after it is a commit to gitops.
set -euo pipefail
export KUBECONFIG=${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}

ARGO_VERSION="${ARGO_VERSION:-v3.5.2}"

kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -

# Server-side apply: the Argo CD install manifest's CRDs are large enough to
# blow the 262144-byte last-applied-configuration annotation on a client apply.
kubectl apply -n argocd --server-side --force-conflicts -f \
  "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGO_VERSION}/manifests/install.yaml"
kubectl -n argocd rollout status deploy/argocd-server --timeout=300s

# The one object applied by hand. Everything else is a child of this.
kubectl apply -f "$(dirname "$0")/root-app.yaml"

echo
echo "initial admin password:"
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d; echo
echo
echo "The UI is not exposed. Reach it from your workstation with:"
echo "  ssh -L 8080:localhost:8080 root@\${PUBLIC_IP} \\"
echo "    'KUBECONFIG=/etc/rancher/k3s/k3s.yaml kubectl -n argocd port-forward --address 0.0.0.0 svc/argocd-server 8080:443'"
echo "then open https://localhost:8080 (self-signed cert warning is expected)."
