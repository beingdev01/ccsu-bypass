#!/usr/bin/env bash
#
# add-quic.sh — add an XHTTP/HTTP-3 (QUIC over UDP) inbound ALONGSIDE the
# existing WebSocket one. Nothing existing is removed: TCP/443 keeps serving
# every current device, and you migrate them one at a time.
#
# WHY THIS EXISTS
#   The WebSocket transport carries your UDP traffic (WhatsApp calls, games)
#   inside TCP. When a packet is lost, TCP stalls everything behind it until it
#   is retransmitted — head-of-line blocking — and a call's own loss concealment
#   never gets to do its job. That is a property of the transport, not a tuning
#   knob. QUIC carries UDP as datagrams, so a lost packet stays lost instead of
#   freezing the stream.
#
# VERIFIED IN THE LAB against this exact xray build (26.3.27):
#   - the H3 inbound binds UDP only (TCP on the same port is refused), so it
#     does NOT collide with the existing WS inbound on TCP/443
#   - a full request completed through the QUIC tunnel (HTTP 200)
#   - SOCKS5 UDP ASSOCIATE worked end to end: 10/10 datagrams echoed
#
# PREREQUISITES
#   1. Oracle VCN Ingress rule: Source 0.0.0.0/0, Protocol UDP, Dest port 443
#   2. udp-probe.sh confirmed UDP actually reaches this box
#
#   sudo ./add-quic.sh
set -euo pipefail
[ "$(id -u)" = 0 ] || exec sudo -E bash "$0" "$@"

CFG=/etc/xray/config.json
[ -f "$CFG" ] || { echo "No $CFG — run setup.sh first."; exit 1; }
BACKUP="/etc/xray/config.json.pre-quic.$(date +%s)"
cp "$CFG" "$BACKUP"
echo "backup: $BACKUP"

g=$'\033[1;32m'; y=$'\033[1;33m'; r=$'\033[1;31m'; z=$'\033[0m'
ok(){ echo "${g}  ok${z} $*"; }; warn(){ echo "${y}  !!${z} $*"; }; bad(){ echo "${r} err${z} $*"; }

# --- open UDP in the host firewall ------------------------------------------
PORT="$(python3 -c "
import json;c=json.load(open('$CFG'))
print(c['inbounds'][0].get('port',443))")"
iptables -C INPUT -p udp --dport "$PORT" -j ACCEPT 2>/dev/null || \
  iptables -I INPUT -p udp --dport "$PORT" -j ACCEPT
command -v ip6tables >/dev/null 2>&1 && {
  ip6tables -C INPUT -p udp --dport "$PORT" -j ACCEPT 2>/dev/null || \
  ip6tables -I INPUT -p udp --dport "$PORT" -j ACCEPT 2>/dev/null || true; }
command -v netfilter-persistent >/dev/null 2>&1 && netfilter-persistent save >/dev/null 2>&1 || true
ok "UDP/${PORT} opened in the host firewall"
echo "     (the Oracle VCN Ingress rule for UDP/${PORT} is a SEPARATE layer)"

# --- add the H3 inbound, reusing the same UUIDs, domain, cert and path -------
python3 - "$CFG" <<'PY'
import json,sys
p=sys.argv[1]; c=json.load(open(p))
base=c['inbounds'][0]
ss=base['streamSettings']
tls=ss['tlsSettings']
port=base.get('port',443)
path=ss.get('wsSettings',{}).get('path','/cdn')

# drop any previous quic inbound so this script is re-runnable
c['inbounds']=[i for i in c['inbounds'] if i.get('tag')!='quic-in']

quic={
  "tag":"quic-in",
  "listen":"0.0.0.0",
  "port":port,                      # UDP/443 — no clash with TCP/443
  "protocol":"vless",
  "settings":{"clients":base['settings']['clients'],"decryption":"none"},
  "streamSettings":{
    "network":"xhttp",
    "security":"tls",
    "tlsSettings":{
      "alpn":["h3"],                # h3 ONLY -> xray binds UDP (QUIC)
      "minVersion":"1.3",           # QUIC requires TLS 1.3
      "certificates":tls["certificates"]
    },
    "xhttpSettings":{"path":path,"mode":"auto"}
  }
}
c['inbounds'].append(quic)
json.dump(c,open(p,'w'),indent=2)
print(f"  added quic-in on UDP/{port}, path {path}, {len(base['settings']['clients'])} client(s)")
PY

# --- validate and restart ----------------------------------------------------
if ! /usr/local/bin/xray -test -config "$CFG" >/dev/null 2>&1; then
  bad "xray rejected the new config — rolling back"
  cp "$BACKUP" "$CFG"; systemctl restart xray; exit 1
fi
ok "config valid"
systemctl restart xray; sleep 2
systemctl is-active --quiet xray || { bad "xray failed to start — rolling back"; cp "$BACKUP" "$CFG"; systemctl restart xray; exit 1; }
ok "xray restarted"

# --- verify BOTH transports are actually live -------------------------------
echo
echo "=== verifying both transports ==="
DOMAIN="$(grep -o '/etc/letsencrypt/live/[^/]*' "$CFG" | head -1 | sed 's#.*/##')"
UP="$(curl -sk --max-time 10 --resolve "${DOMAIN}:${PORT}:127.0.0.1" -o /dev/null -w '%{http_code}' \
   -H 'Connection: Upgrade' -H 'Upgrade: websocket' \
   -H "Sec-WebSocket-Key: $(head -c16 /dev/urandom|base64)" -H 'Sec-WebSocket-Version: 13' \
   "https://${DOMAIN}:${PORT}$(python3 -c "
import json;c=json.load(open('$CFG'))
print(c['inbounds'][0]['streamSettings'].get('wsSettings',{}).get('path','/cdn'))")" 2>/dev/null || true)"
[ "${UP: -3}" = "101" ] && ok "TCP/WebSocket still healthy (101) — existing devices unaffected" \
                        || warn "WS check returned ${UP: -3} (expected 101)"

if command -v ss >/dev/null 2>&1; then
  ss -lunH 2>/dev/null | grep -q ":${PORT}\b" && ok "UDP/${PORT} is bound (QUIC listening)" \
                                              || warn "UDP/${PORT} not shown as bound"
fi

echo
echo "${g}Done.${z} Both transports are live on port ${PORT}:"
echo "  TCP/${PORT}  -> WebSocket  (your existing links keep working)"
echo "  UDP/${PORT}  -> QUIC/H3    (use for calls + games)"
echo
echo "Generate a QUIC client config:   MODE=quic npm run client"
echo "Roll back at any time:           sudo cp ${BACKUP} ${CFG} && sudo systemctl restart xray"
