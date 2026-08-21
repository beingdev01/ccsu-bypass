#!/usr/bin/env bash
#
# add-device.sh — add (or remove) a device on a running server, no downtime.
#
#   sudo ./add-device.sh                 # add a device, print its link + QR
#   sudo ./add-device.sh --name phone    # label it
#   sudo ./add-device.sh --remove <uuid> # revoke a device
#   sudo ./add-device.sh --list          # list device UUIDs
#
# Edits /etc/xray/config.json in place and reloads xray (~1s blip).
set -euo pipefail
[ "$(id -u)" = 0 ] || exec sudo -E bash "$0" "$@"

CFG=/etc/xray/config.json
[ -f "$CFG" ] || { echo "No $CFG — run setup.sh first."; exit 1; }

ACTION=add; NAME=""; TARGET=""
while [ $# -gt 0 ]; do
  case "$1" in
    --name)   NAME="$2"; shift 2;;
    --remove) ACTION=remove; TARGET="$2"; shift 2;;
    --list)   ACTION=list; shift;;
    *) echo "unknown arg: $1"; exit 1;;
  esac
done

DOMAIN="$(grep -o '/etc/letsencrypt/live/[^/]*' "$CFG" | head -1 | sed 's#.*/##')"
PORT="$(grep -o '"port"[[:space:]]*:[[:space:]]*[0-9]*' "$CFG" | head -1 | grep -o '[0-9]*')"
WS_PATH="$(grep -o '"path"[[:space:]]*:[[:space:]]*"[^"]*"' "$CFG" | head -1 | sed 's/.*"\(\/[^"]*\)"/\1/')"
ENC_PATH="$(printf '%s' "$WS_PATH" | sed 's|/|%2F|g')"

link(){ echo "vless://$1@${DOMAIN}:${PORT}?encryption=none&security=tls&sni=${DOMAIN}&fp=chrome&type=ws&host=${DOMAIN}&path=${ENC_PATH}#${2:-CCSU}"; }

case "$ACTION" in
  list)
    python3 - "$CFG" <<'PY'
import json,sys
c=json.load(open(sys.argv[1]))
for i,cl in enumerate(c['inbounds'][0]['settings']['clients'],1):
    print(f"  device {i}: {cl['id']}  {cl.get('email','')}")
PY
    ;;
  add)
    NEW="$(cat /proc/sys/kernel/random/uuid)"
    python3 - "$CFG" "$NEW" "$NAME" <<'PY'
import json,sys
p,new,name=sys.argv[1],sys.argv[2],sys.argv[3]
c=json.load(open(p))
cl={'id':new}
if name: cl['email']=name
c['inbounds'][0]['settings']['clients'].append(cl)
json.dump(c,open(p,'w'),indent=2)
PY
    /usr/local/bin/xray -test -config "$CFG" >/dev/null 2>&1 || { echo "config invalid, aborting"; exit 1; }
    systemctl restart xray
    echo "Added device ${NAME:-(unnamed)}: ${NEW}"
    echo "Share link:"; echo "  $(link "$NEW" "${NAME:-CCSU-new}")"
    command -v qrencode >/dev/null 2>&1 && qrencode -t ANSIUTF8 "$(link "$NEW" "${NAME:-CCSU-new}")"
    ;;
  remove)
    [ -n "$TARGET" ] || { echo "--remove needs a UUID"; exit 1; }
    python3 - "$CFG" "$TARGET" <<'PY'
import json,sys
p,tgt=sys.argv[1],sys.argv[2]
c=json.load(open(p))
cl=c['inbounds'][0]['settings']['clients']
n=len(cl)
cl[:]=[x for x in cl if x['id']!=tgt]
json.dump(c,open(p,'w'),indent=2)
print(f"removed {n-len(cl)} client(s)")
PY
    /usr/local/bin/xray -test -config "$CFG" >/dev/null 2>&1 || { echo "config invalid, aborting"; exit 1; }
    systemctl restart xray
    echo "Revoked ${TARGET}"
    ;;
esac
