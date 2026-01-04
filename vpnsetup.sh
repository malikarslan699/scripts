#!/bin/bash
set -e

### ===== BASIC CHECK =====
if [[ $EUID -ne 0 ]]; then
  echo "Run as root"
  exit 1
fi

log() { echo "[OCSERV] $1"; }

### ===== DOMAIN SELECTION =====
CERT_PATH="/etc/letsencrypt/live"

log "Scanning existing certificates..."
mapfile -t DOMAINS < <(ls -1 $CERT_PATH 2>/dev/null | grep -v README || true)

if [ ${#DOMAINS[@]} -eq 0 ]; then
  echo "No existing certificates found."
  read -rp "Enter new domain: " DOMAIN
  NEW_CERT=1
else
  echo "Available certificates:"
  for i in "${!DOMAINS[@]}"; do
    echo "$((i+1))) ${DOMAINS[$i]}"
  done
  echo "$(( ${#DOMAINS[@]} + 1 ))) Enter new domain"

  while true; do
    read -rp "Select option: " CHOICE
    if [[ "$CHOICE" -ge 1 && "$CHOICE" -le "${#DOMAINS[@]}" ]]; then
      DOMAIN="${DOMAINS[$((CHOICE-1))]}"
      NEW_CERT=0
      break
    elif [[ "$CHOICE" -eq "$(( ${#DOMAINS[@]} + 1 ))" ]]; then
      read -rp "Enter new domain: " DOMAIN
      NEW_CERT=1
      break
    fi
  done
fi

log "Using domain: $DOMAIN"

### ===== SYSTEM PREP =====
log "Cleaning old ocserv if exists"
systemctl stop ocserv 2>/dev/null || true
apt-get purge -y ocserv || true
rm -rf /etc/ocserv

log "Installing dependencies"
apt-get update -y
apt-get install -y ocserv iptables iproute2 curl

### ===== CERTBOT (ONLY IF NEEDED) =====
if [[ "$NEW_CERT" == "1" ]]; then
  log "Issuing new certificate"
  apt-get install -y snapd
  snap install core || true
  snap refresh core
  snap install --classic certbot
  ln -sf /snap/bin/certbot /usr/bin/certbot

  systemctl stop apache2 nginx 2>/dev/null || true
  certbot certonly --standalone \
    --agree-tos \
    --register-unsafely-without-email \
    -d "$DOMAIN" \
    --non-interactive
fi

CERT="$CERT_PATH/$DOMAIN/fullchain.pem"
KEY="$CERT_PATH/$DOMAIN/privkey.pem"

if [[ ! -f "$CERT" || ! -f "$KEY" ]]; then
  log "Certificate files missing — abort"
  exit 1
fi

### ===== OCSERV CONFIG =====
log "Configuring ocserv"
mkdir -p /etc/ocserv

log "Configuring ocserv (FINAL balanced config)"

cat > /etc/ocserv/ocserv.conf <<EOF
# ---------- PROTOCOL ----------
proto = udp
tcp-port = 443
udp-port = 443
switch-to-tcp-timeout = 8

# ---------- PROCESS ----------
run-as-user = nobody
run-as-group = daemon
socket-file = /var/run/ocserv-socket
pid-file = /var/run/ocserv.pid
device = vpns

# ---------- CERTS ----------
ca-cert = /etc/ssl/certs/ssl-cert-snakeoil.pem
server-cert = $CERT
server-key  = $KEY

# ---------- NETWORK / MTU ----------
mtu = 1420
try-mtu-discovery = false
dtls-legacy = true
isolate-workers = true

# ---------- KEEPALIVE / DPD ----------
keepalive = 1800
dpd = 40
mobile-dpd = 40

# ---------- TLS (OLD + NEW DEVICES SAFE) ----------
# Allows TLS 1.0/1.1 for very old phones
# New phones will auto-use TLS 1.2 / 1.3
#tls-priorities = "PERFORMANCE:%SERVER_PRECEDENCE:%COMPAT:-VERS-SSL3.0"
#tls-priorities = "NORMAL:%SERVER_PRECEDENCE:-VERS-TLS1.0:-VERS-TLS1.1:-VERS-SSL3.0"
#tls-priorities = "NORMAL:%SERVER_PRECEDENCE:-VERS-SSL3.0:-VERS-TLS1.0:-VERS-TLS1.1:+VERS-TLS1.2:+VERS-TLS1.3"
#tls-priorities = "NORMAL:%SERVER_PRECEDENCE"
#tls-priorities = "SECURE256:+SECURE128:-VERS-ALL:+VERS-TLS1.0:+COMP-NULL"
#tls-priorities = "NORMAL:%SERVER_PRECEDENCE:%COMPAT:-VERS-SSL3.0"

tls-priorities = "NORMAL:%SERVER_PRECEDENCE:-VERS-SSL3.0"

# ---------- AUTH ----------
auth-timeout = 400
min-reauth-time = 100
rekey-time = 172800
rekey-method = ssl

use-utmp = true
use-occtl = true
cert-user-oid = 0.9.2342.19200300.100.1.1

# ---------- COMPRESSION ----------
compression = true
no-compress-limit = 50

# ---------- IP POOL ----------
predictable-ips = true
ipv4-network = 191.10.10.0/21

# ---------- DNS (BLOCK SAFE ORDER) ----------
dns = 1.1.1.1
dns = 8.8.8.8
dns-timeout = 2
dns-retries = 1
tunnel-all-dns = false

# ---------- CLIENT LIMITS ----------
max-clients = 0
max-same-clients = 20000

# ---------- COMPAT ----------
cisco-client-compat = true

# ---------- AUTH BACKEND ----------
auth = plain[passwd=/etc/ocserv/ocpasswd]
# auth = "pam"
EOF

touch /etc/ocserv/ocpasswd
chmod 600 /etc/ocserv/ocpasswd

### ===== NETWORK (NO-STUCK FIX) =====
log "Enabling IP forward"
sysctl -w net.ipv4.ip_forward=1
grep -q ip_forward /etc/sysctl.conf || echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf

IFACE=$(ip route get 8.8.8.8 | awk '{print $5}')

log "Setting iptables (stable NAT)"
iptables -t nat -C POSTROUTING -o "$IFACE" -j MASQUERADE 2>/dev/null || \
iptables -t nat -A POSTROUTING -o "$IFACE" -j MASQUERADE

iptables -C INPUT -p tcp --dport 443 -j ACCEPT 2>/dev/null || \
iptables -A INPUT -p tcp --dport 443 -j ACCEPT

iptables -C INPUT -p udp --dport 443 -j ACCEPT 2>/dev/null || \
iptables -A INPUT -p udp --dport 443 -j ACCEPT

iptables-save > /etc/iptables.rules

cat > /etc/systemd/system/iptables-restore.service <<EOF
[Unit]
Before=network-pre.target
Wants=network-pre.target

[Service]
Type=oneshot
ExecStart=/sbin/iptables-restore /etc/iptables.rules
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable iptables-restore

### ===== START SERVICE =====
log "Starting ocserv"
systemctl restart ocserv
systemctl enable ocserv

echo
echo "======================================"
echo " OCServ READY"
echo " Domain : $DOMAIN"
echo " Port   : 443"
echo " Status :"
systemctl --no-pager status ocserv
echo "======================================"
