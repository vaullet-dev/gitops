#!/usr/bin/env bash
# OpenBao: the steps that need a human, because they produce or consume the
# unseal keys. Argo installs OpenBao (clusters/prod/openbao.yaml); it cannot
# initialise or unseal it, and that is the point of a seal.
#
#   03-openbao.sh status          initialised? sealed?
#   03-openbao.sh init            ONCE, ever. Prints the unseal keys and root token
#   03-openbao.sh unseal          after every start of openbao-0
#   03-openbao.sh configure       kv-v2 at kv/, kubernetes auth. Safe to rerun
#   03-openbao.sh onboard <ns>    namespace <ns> may read kv/<ns>/*, nothing else
#
# Run this in your own SSH session on the box. Not in CI, not through an AI
# assistant's terminal, not under `script`: `init` prints the only copy of the
# keys, and anything that captured the terminal has them too.
set -euo pipefail
export KUBECONFIG=${KUBECONFIG:-/etc/rancher/rke2/rke2.yaml}

NS=openbao
POD=openbao-0

# 3 shares, any 2 unseal. One share can be lost without losing OpenBao, and
# one share alone -- a leaked password manager, a found piece of paper -- is
# not enough to open it. Keep them in three different places.
KEY_SHARES=3
KEY_THRESHOLD=2

in_pod() { kubectl -n "$NS" exec "$POD" -- "$@"; }

# `bao status` exits 2 when sealed; that is information here, not failure.
status_json() { in_pod bao status -format=json 2>/dev/null || true; }
is_initialized() { status_json | grep -q '"initialized": true'; }
# Asks "is it unsealed", not "is it sealed": an unreachable server says neither,
# and must not be reported as open.
is_unsealed() { status_json | grep -q '"sealed": false'; }

wait_for_pod() {
  kubectl -n "$NS" wait pod/"$POD" --for=jsonpath='{.status.phase}'=Running --timeout=300s >/dev/null
}

# Runs a script inside the pod with the root token. The token goes in on stdin,
# so it never appears in a process list or in `kubectl` arguments.
as_root() {
  local token
  # < /dev/tty is load-bearing. Callers pass the script to run as a HEREDOC, which
  # makes it this function's stdin -- so a bare `read` consumes the heredoc's first
  # line as the token instead of waiting for the terminal. The symptom is every
  # `bao` call returning 403 with no early abort, because the `set -eu` line was
  # what got eaten. It also makes a non-interactive run fail loudly rather than
  # authenticate with garbage.
  read -rsp "root token: " token < /dev/tty; echo
  { printf 'export BAO_TOKEN=%q\n' "$token"; cat; } | kubectl -n "$NS" exec -i "$POD" -- sh -s
}

cmd_status() {
  wait_for_pod
  in_pod bao status || true
}

cmd_init() {
  wait_for_pod
  if is_initialized; then
    echo "already initialised. This runs once; the keys from that run are the keys." >&2
    exit 1
  fi
  echo "Initialising: ${KEY_SHARES} key shares, ${KEY_THRESHOLD} needed to unseal."
  echo "Copy each share and the root token somewhere offline NOW. They are not stored anywhere else."
  echo
  in_pod bao operator init -key-shares="$KEY_SHARES" -key-threshold="$KEY_THRESHOLD"
  echo
  echo "Next: clear this terminal's scrollback, then run: $0 unseal"
}

cmd_unseal() {
  wait_for_pod
  if ! is_initialized; then
    echo "not initialised yet. Run: $0 init" >&2
    exit 1
  fi
  until is_unsealed; do
    # -t: the key is typed at a hidden prompt, never passed as an argument.
    kubectl -n "$NS" exec -it "$POD" -- bao operator unseal
  done
  echo "unsealed."
}

cmd_configure() {
  wait_for_pod
  as_root <<'EOF'
set -eu
bao secrets list | grep -q '^kv/' || bao secrets enable -path=kv kv-v2
bao auth list | grep -q '^kubernetes/' || bao auth enable kubernetes

# No reviewer JWT and no CA given: running in-cluster, OpenBao uses its own
# service account token and CA, and re-reads the token as it rotates. The chart
# binds that service account to system:auth-delegator for the TokenReview.
bao write auth/kubernetes/config \
  kubernetes_host="https://${KUBERNETES_SERVICE_HOST}:${KUBERNETES_SERVICE_PORT}"
EOF
  echo "configured. Onboard a namespace with: $0 onboard <namespace>"
}

# One policy and one role per namespace, both named after it. Explicit rather
# than a single templated policy: `bao policy read wallet-ledger` shows exactly
# what that service can read, with nothing to evaluate in your head.
cmd_onboard() {
  local ns=${1:-}
  if [[ ! $ns =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]]; then
    echo "usage: $0 onboard <namespace>   (a DNS-1123 label, e.g. wallet-ledger)" >&2
    exit 1
  fi
  wait_for_pod
  as_root <<EOF
set -eu
bao policy write '$ns' - <<'POLICY'
path "kv/data/$ns/*"     { capabilities = ["read"] }
path "kv/metadata/$ns/*" { capabilities = ["read", "list"] }
POLICY

bao write 'auth/kubernetes/role/$ns' \
  bound_service_account_names=secrets-reader \
  bound_service_account_namespaces='$ns' \
  token_policies='$ns' \
  token_ttl=10m
EOF
  cat <<EOF
onboarded $ns: service account "secrets-reader" in namespace "$ns" can read kv/$ns/*.
Still needed, in git: that service account, and a ClusterSecretStore
"openbao-$ns" limited to namespace $ns (see README, "Secrets").
EOF
}

case "${1:-}" in
  status)    cmd_status ;;
  init)      cmd_init ;;
  unseal)    cmd_unseal ;;
  configure) cmd_configure ;;
  onboard)   shift; cmd_onboard "$@" ;;
  *)
    sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
    ;;
esac
