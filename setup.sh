#!/usr/bin/env bash
#
# ccsu-bypass — one-command installer for a VLESS + WebSocket + real-TLS proxy.
#
# Architecture (the one that actually worked after everything else failed):
#   real Let's Encrypt cert on YOUR domain, VLESS inside a standard WebSocket,
#   Cloudflare DNS-only (grey cloud) so the connection is DIRECT to the VPS.
#   To Sophos XG it looks exactly like a browser opening an HTTPS WebSocket to a
#   legitimate site — nothing to fingerprint, nothing to block. Direct = full
#   duplex (unlimited up AND down, no CDN throttle) and the lowest ping.
#
# Just run it. It installs everything, asks for what it needs, verifies DNS,
# opens the ports, gets the cert, tunes for latency, writes every file, starts
# the service, and prints a ready-to-import link + QR code.
#
#   bash setup.sh                 # interactive (recommended)
#   DOMAIN=... UUID=... bash setup.sh   # non-interactive (env overrides prompts)
#
set -euo pipefail

# ---- 0. become root ---------------------------------------------------------
if [ "$(id -u)" != "0" ]; then
  echo "Re-running with sudo (needs root to install packages, open ports, bind :443)..."
  exec sudo -E bash "$0" "$@"
fi

# ---- pretty output ----------------------------------------------------------
c_g=$'\033[1;32m'; c_y=$'\033[1;33m'; c_r=$'\033[1;31m'; c_b=$'\033[1;34m'; c_0=$'\033[0m'
info(){ echo "${c_b}==>${c_0} $*"; }
ok(){   echo "${c_g} ok${c_0} $*"; }
warn(){ echo "${c_y} !!${c_0} $*"; }
err(){  echo "${c_r}err${c_0} $*" >&2; }
have(){ command -v "$1" >/dev/null 2>&1; }

# Interactive only when we have a real terminal.
INTERACTIVE=0; [ -t 0 ] && INTERACTIVE=1
ask(){ # ask VAR "prompt" "default"
  local __var="$1" __prompt="$2" __def="${3:-}" __ans=""
  local __cur="${!__var:-}"
  if [ -n "$__cur" ]; then printf -v "$__var" '%s' "$__cur"; return; fi   # env override
  if [ "$INTERACTIVE" = 1 ]; then
    read -r -p "$__prompt [${__def}]: " __ans || true
    printf -v "$__var" '%s' "${__ans:-$__def}"
  else
    printf -v "$__var" '%s' "$__def"
  fi
}

echo
echo "${c_g}ccsu-bypass — VLESS + WS + TLS installer${c_0}"
echo "----------------------------------------"

# ---- 1. gather settings -----------------------------------------------------
ask DOMAIN  "Domain for this proxy (must be a DNS record you control)" "vpn.codescriet.dev"
ask PORT    "TLS port"        "443"
ask WS_PATH "WebSocket path"  "/cdn"
APEX="${DOMAIN#*.}"
ask EMAIL   "Email for Let's Encrypt expiry notices" "admin@${APEX}"
ask DEVICES "How many devices will connect (one credential each)" "8"

# One UUID per device: a lost phone can be revoked without touching the others,
# and per-device credentials keep flows attributable. UUID (single) still works;
# UUIDS (comma list) is what the multi-device config is built from.
if [ -n "${UUIDS:-}" ]; then
  ok "Using provided UUIDS (${UUIDS})"
elif [ -n "${UUID:-}" ]; then
  UUIDS="$UUID"; ok "Using provided UUID: ${UUID}"
else
  UUIDS=""
  for i in $(seq 1 "${DEVICES:-1}"); do
    UUIDS="${UUIDS:+$UUIDS,}$(cat /proc/sys/kernel/random/uuid)"
  done
  ok "Generated ${DEVICES} device UUID(s)"
fi
# First UUID is the "primary" used in single-value spots.
UUID="${UUIDS%%,*}"
APP_DIR="$(cd "$(dirname "$0")" && pwd)"

# ---- 2. install packages ----------------------------------------------------
info "Installing dependencies..."
PKGS="curl unzip certbot iptables ca-certificates qrencode"
if have apt-get; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y -q
  # dnsutils gives us `dig`; ignore if unavailable.
  apt-get install -y -q $PKGS dnsutils || apt-get install -y -q $PKGS
elif have dnf; then
  dnf install -y -q $PKGS bind-utils || dnf install -y -q $PKGS
elif have yum; then
  yum install -y -q $PKGS bind-utils || yum install -y -q $PKGS
else
  err "No supported package manager (need apt, dnf, or yum)."; exit 1
fi
ok "packages installed"

# ---- 3. detect this VPS's public IP -----------------------------------------
info "Detecting public IP..."
PUBIP=""
for u in "https://api.ipify.org" "https://ifconfig.me" "https://checkip.amazonaws.com"; do
  PUBIP="$(curl -fsS --max-time 8 "$u" 2>/dev/null | tr -d '[:space:]')" && [ -n "$PUBIP" ] && break
done
# Oracle metadata fallback.
if [ -z "$PUBIP" ]; then
  PUBIP="$(curl -fsS --max-time 5 -H 'Authorization: Bearer Oracle' \
    http://169.254.169.254/opc/v2/vnics/ 2>/dev/null | grep -o '"publicIp"[^,]*' | head -1 | grep -o '[0-9.]\+' || true)"
fi
[ -n "$PUBIP" ] && ok "public IP: ${PUBIP}" || warn "could not auto-detect public IP (continuing)"

# ---- 4. DNS pre-flight: DOMAIN must point straight at this VPS ---------------
resolve_ip(){
  local h="$1"
  if have dig; then dig +short A "$h" | grep -Eo '^[0-9.]+$' | tail -1; return; fi
  if have getent; then getent hosts "$h" | awk '{print $1; exit}'; return; fi
  python3 - "$h" <<'PY' 2>/dev/null
import socket,sys
try: print(socket.gethostbyname(sys.argv[1]))
except Exception: pass
PY
}
resolve_aaaa(){ have dig && dig +short AAAA "$1" | grep -E '^[0-9a-fA-F:]+$' | tail -1 || true; }
info "Checking that ${DOMAIN} points to this VPS..."
if [ -n "$PUBIP" ]; then
  while true; do
    RIP="$(resolve_ip "$DOMAIN" || true)"
    if [ "$RIP" = "$PUBIP" ]; then ok "${DOMAIN} -> ${RIP} (correct, DNS-only)"; break; fi
    echo
    warn "${DOMAIN} currently resolves to '${RIP:-<nothing>}', not ${PUBIP}."
    echo "    In Cloudflare (DNS tab) create/fix this record, then it must be GREY cloud:"
    echo
    echo "      Type: A   Name: ${DOMAIN%%.*}   Content: ${PUBIP}   Proxy: DNS only (grey)"
    echo
    echo "    Grey cloud = direct = best ping + unlimited up/down, and it's REQUIRED"
    echo "    for the certificate step below to succeed."
    if [ "$INTERACTIVE" = 1 ]; then
      read -r -p "    Press Enter to re-check, or type 'skip' to proceed anyway: " a || true
      [ "$a" = "skip" ] && { warn "proceeding without a verified DNS match"; break; }
    else
      warn "non-interactive: proceeding; certbot will fail if DNS is wrong."; break
    fi
  done
else
  warn "skipping DNS verification (no public IP detected)"
fi

# A stray AAAA record is a classic silent breaker: clients prefer IPv6, so they
# would connect somewhere other than the address we just verified.
AAAA="$(resolve_aaaa "$DOMAIN")"
if [ -n "$AAAA" ]; then
  if ip -6 addr show scope global 2>/dev/null | grep -q "${AAAA%%/*}"; then
    ok "AAAA ${AAAA} is this host (fine)"
  else
    warn "${DOMAIN} also has an AAAA record: ${AAAA}"
    warn "Clients PREFER IPv6 and would connect there instead of ${PUBIP}."
    warn "Delete that AAAA record in Cloudflare unless it is this VPS."
  fi
fi

# ---- 5. host firewall: open 80 (cert) + PORT (proxy) ------------------------
info "Opening ports 80 and ${PORT} in the host firewall..."
open_port(){ local p="$1"; iptables -C INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport "$p" -j ACCEPT; }
open_port6(){ local p="$1"; have ip6tables || return 0
  ip6tables -C INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null || ip6tables -I INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null || true; }
open_port 80; open_port "$PORT"
open_port6 80; open_port6 "$PORT"
if have netfilter-persistent; then netfilter-persistent save >/dev/null 2>&1 || true
else
  mkdir -p /etc/iptables
  iptables-save  > /etc/iptables/rules.v4 2>/dev/null || true
  have ip6tables-save && ip6tables-save > /etc/iptables/rules.v6 2>/dev/null || true
fi
if have firewall-cmd && firewall-cmd --state >/dev/null 2>&1; then
  firewall-cmd --permanent --add-port=80/tcp >/dev/null 2>&1 || true
  firewall-cmd --permanent --add-port="${PORT}"/tcp >/dev/null 2>&1 || true
  firewall-cmd --reload >/dev/null 2>&1 || true
fi
ok "firewall rules in place"

# ---- 5b. time sync (a skewed clock breaks TLS validation and cert issuance) --
info "Checking clock sync..."
if have timedatectl; then
  timedatectl set-ntp true >/dev/null 2>&1 || true
  if timedatectl show -p NTPSynchronized --value 2>/dev/null | grep -q yes; then ok "clock synced"
  else warn "clock not confirmed synced — if TLS fails later, check 'timedatectl'"; fi
else
  warn "timedatectl unavailable; ensure the system clock is correct"
fi

# ---- 6. free port 80, then get the certificate ------------------------------
CERT="/etc/letsencrypt/live/${DOMAIN}/fullchain.pem"
if [ -f "$CERT" ]; then
  ok "certificate already present for ${DOMAIN}"
else
  info "Freeing port 80 for the certificate challenge..."
  systemctl stop xray 2>/dev/null || true
  systemctl stop x-ui 2>/dev/null || true
  # Anything else squatting on :80?
  if have ss && ss -ltnH '( sport = :80 )' | grep -q ':80'; then
    warn "something is still listening on :80 — cert issuance may fail."
    ss -ltnp '( sport = :80 )' || true
  fi
  info "Requesting Let's Encrypt certificate for ${DOMAIN}..."
  if ! certbot certonly --standalone --non-interactive --agree-tos -m "$EMAIL" -d "$DOMAIN"; then
    echo
    err "Certificate issuance failed. It is almost always one of these:"
    echo "  1. Oracle VCN / NSG has no INGRESS rule for TCP 80 from 0.0.0.0/0."
    echo "     Let's Encrypt must reach this box on port 80 to verify the domain."
    echo "     Fix in the Oracle console: Networking > VCN > Security List > Add Ingress."
    echo "  2. ${DOMAIN} does not resolve to ${PUBIP:-this VPS} yet, or is still"
    echo "     ORANGE-clouded in Cloudflare. It must be GREY (DNS only) right now."
    echo "  3. Something else is listening on port 80 (check: ss -ltnp | grep :80)."
    echo "  4. Rate limit: 5 failures/hour per domain. Wait an hour if you retried a lot."
    echo
    echo "  Re-run this script once fixed — it is safe to run repeatedly."
    exit 1
  fi
  ok "certificate issued"
fi

# ---- 7. install xray (arch-aware) -------------------------------------------
info "Installing xray..."
case "$(uname -m)" in
  x86_64|amd64)  ASSET="Xray-linux-64.zip" ;;
  aarch64|arm64) ASSET="Xray-linux-arm64-v8a.zip" ;;
  armv7l)        ASSET="Xray-linux-arm32-v7a.zip" ;;
  *) err "unsupported arch: $(uname -m)"; exit 1 ;;
esac
TMP="$(mktemp -d)"
curl -fsSL "https://github.com/XTLS/Xray-core/releases/latest/download/${ASSET}" -o "${TMP}/xray.zip"
unzip -o "${TMP}/xray.zip" xray -d "${TMP}" >/dev/null
install -m 0755 "${TMP}/xray" /usr/local/bin/xray
rm -rf "$TMP"
ok "xray -> $(/usr/local/bin/xray version 2>/dev/null | head -n1)"

# ---- 8. low-latency kernel/network tuning -----------------------------------
info "Applying low-latency network tuning (BBR, fq, buffers)..."
modprobe tcp_bbr 2>/dev/null || true
echo 'tcp_bbr' > /etc/modules-load.d/bbr.conf 2>/dev/null || true
cat > /etc/sysctl.d/99-ccsu-latency.conf <<'SYSCTL'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_notsent_lowat=16384
net.core.rmem_max=16777216
net.core.wmem_max=16777216
net.ipv4.tcp_rmem=4096 131072 16777216
net.ipv4.tcp_wmem=4096 131072 16777216
SYSCTL
sysctl --system >/dev/null 2>&1 || true
ok "congestion control: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"

# ---- 9. write the server config ---------------------------------------------
info "Writing /etc/xray/config.json ..."
mkdir -p /etc/xray
# Build the clients[] JSON from every device UUID.
CLIENTS_JSON="$(python3 - "$UUIDS" <<'PY'
import sys
ids=[u.strip() for u in sys.argv[1].split(',') if u.strip()]
print(','.join('{ "id": "%s" }' % u for u in ids))
PY
)"
cat > /etc/xray/config.json <<JSON
{
  "log": { "loglevel": "warning", "access": "none" },
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": ${PORT},
      "protocol": "vless",
      "settings": { "clients": [ ${CLIENTS_JSON} ], "decryption": "none" },
      "streamSettings": {
        "network": "ws",
        "security": "tls",
        "tlsSettings": {
          "alpn": ["http/1.1"],
          "minVersion": "1.2",
          "certificates": [
            {
              "certificateFile": "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem",
              "keyFile": "/etc/letsencrypt/live/${DOMAIN}/privkey.pem"
            }
          ]
        },
        "wsSettings": { "path": "${WS_PATH}" },
        "sockopt": { "tcpCongestion": "bbr" }
      }
    }
  ],
  "outbounds": [
    { "protocol": "freedom", "tag": "direct", "streamSettings": { "sockopt": { "tcpCongestion": "bbr" } } },
    { "protocol": "blackhole", "tag": "block" }
  ]
}
JSON
/usr/local/bin/xray -test -config /etc/xray/config.json >/dev/null 2>&1 \
  && ok "config valid" || { err "xray rejected the config"; /usr/local/bin/xray -test -config /etc/xray/config.json; exit 1; }

# ---- 10. systemd service ----------------------------------------------------
info "Installing + starting systemd service..."
cat > /etc/systemd/system/xray.service <<'UNIT'
[Unit]
Description=Xray VLESS+WS+TLS (ccsu-bypass)
# network-online (not just network.target) so the cert/DNS are usable at boot.
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/local/bin/xray run -config /etc/xray/config.json
Restart=always
RestartSec=3
# Don't hammer forever on a broken config/cert — surface the failure instead.
StartLimitIntervalSec=300
StartLimitBurst=10
AmbientCapabilities=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable xray >/dev/null 2>&1
systemctl restart xray
sleep 1
systemctl is-active --quiet xray && ok "xray is running" || { err "xray failed to start"; journalctl -u xray --no-pager -n 20; exit 1; }

# ---- 11. cert renewal reloads xray ------------------------------------------
mkdir -p /etc/letsencrypt/renewal-hooks/deploy
cat > /etc/letsencrypt/renewal-hooks/deploy/reload-xray.sh <<'HOOK'
#!/usr/bin/env bash
systemctl restart xray
HOOK
chmod +x /etc/letsencrypt/renewal-hooks/deploy/reload-xray.sh
ok "auto-renewal hook installed"

# ---- 11b. self-healing watchdog (systemd timer) -----------------------------
# Proves the tunnel actually serves (WS upgrade -> 101), not just that the
# process is alive, and fixes the silent-rot cases. Runs every 3 minutes.
info "Installing self-healing watchdog..."
install -m 0755 "${APP_DIR}/healthcheck.sh" /usr/local/bin/ccsu-healthcheck.sh 2>/dev/null \
  || cp "${APP_DIR}/healthcheck.sh" /usr/local/bin/ccsu-healthcheck.sh
chmod +x /usr/local/bin/ccsu-healthcheck.sh
cat > /etc/systemd/system/ccsu-heal.service <<UNIT
[Unit]
Description=ccsu-bypass self-healing check
After=xray.service
[Service]
Type=oneshot
Environment=DOMAIN=${DOMAIN} PORT=${PORT} WS_PATH=${WS_PATH}
ExecStart=/usr/local/bin/ccsu-healthcheck.sh
UNIT
cat > /etc/systemd/system/ccsu-heal.timer <<'UNIT'
[Unit]
Description=Run ccsu-bypass self-healing check every 3 minutes
[Timer]
OnBootSec=120
OnUnitActiveSec=180
AccuracySec=30
[Install]
WantedBy=timers.target
UNIT
systemctl daemon-reload
systemctl enable --now ccsu-heal.timer >/dev/null 2>&1
ok "watchdog active (systemctl list-timers ccsu-heal.timer)"

# ---- 12. build per-device share links + save credentials --------------------
ENC_PATH="$(printf '%s' "$WS_PATH" | sed 's|/|%2F|g')"
# Primary link (first device) for the summary/QR.
LINK="vless://${UUID}@${DOMAIN}:${PORT}?encryption=none&security=tls&sni=${DOMAIN}&fp=chrome&type=ws&host=${DOMAIN}&path=${ENC_PATH}#CCSU-Bypass"

CRED="${APP_DIR}/credentials.txt"
{
  echo "ccsu-bypass credentials  (generated $(date -u '+%Y-%m-%d %H:%M UTC'))"
  echo "DOMAIN : ${DOMAIN}"
  echo "IP     : ${PUBIP:-<unknown>}"
  echo "PORT   : ${PORT}"
  echo "PATH   : ${WS_PATH}"
  echo
  echo "One share link PER DEVICE (give each device its own):"
  n=1
  IFS=','; for u in $UUIDS; do
    u="$(printf '%s' "$u" | tr -d '[:space:]')"
    echo
    echo "  device ${n}  (UUID ${u}):"
    echo "  vless://${u}@${DOMAIN}:${PORT}?encryption=none&security=tls&sni=${DOMAIN}&fp=chrome&type=ws&host=${DOMAIN}&path=${ENC_PATH}#CCSU-dev${n}"
    n=$((n+1))
  done
  unset IFS
} > "$CRED"
chmod 600 "$CRED"

# ---- 13. self-test ----------------------------------------------------------
# Test against 127.0.0.1 via --resolve: hairpin NAT to our own public IP often
# fails on Oracle and would look like a failure when the server is fine.
info "Self-test 1/3: TLS handshake + certificate..."
if curl -s --max-time 10 --resolve "${DOMAIN}:${PORT}:127.0.0.1" \
     "https://${DOMAIN}:${PORT}/" -o /dev/null 2>/dev/null; then
  ok "TLS handshake OK and certificate is trusted for ${DOMAIN}"
else
  # A 400 body still means TLS+cert worked; only a handshake error is fatal.
  if curl -sk --max-time 10 --resolve "${DOMAIN}:${PORT}:127.0.0.1" \
       "https://${DOMAIN}:${PORT}/" -o /dev/null 2>/dev/null; then
    ok "TLS handshake OK (cert chain served)"
  else
    warn "TLS handshake failed locally — check 'journalctl -u xray -n 30'"
  fi
fi

info "Self-test 2/3: WebSocket upgrade on ${WS_PATH} (expect 101)..."
WSKEY="$(head -c 16 /dev/urandom | base64)"
UP="$(curl -sk --max-time 10 --resolve "${DOMAIN}:${PORT}:127.0.0.1" \
      -o /dev/null -w '%{http_code}' \
      -H "Connection: Upgrade" -H "Upgrade: websocket" \
      -H "Sec-WebSocket-Key: ${WSKEY}" -H "Sec-WebSocket-Version: 13" \
      "https://${DOMAIN}:${PORT}${WS_PATH}" 2>/dev/null || true)"
UP="${UP:-000}"; UP="${UP: -3}"
if [ "$UP" = "101" ]; then ok "WebSocket upgrade accepted (101) — path ${WS_PATH} is live"
else warn "WebSocket upgrade returned ${UP} (expected 101). Path mismatch or xray not serving."; fi

info "Self-test 3/3: reachability from OUTSIDE (Oracle VCN check)..."
# This is the layer the OS firewall cannot prove. If this fails but the local
# tests passed, the VCN/NSG ingress rule is missing.
EXT="$(curl -sk --max-time 12 -o /dev/null -w '%{http_code}' \
       "https://${DOMAIN}:${PORT}${WS_PATH}" 2>/dev/null || true)"
EXT="${EXT:-000}"; EXT="${EXT: -3}"
if [ "$EXT" != "000" ]; then
  ok "reachable over the public path (HTTP ${EXT})"
else
  warn "could not reach ${DOMAIN}:${PORT} over the public path."
  warn "If self-tests 1-2 passed, add an Oracle VCN INGRESS rule for TCP ${PORT}"
  warn "from 0.0.0.0/0 (Networking > VCN > Security Lists). Note this test can"
  warn "also fail harmlessly due to hairpin NAT — verify from your laptop."
fi

# ---- 14. done ---------------------------------------------------------------
echo
echo "${c_g}======================================================================${c_0}"
echo "${c_g} ccsu-bypass is live.${c_0}  Credentials saved to: ${CRED}"
echo
echo "  DOMAIN ${DOMAIN}    PORT ${PORT}    PATH ${WS_PATH}"
echo "  UUID   ${UUID}"
echo
echo "  Import this on any device (v2rayNG / v2rayN / Hiddify / Nekobox):"
echo "${c_y}  ${LINK}${c_0}"
echo
if have qrencode; then
  echo "  Or scan on your phone:"
  qrencode -t ANSIUTF8 "$LINK" || true
fi
echo "${c_g}======================================================================${c_0}"
