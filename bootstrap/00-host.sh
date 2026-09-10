#!/usr/bin/env bash
# Run once on the Hetzner AX41, as root, BEFORE k3s. Ubuntu 26.04 LTS.
# Public IP: harden first, cluster second.
#
# This script refuses to run if it would lock you out. Read the guard below.
set -euo pipefail

# --- guard: never disable password auth without a working key -------------
if ! grep -qs 'ssh-' /root/.ssh/authorized_keys; then
  echo "REFUSING: /root/.ssh/authorized_keys has no key." >&2
  echo "Install your public key first, or you will be locked out." >&2
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get -y install ufw fail2ban unattended-upgrades curl

# --- SSH: keys only -------------------------------------------------------
# A drop-in, not an edit of sshd_config: Ubuntu's stock config ends with
# "Include /etc/ssh/sshd_config.d/*.conf", and on Hetzner images something
# already in that directory can silently win over a sed'ed main file.
cat > /etc/ssh/sshd_config.d/99-vaullet.conf <<'EOF'
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
EOF

# Validate before reloading. A bad config here is a Hetzner-rescue-console trip.
sshd -t

# Ubuntu has socket-activated ssh since 24.04: ssh.socket accepts the connection
# and spawns a per-connection sshd, so sshd_config is re-read on every new
# connection and there is nothing long-running to reload. Restart the socket if
# that is what is active, and fall back to the classic service if it is not.
# (Note for later: changing the SSH *port* on this setup means editing
# ssh.socket's ListenStream, not sshd_config. Port is unchanged here.)
if systemctl is-active --quiet ssh.socket; then
  systemctl restart ssh.socket
else
  systemctl reload ssh   # Debian/Ubuntu unit is "ssh", not "sshd"
fi

# --- fail2ban -------------------------------------------------------------
# Ubuntu dropped rsyslog as of 24.04, so /var/log/auth.log does not exist and
# the stock sshd jail dies on startup. Read the journal instead. Still true on
# 26.04.
cat > /etc/fail2ban/jail.local <<'EOF'
[DEFAULT]
backend = systemd

[sshd]
enabled = true
maxretry = 5
bantime = 1h
EOF
systemctl enable --now fail2ban
systemctl restart fail2ban

# --- firewall -------------------------------------------------------------
# Only 22/80/443 from the world. The k3s API (6443) stays closed; reach it
# over an SSH tunnel until a second node actually needs it.
ufw --force reset
ufw default deny incoming
ufw default allow outgoing

# k3s puts pod traffic through the FORWARD chain. ufw's default DROP there
# breaks CoreDNS and every pod-to-pod hop; this is the single most common
# way a "hardened" single-node k3s ends up half-broken.
sed -i 's/^DEFAULT_FORWARD_POLICY=.*/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw

ufw allow 22/tcp     comment 'ssh'
ufw allow 80/tcp     comment 'http  - acme http-01 + ingress'
ufw allow 443/tcp    comment 'https - ingress'

# Trust the cluster's own CIDRs (k3s defaults) and the flannel interface.
ufw allow from 10.42.0.0/16 comment 'k3s pod cidr'
ufw allow from 10.43.0.0/16 comment 'k3s service cidr'
ufw allow in on cni0
ufw allow in on flannel.1

ufw --force enable
ufw status verbose

# --- unattended security updates -----------------------------------------
# Security patches only, and never a reboot on its own schedule.
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
sed -i 's|^//Unattended-Upgrade::Automatic-Reboot .*|Unattended-Upgrade::Automatic-Reboot "false";|' \
  /etc/apt/apt.conf.d/50unattended-upgrades

# --- report ---------------------------------------------------------------
echo
echo "=== disks ==="; lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT
echo "=== md raid ==="; cat /proc/mdstat 2>/dev/null || echo "(no mdraid)"
echo "=== memory ==="; free -h
echo
echo "host hardened."
echo "OPEN A SECOND SSH SESSION AND CONFIRM IT WORKS before closing this one."
