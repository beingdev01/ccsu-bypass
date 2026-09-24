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

cfg_val(){ # python-based JSON read (grep breaks once a 2nd inbound exists)
  python3 - "$CFG" "$1" <<'PY' 2>/dev/null || true
import json,sys
p,what=sys.argv[1],sys.argv[2]
try:
    c=json.load(open(p)); ib=c['inbounds'][0]; ss=ib.get('streamSettings',{})
    if what=='domain':
        for cert in ss.get('tlsSettings',{}).get('certificates',[]):
            f=cert.get('certificateFile','')
            if '/etc/letsencrypt/live/' in f: print(f.split('/etc/letsencrypt/live/')[1].split('/')[0]); break
    elif what=='port': print(ib.get('port',443))
    elif what=='path':
        print(ss.get('wsSettings',{}).get('path') or ss.get('xhttpSettings',{}).get('path','/cdn'))
except Exception: pass
PY
}

DOMAIN="$(cfg_val domain)"; [ -n "$DOMAIN" ] || DOMAIN="vpn.codescriet.dev"
PORT="$(cfg_val port)";     [ -n "$PORT" ]   || PORT="443"
WS_PATH="$(cfg_val path)";  [ -n "$WS_PATH" ] || WS_PATH="/cdn"
ENC_PATH="$(printf '%s' "$WS_PATH" | sed 's|/|%2F|g')"

backup_cfg(){
  local b="${CFG}.bak.$(date +%s)"
  cp "$CFG" "$b" && echo "$b"
}

# Validate a candidate config file before it ever replaces the live one.
validate_cfg(){ /usr/local/bin/xray -test -config "$1" >/dev/null 2>&1; }

link(){ echo "vless://$1@${DOMAIN}:${PORT}?encryption=none&security=tls&sni=${DOMAIN}&fp=chrome&type=ws&host=${DOMAIN}&path=${ENC_PATH}#${2:-CCSU}"; }

case "$ACTION" in
  list)
    python3 - "$CFG" <<'PY'
import json,sys
c=json.load(open(sys.argv[1]))
seen={}
for ib in c.get('inbounds',[]):
    for cl in ib.get('settings',{}).get('clients',[]):
        seen.setdefault(cl['id'], cl.get('email',''))
for i,(uid,email) in enumerate(seen.items(),1):
    print(f"  device {i}: {uid}  {email}")
PY
    ;;
  add)
    NEW="$(cat /proc/sys/kernel/random/uuid)"
    BAK="$(backup_cfg)"; echo "backup: $BAK"
    TMP="$(mktemp)"
    cp "$CFG" "$TMP"
    # Add to EVERY vless inbound (WS + QUIC if present) so transports never diverge.
    if ! python3 - "$TMP" "$NEW" "$NAME" <<'PY'; then
import json,sys
p,new,name=sys.argv[1],sys.argv[2],sys.argv[3]
c=json.load(open(p)); n=0
for ib in c.get('inbounds',[]):
    if ib.get('protocol')!='vless': continue
    clients=ib.setdefault('settings',{}).setdefault('clients',[])
    if all(x.get('id')!=new for x in clients):
        cl={'id':new}
        if name: cl['email']=name
        clients.append(cl); n+=1
json.dump(c,open(p,'w'),indent=2)
print(f"  added to {n} inbound(s)")
PY
      echo "config edit failed — live config untouched"; rm -f "$TMP"; exit 1
    fi
    if ! validate_cfg "$TMP"; then echo "config invalid, aborting (live untouched, backup $BAK)"; rm -f "$TMP"; exit 1; fi
    mv "$TMP" "$CFG"
    systemctl restart xray
    echo "Added device ${NAME:-(unnamed)}: ${NEW}"
    echo "Share link:"; echo "  $(link "$NEW" "${NAME:-CCSU-new}")"
    command -v qrencode >/dev/null 2>&1 && qrencode -t ANSIUTF8 "$(link "$NEW" "${NAME:-CCSU-new}")"
    ;;
  remove)
    [ -n "$TARGET" ] || { echo "--remove needs a UUID"; exit 1; }
    BAK="$(backup_cfg)"; echo "backup: $BAK"
    TMP="$(mktemp)"
    cp "$CFG" "$TMP"
    python3 - "$TMP" "$TARGET" <<'PY'
import json,sys
p,tgt=sys.argv[1],sys.argv[2]
c=json.load(open(p)); total=0
for ib in c.get('inbounds',[]):
    cl=ib.get('settings',{}).get('clients',[])
    n=len(cl)
    cl[:]=[x for x in cl if x.get('id')!=tgt]
    total+=n-len(cl)
json.dump(c,open(p,'w'),indent=2)
print(f"removed {total} client entr(y/ies)")
PY
    if ! validate_cfg "$TMP"; then echo "config invalid, aborting (live untouched, backup $BAK)"; rm -f "$TMP"; exit 1; fi
    mv "$TMP" "$CFG"
    systemctl restart xray
    echo "Revoked ${TARGET}"
    ;;
esac
