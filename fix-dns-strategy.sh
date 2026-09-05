#!/usr/bin/env bash
#
# fix-dns-strategy.sh — stop the VPS wasting time on IPv6 that does not work.
#
# THE PROBLEM
#   The freedom outbound has no domainStrategy, so it defaults to "AsIs": xray
#   hands the hostname to Go's dialer, which does Happy Eyeballs — it resolves
#   both A and AAAA and races them, giving IPv6 a 300 ms head start. On a box
#   with working IPv6 that is correct and costs nothing. On a box WITHOUT it,
#   every new connection to a dual-stack site pays up to 300 ms waiting for an
#   IPv6 attempt that was never going to succeed.
#
#   That is a real cost on cold connections, but ONLY on a box whose IPv6 is
#   broken or absent. So this script measures first and only changes the config
#   when the measurement justifies it. It will tell you it did nothing, and why.
#
#   sudo ./fix-dns-strategy.sh
set -u
[ "$(id -u)" = 0 ] || exec sudo -E bash "$0" "$@"

CFG=/etc/xray/config.json
g=$'\033[1;32m'; y=$'\033[1;33m'; r=$'\033[1;31m'; b=$'\033[1m'; z=$'\033[0m'
ok(){ echo "${g}  ok${z} $*"; }; warn(){ echo "${y}  !!${z} $*"; }; bad(){ echo "${r} err${z} $*"; }

[ -f "$CFG" ] || { bad "no $CFG — run setup.sh first."; exit 1; }

# --- 1. does this box actually have working IPv6? ---------------------------
echo "${b}1. TESTING IPv6 FROM THIS BOX${z}"
HAVE_V6_ADDR=no
ip -6 addr show scope global 2>/dev/null | grep -q 'inet6' && HAVE_V6_ADDR=yes
echo "  global IPv6 address : ${HAVE_V6_ADDR}"

V6_WORKS=no
if [ "$HAVE_V6_ADDR" = yes ]; then
  # A real connection attempt, not a ping: this is what xray would do.
  if timeout 6 python3 - <<'PY' 2>/dev/null
import socket,sys
try:
    s=socket.socket(socket.AF_INET6, socket.SOCK_STREAM); s.settimeout(5)
    s.connect(("2606:4700:4700::1111", 443)); s.close(); sys.exit(0)
except Exception: sys.exit(1)
PY
  then V6_WORKS=yes; fi
fi
echo "  IPv6 TCP reachable  : ${V6_WORKS}"

# --- 2. decide --------------------------------------------------------------
echo
echo "${b}2. DECISION${z}"
if [ "$V6_WORKS" = yes ]; then
  WANT=""
  ok "IPv6 works here — 'AsIs' is already correct."
  echo "     Forcing IPv4 would LOSE working IPv6 connectivity for no gain."
  echo "     Nothing to change."
else
  WANT="UseIPv4"
  warn "IPv6 is absent or unreachable from this box."
  echo "     Every cold connection to a dual-stack site currently waits on an"
  echo "     IPv6 attempt that cannot succeed. Setting domainStrategy=UseIPv4"
  echo "     so xray stops trying."
fi

CUR="$(python3 -c "
import json;c=json.load(open('$CFG'))
o=[x for x in c['outbounds'] if x.get('protocol')=='freedom']
print(o[0].get('settings',{}).get('domainStrategy','AsIs') if o else 'NO-FREEDOM-OUTBOUND')")"
echo "  current domainStrategy: ${CUR}"

if [ -z "$WANT" ]; then
  [ "$CUR" != "AsIs" ] && warn "config says '${CUR}' but IPv6 works — consider removing it to regain IPv6."
  echo; echo "No change made."; exit 0
fi
if [ "$CUR" = "$WANT" ]; then echo; ok "already set to ${WANT} — nothing to do."; exit 0; fi

# --- 3. apply, validated, with rollback -------------------------------------
echo
echo "${b}3. APPLYING${z}"
BACKUP="${CFG}.pre-dns.$(date +%s)"
cp "$CFG" "$BACKUP"; echo "  backup: $BACKUP"

python3 - "$CFG" "$WANT" <<'PY'
import json,sys
p,want=sys.argv[1],sys.argv[2]
c=json.load(open(p)); n=0
for o in c['outbounds']:
    if o.get('protocol')=='freedom':
        o.setdefault('settings',{})['domainStrategy']=want; n+=1
json.dump(c,open(p,'w'),indent=2)
print(f"  set domainStrategy={want} on {n} freedom outbound(s)")
PY

if ! /usr/local/bin/xray -test -config "$CFG" >/dev/null 2>&1; then
  bad "xray rejected the config — rolling back"; cp "$BACKUP" "$CFG"; exit 1
fi
ok "config valid"
systemctl restart xray; sleep 2
if ! systemctl is-active --quiet xray; then
  bad "xray failed to start — rolling back"; cp "$BACKUP" "$CFG"; systemctl restart xray; exit 1
fi
ok "xray restarted"

DOMAIN="$(grep -o '/etc/letsencrypt/live/[^/]*' "$CFG" | head -1 | sed 's#.*/##')"
PORT="$(python3 -c "import json;print(json.load(open('$CFG'))['inbounds'][0].get('port',443))")"
WSP="$(python3 -c "
import json;c=json.load(open('$CFG'))
print(c['inbounds'][0]['streamSettings'].get('wsSettings',{}).get('path','/cdn'))")"
UP="$(curl -sk --max-time 10 --resolve "${DOMAIN}:${PORT}:127.0.0.1" -o /dev/null -w '%{http_code}' \
  -H 'Connection: Upgrade' -H 'Upgrade: websocket' \
  -H "Sec-WebSocket-Key: $(head -c16 /dev/urandom|base64)" -H 'Sec-WebSocket-Version: 13' \
  "https://${DOMAIN}:${PORT}${WSP}" 2>/dev/null || true)"
[ "${UP: -3}" = "101" ] && ok "tunnel still healthy (101)" || warn "WS check returned ${UP: -3} (expected 101)"

echo
echo "${g}Done.${z}  Roll back:  sudo cp ${BACKUP} ${CFG} && sudo systemctl restart xray"
