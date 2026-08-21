#!/usr/bin/env bash
#
# ccsu-bypass — one-shot VPS bootstrap for VLESS + WS + TLS behind a real domain.
#
# Sets up the "Direct TLS" architecture proven in the engineering writeup:
#   client (uTLS Chrome)  --HTTPS/WSS-->  Sophos  -->  this VPS (Xray, real cert)
#
# Tuned for a small Oracle "Always Free" box (1 GB RAM, ARM or AMD). Xray idles
# at ~20-40 MB, so 1 GB is plenty.
#
# Usage:
#   sudo DOMAIN=vpn.codecriet.dev UUID=$(cat /proc/sys/kernel/random/uuid) ./setup.sh
#
# Prereqs (do these in the Cloudflare / Oracle consoles BEFORE running):
#   1. Cloudflare DNS: A record  vpn -> <your VPS public IP>, "DNS only" (grey cloud).
#      (Grey cloud = direct TLS = ~60 ms. Orange/proxied works too but adds ~400 ms;
#       if you switch to proxied later, see README "Cloudflare modes".)
#   2. Oracle console: VCN Security List / NSG ingress rule for TCP 443 and TCP 80
#      from 0.0.0.0/0 (80 is only needed for the cert challenge & renewals).
set -euo pipefail

DOMAIN="${DOMAIN:-vpn.codecriet.dev}"
UUID="${UUID:-}"
WS_PATH="${WS_PATH:-/cdn}"
PORT="${PORT:-443}"
EMAIL="${EMAIL:-admin@${DOMAIN#*.}}"   # for Let's Encrypt expiry notices
APP_DIR="$(cd "$(dirname "$0")" && pwd)"

need_root() { [ "$(id -u)" = "0" ] || { echo "Run as root (sudo)."; exit 1; }; }
need_root

if [ -z "$UUID" ]; then
  UUID="$(cat /proc/sys/kernel/random/uuid)"
  echo "[gen] No UUID supplied. Generated: $UUID"
fi

echo "==> DOMAIN=$DOMAIN  PORT=$PORT  WS_PATH=$WS_PATH"

# --- 1. Packages -------------------------------------------------------------
echo "==> Installing packages..."
if command -v apt-get >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y curl unzip certbot nodejs iptables ca-certificates
elif command -v dnf >/dev/null 2>&1; then
  dnf install -y curl unzip certbot nodejs iptables ca-certificates
else
  echo "Unsupported distro (need apt or dnf)."; exit 1
fi

# --- 2. Firewall: allow 80 (cert) + 443 (proxy) ------------------------------
# Oracle images ship a restrictive iptables INPUT chain. Insert accepts ABOVE
# the default REJECT rule so they actually take effect.
echo "==> Opening ports 80 and 443 in the host firewall..."
open_port() {
  local p="$1"
  if ! iptables -C INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null; then
    iptables -I INPUT -p tcp --dport "$p" -j ACCEPT
  fi
}
open_port 80
open_port "$PORT"
# Persist iptables across reboots (best-effort; method varies by distro).
if command -v netfilter-persistent >/dev/null 2>&1; then
  netfilter-persistent save || true
elif command -v service >/dev/null 2>&1 && [ -d /etc/iptables ]; then
  iptables-save > /etc/iptables/rules.v4 || true
else
  mkdir -p /etc/iptables && iptables-save > /etc/iptables/rules.v4 || true
fi
# If firewalld is the active manager (Oracle Linux), add there too.
if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
  firewall-cmd --permanent --add-port=80/tcp || true
  firewall-cmd --permanent --add-port="${PORT}"/tcp || true
  firewall-cmd --reload || true
fi

# --- 3. Let's Encrypt certificate (standalone HTTP-01 on port 80) ------------
CERT="/etc/letsencrypt/live/${DOMAIN}/fullchain.pem"
if [ -f "$CERT" ]; then
  echo "==> Certificate already present for ${DOMAIN}, skipping issuance."
else
  echo "==> Obtaining Let's Encrypt certificate for ${DOMAIN} (port 80 must be reachable)..."
  # Nothing should be bound to :80 yet at this point.
  certbot certonly --standalone --non-interactive --agree-tos \
    -m "$EMAIL" -d "$DOMAIN"
fi

# --- 4. Install xray binary (arch-aware) -------------------------------------
echo "==> Installing xray..."
ARCH="$(uname -m)"
case "$ARCH" in
  x86_64|amd64)  ASSET="Xray-linux-64.zip" ;;
  aarch64|arm64) ASSET="Xray-linux-arm64-v8a.zip" ;;
  armv7l)        ASSET="Xray-linux-arm32-v7a.zip" ;;
  *) echo "Unsupported arch: $ARCH"; exit 1 ;;
esac
TMP="$(mktemp -d)"
curl -fsSL "https://github.com/XTLS/Xray-core/releases/latest/download/${ASSET}" -o "${TMP}/xray.zip"
unzip -o "${TMP}/xray.zip" xray -d "${TMP}" >/dev/null
install -m 0755 "${TMP}/xray" /usr/local/bin/xray
rm -rf "$TMP"
echo "    xray -> $(/usr/local/bin/xray version | head -n1)"

# --- 5. Write the Xray server config -----------------------------------------
# Same shape index.js generates, written inline so the bootstrap is fully
# deterministic and needs no node runtime to (re)generate it.
echo "==> Generating /etc/xray/config.json ..."
mkdir -p /etc/xray
cat > /etc/xray/config.json <<JSON
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": ${PORT},
      "protocol": "vless",
      "settings": { "clients": [ { "id": "${UUID}" } ], "decryption": "none" },
      "streamSettings": {
        "network": "ws",
        "security": "tls",
        "tlsSettings": {
          "alpn": ["h2", "http/1.1"],
          "minVersion": "1.2",
          "certificates": [
            {
              "certificateFile": "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem",
              "keyFile": "/etc/letsencrypt/live/${DOMAIN}/privkey.pem"
            }
          ]
        },
        "wsSettings": { "path": "${WS_PATH}" },
        "sockopt": { "tcpNoDelay": true, "tcpFastOpen": true, "tcpcongestion": "bbr" }
      }
    }
  ],
  "outbounds": [
    { "protocol": "freedom", "tag": "direct", "streamSettings": { "sockopt": { "tcpNoDelay": true, "tcpcongestion": "bbr" } } },
    { "protocol": "blackhole", "tag": "block" }
  ]
}
JSON

# --- 5b. Low-latency kernel/network tuning -----------------------------------
# This box does one job (the proxy), so tune the whole stack for interactive
# latency, not throughput fairness:
#   BBR + fq        -> low queueing delay, no bufferbloat under load
#   tcp_fastopen=3  -> skip a round trip on both client and server sockets
#   slow_start_after_idle=0 -> don't collapse the window on brief idle (gaming)
#   mtu_probing=1   -> avoid black-hole stalls if the path MTU is odd (Oracle)
#   low_latency/notsent buffers -> keep the send queue short
echo "==> Applying low-latency network tuning..."
modprobe tcp_bbr 2>/dev/null || true
echo 'tcp_bbr' > /etc/modules-load.d/bbr.conf 2>/dev/null || true
cat > /etc/sysctl.d/99-ccsu-latency.conf <<'SYSCTL'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_notsent_lowat=16384
net.core.rmem_max=16777216
net.core.wmem_max=16777216
net.ipv4.tcp_rmem=4096 131072 16777216
net.ipv4.tcp_wmem=4096 131072 16777216
SYSCTL
sysctl --system >/dev/null 2>&1 || true
echo "    congestion control now: $(sysctl -n net.ipv4.tcp_congestion_control)"

# --- 6. systemd service ------------------------------------------------------
echo "==> Installing systemd service..."
cat > /etc/systemd/system/xray.service <<UNIT
[Unit]
Description=Xray VLESS+WS+TLS (ccsu-bypass)
After=network.target

[Service]
ExecStart=/usr/local/bin/xray run -config /etc/xray/config.json
Restart=always
RestartSec=3
# Let xray bind :443 without running as full root.
AmbientCapabilities=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable xray
systemctl restart xray

# --- 7. Cert renewal reloads xray -------------------------------------------
# Let's Encrypt auto-renews; xray must restart to pick up the new cert.
mkdir -p /etc/letsencrypt/renewal-hooks/deploy
cat > /etc/letsencrypt/renewal-hooks/deploy/reload-xray.sh <<'HOOK'
#!/usr/bin/env bash
systemctl restart xray
HOOK
chmod +x /etc/letsencrypt/renewal-hooks/deploy/reload-xray.sh

# --- 8. Done: print the share link ------------------------------------------
echo
echo "======================================================================"
echo " ccsu-bypass is running."
systemctl --no-pager --full status xray | sed -n '1,4p' || true
echo
echo " Save these — you need them on every client:"
echo "   DOMAIN : ${DOMAIN}"
echo "   UUID   : ${UUID}"
echo "   PORT   : ${PORT}"
echo "   PATH   : ${WS_PATH}"
echo
ENC_PATH="$(printf '%s' "$WS_PATH" | sed 's|/|%2F|g')"
echo " VLESS share link (import in v2rayNG / v2rayN / Hiddify / Nekobox):"
echo "   vless://${UUID}@${DOMAIN}:${PORT}?encryption=none&security=tls&sni=${DOMAIN}&fp=chrome&type=ws&host=${DOMAIN}&path=${ENC_PATH}#CCSU-Bypass"
echo "======================================================================"
echo
echo " Quick self-test from the VPS (should print HTTP 400 Bad Request — that"
echo " means xray is answering a non-WebSocket GET, which is correct):"
echo "   curl -sk https://${DOMAIN}:${PORT}${WS_PATH} -o /dev/null -w '%{http_code}\\n'"
