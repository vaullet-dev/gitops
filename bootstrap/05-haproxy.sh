#!/usr/bin/env bash
# Ingress for the three-node cluster: HAProxy on the HOST, TCP passthrough.
# ADR-015 §4 stage two. Run on the hypervisor, after 04-ingress.sh has proven
# the cluster serves.
#
# Why this replaces the DNAT from 04-ingress.sh:
#
#   * The DNAT names ONE node. That node going down takes the site with it, no
#     matter where Traefik is scheduled, because klipper-lb only forwards from a
#     node that is up. HAProxy health-checks all three and drops a dead one.
#   * It fixes the hairpin for free. DNAT preserves the source address, so the
#     node being targeted ends up sending a packet to itself with src == dst,
#     which the kernel discards as a martian. HAProxy terminates the connection
#     and opens a NEW one to the backend, sourced from the host's bridge
#     address, so source and destination are never equal.
#   * Traffic moves from the FORWARD path to INPUT, which means ufw's rules
#     apply to it for the first time. 00-host.sh already allows 80 and 443.
#
# TLS still terminates in Traefik: this is `mode tcp`, and the host never holds
# a certificate. The cost is the client's source address -- backends see the
# host. Nothing depends on it today (no middlewares, access logs off); when
# something does, the fix is PROXY protocol on both sides, which is a
# coordinated change with the Traefik values in gitops.
set -euo pipefail

PUBLIC_IP="${PUBLIC_IP:-$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}')}"
NODES="${NODES:-192.168.122.11 192.168.122.12 192.168.122.13}"

[ -n "$PUBLIC_IP" ] || { echo "cannot determine the public address" >&2; exit 1; }

export DEBIAN_FRONTEND=noninteractive
apt-get install -y haproxy socat >/dev/null

servers_http=""; servers_https=""; i=0
for ip in $NODES; do
    i=$((i + 1))
    servers_http="${servers_http}    server k8s-${i} ${ip}:80 check"$'\n'
    servers_https="${servers_https}    server k8s-${i} ${ip}:443 check"$'\n'
done

cat > /etc/haproxy/haproxy.cfg <<CFG
# Managed by gitops/bootstrap/05-haproxy.sh -- see it for the reasoning.
global
    log /dev/log local0
    stats socket /run/haproxy/admin.sock mode 660 level admin expose-fd listeners
    stats timeout 30s
    user haproxy
    group haproxy
    daemon
    maxconn 20000

defaults
    log     global
    mode    tcp
    option  dontlognull
    retries 2
    timeout connect 5s
    timeout client  50s
    timeout server  50s
    # Argo CD's UI streams over websockets; without this they are cut at 50s.
    timeout tunnel  1h

frontend ft_http
    bind ${PUBLIC_IP}:80
    default_backend bk_http

frontend ft_https
    bind ${PUBLIC_IP}:443
    default_backend bk_https

# Health check on :80 for BOTH pools. A bare TCP connect would succeed against
# klipper-lb even with no Traefik behind it; an HTTP probe does not. :80 answers
# with the https redirect, hence 301/308 being acceptable.
backend bk_http
    balance roundrobin
    option httpchk GET /
    http-check expect status 200,301,302,308,404
    default-server inter 3s fall 3 rise 2
${servers_http}
backend bk_https
    balance roundrobin
    option httpchk GET /
    http-check expect status 200,301,302,308,404
    default-server inter 3s fall 3 rise 2 port 80
${servers_https}
CFG

haproxy -c -f /etc/haproxy/haproxy.cfg
systemctl enable --now haproxy
systemctl reload haproxy 2>/dev/null || systemctl restart haproxy
sleep 4

echo
echo "HAProxy is listening but receives nothing yet: the DNAT in nat/PREROUTING"
echo "still diverts inbound traffic before it reaches a local socket."
echo
echo "backend health:"
echo "show stat" | socat stdio /run/haproxy/admin.sock 2>/dev/null \
    | awk -F, 'NR>1 && $2!="BACKEND" && $2!="FRONTEND" && $1!="" {printf "  %-10s %-8s %s\n",$1,$2,$18}'
echo
echo "Verify BEFORE cutting over -- from the host is valid here, unlike the DNAT"
echo "test, because HAProxy is a local socket and locally-originated traffic"
echo "reaches it through OUTPUT without touching PREROUTING:"
echo "  curl -sI --resolve vaullet.dev:443:${PUBLIC_IP} https://vaullet.dev/ | head -1"
echo
echo "Then cut over by retiring the DNAT, and verify from your laptop:"
echo "  systemctl disable --now vaullet-ingress.service"
echo "  iptables -t nat -D PREROUTING -d ${PUBLIC_IP}/32 -p tcp --dport 80 -j DNAT --to-destination 192.168.122.11:80"
echo "  iptables -t nat -D PREROUTING -d ${PUBLIC_IP}/32 -p tcp --dport 443 -j DNAT --to-destination 192.168.122.11:443"
echo
echo "Rollback is one command -- it re-inserts all three rules:"
echo "  systemctl enable --now vaullet-ingress.service"
