#!/usr/bin/env bash
#
# add-xhttp.sh — STAGED, not yet activated. Adds an XHTTP/H2 (TCP) inbound
# ALONGSIDE WebSocket. Same pattern as add-quic.sh, but needs NO UDP, so it
# works even where Sophos eats all UDP. WS is deprecated upstream; H2 muxes
# better for browsing/text. Gaming neutral.
#
# NOT run automatically: activating restarts xray (~1s blip, drops live
# calls/games). Run off-peak when ready:
#   sudo ./add-xhttp.sh
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

python3 - "$CFG" <<'PY'
import json,sys
p=sys.argv[1]; c=json.load(open(p))
base=c['inbounds'][0]
ss=base['streamSettings']
tls=ss['tlsSettings']
port=base.get('port',443)
path=ss.get('wsSettings',{}).get('path') or ss.get('xhttpSettings',{}).get('path','/cdn')
c['inbounds']=[i for i in c['inbounds'] if i.get('tag')!='xhttp-in']
hx={
  "tag":"xhttp-in",
  "listen":"0.0.0.0",
  "port":port,
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
print(f"  staged xhttp-in on TCP/{port}, path {path}")
PY

if ! /usr/local/bin/xray -test -config "$CFG" >/dev/null 2>&1; then
  bad "xray rejected the new config — rolling back"
  cp "$BACKUP" "$CFG"; exit 1
fi
ok "config valid (NOT activated — no restart done)"
echo "Activate off-peak: sudo systemctl restart xray && sleep 2 && systemctl is-active xray"
echo "Rollback:          sudo cp $BACKUP $CFG && sudo systemctl restart xray"
