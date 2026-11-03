#!/usr/bin/env bash
#
# add-xhttp.sh — DISABLED BY DEFAULT. Verified live 2026-09-24: two TCP
# inbounds (WS + XHTTP/H2) on the SAME port 443 clash — the WS handshake hits
# the XHTTP handler and returns 404 (existing devices break). Unlike add-quic.sh
# (QUIC binds UDP-only, no clash), XHTTP/H2 binds TCP and cannot share 443.
#
# Safe options: (a) stay on WS/443 — recommended, zero hassle; (b) XHTTP on a
# SEPARATE TCP port (e.g. XHTTP_PORT=8443) with its own VCN+firewall rule and
# new client links. This script therefore REFUSES same-port use. Pass an
# explicit different port to proceed:
#   sudo XHTTP_PORT=8443 ./add-xhttp.sh
# Roll back: sudo cp <printed-backup> /etc/xray/config.json && sudo systemctl restart xray
set -euo pipefail
[ "$(id -u)" = 0 ] || exec sudo -E bash "$0" "$@"

CFG=/etc/xray/config.json
[ -f "$CFG" ] || { echo "No $CFG — run setup.sh first."; exit 1; }
BACKUP="/etc/xray/config.json.pre-xhttp.$(date +%s)"
cp "$CFG" "$BACKUP"
echo "backup: $BACKUP"

g=$'\033[1;32m'; y=$'\033[1;33m'; r=$'\033[1;31m'; z=$'\033[0m'
ok(){ echo "${g}  ok${z} $*"; }; warn(){ echo "${y}  !!${z} $*"; }; bad(){ echo "${r} err${z} $*"; }

BASE_PORT="$(python3 -c "import json;print(json.load(open('$CFG'))['inbounds'][0].get('port',443))" 2>/dev/null || echo 443)"
HXPORT="${XHTTP_PORT:-}"
if [ -z "$HXPORT" ]; then
  bad "refusing: XHTTP on same TCP/${BASE_PORT} breaks WS (verified 404 live)."
  echo "  Stay on WS/${BASE_PORT} (recommended), or re-run with a separate port:"
  echo "    sudo XHTTP_PORT=8443 ./add-xhttp.sh   # + open VCN/firewall TCP/8443"
  exit 1
fi
if [ "$HXPORT" = "$BASE_PORT" ]; then
  bad "XHTTP_PORT (${HXPORT}) must differ from base port (${BASE_PORT})."
  exit 1
fi
iptables -C INPUT -p tcp --dport "$HXPORT" -j ACCEPT 2>/dev/null || \
  iptables -I INPUT -p tcp --dport "$HXPORT" -j ACCEPT
BACKUP="/etc/xray/config.json.pre-xhttp.$(date +%s)"
cp "$CFG" "$BACKUP"
echo "backup: $BACKUP"

python3 - "$CFG" "$HXPORT" <<'PY'
import json,sys
p,hxport=sys.argv[1],int(sys.argv[2]); c=json.load(open(p))
base=c['inbounds'][0]
ss=base['streamSettings']
tls=ss['tlsSettings']
path=ss.get('wsSettings',{}).get('path') or ss.get('xhttpSettings',{}).get('path','/cdn')
c['inbounds']=[i for i in c['inbounds'] if i.get('tag')!='xhttp-in']
hx={
  "tag":"xhttp-in",
  "listen":"0.0.0.0",
  "port":hxport,
  "protocol":"vless",
  "settings":{"clients":base['settings']['clients'],"decryption":"none"},
  "streamSettings":{
    "network":"xhttp",
    "security":"tls",
    "tlsSettings":{
      "alpn":["h2","http/1.1"],
      "minVersion":"1.2",
      "certificates":tls["certificates"]
    },
    "xhttpSettings":{"path":path,"mode":"auto"},
    "sockopt":ss.get("sockopt",{"tcpCongestion":"bbr","tcpKeepAliveIdle":30,"tcpKeepAliveInterval":10})
  }
}
c['inbounds'].append(hx)
json.dump(c,open(p,'w'),indent=2)
print(f"  staged xhttp-in on TCP/{hxport}, path {path}")
PY

if ! /usr/local/bin/xray -test -config "$CFG" >/dev/null 2>&1; then
  bad "xray rejected the new config — rolling back"
  cp "$BACKUP" "$CFG"; exit 1
fi
ok "config valid (NOT activated — no restart done)"
echo "Activate off-peak: sudo systemctl restart xray && sleep 2 && systemctl is-active xray"
echo "Rollback:          sudo cp $BACKUP $CFG && sudo systemctl restart xray"
