#!/usr/bin/env bash
#
# regression-check.sh — "the ping got worse". Find out what is actually live on
# this box right now, and roll back any layer in one command.
#
# This exists because we changed several things in sequence and never verified
# which of them are actually applied to the RUNNING server. A change that was
# committed to git is not a change that is running.
#
#   sudo ./regression-check.sh                 # report only, changes nothing
#   sudo ./regression-check.sh --rollback quic     # remove the QUIC inbound
#   sudo ./regression-check.sh --rollback sockopt  # remove per-socket tuning
#   sudo ./regression-check.sh --rollback buffers  # restore the old 16MB buffers
set -u
[ "$(id -u)" = 0 ] || exec sudo -E bash "$0" "$@"

CFG=/etc/xray/config.json
g=$'\033[1;32m'; y=$'\033[1;33m'; r=$'\033[1;31m'; b=$'\033[1m'; z=$'\033[0m'
ok(){   echo "${g}  ok${z} $*"; }
warn(){ echo "${y}  !!${z} $*"; }
bad(){  echo "${r} err${z} $*"; }
hd(){   echo; echo "${b}$*${z}"; }

[ -f "$CFG" ] || { bad "no $CFG — run setup.sh first"; exit 1; }

ROLLBACK="${2:-}"
[ "${1:-}" = "--rollback" ] || ROLLBACK=""

# ---------------------------------------------------------------------------
# 1. Which transports are live? A device pointed at the wrong one explains a
#    2-3x ping difference all on its own.
# ---------------------------------------------------------------------------
hd "1. TRANSPORTS ACTUALLY LISTENING"
HAS_QUIC=no
python3 -c "
import json;c=json.load(open('$CFG'))
print('  inbounds in config:', ', '.join(
  f\"{i.get('tag','(untagged)')}:{i['streamSettings']['network']}\" for i in c['inbounds']))" 2>/dev/null
if python3 -c "
import json,sys;c=json.load(open('$CFG'))
sys.exit(0 if any(i.get('tag')=='quic-in' for i in c['inbounds']) else 1)" 2>/dev/null; then
  HAS_QUIC=yes
  warn "QUIC inbound present (UDP/443)"
  echo "     If your phone/Mac imported the '#CCSU-QUIC' link, you are measuring QUIC."
  echo "     Our own udp-probe measured UDP at ~108 ms median vs 30-50 ms over TCP"
  echo "     on this same path, so QUIC being SLOWER here is expected, not a bug."
  echo "     -> to compare fairly, re-import the '#CCSU-Bypass' (ws) link."
else
  ok "WebSocket only — no QUIC inbound, so you cannot be on the QUIC path"
fi
command -v ss >/dev/null && {
  ss -lntH 2>/dev/null | grep -q ':443' && ok "TCP/443 listening (WebSocket)" || bad "TCP/443 NOT listening"
  ss -lunH 2>/dev/null | grep -q ':443' && echo "     UDP/443 bound (QUIC)"   || echo "     UDP/443 not bound"
}

# ---------------------------------------------------------------------------
# 2. Did the bufferbloat fix ever get APPLIED here? setup.sh writes these on a
#    fresh install only. An existing box keeps the old oversized buffers until
#    tune-latency.sh is run, so the fix can be "in git" and absent in reality.
# ---------------------------------------------------------------------------
hd "2. IS THE BUFFERBLOAT FIX ACTUALLY APPLIED?"
WMEM="$(sysctl -n net.core.wmem_max 2>/dev/null || echo 0)"
LOWAT="$(sysctl -n net.ipv4.tcp_notsent_lowat 2>/dev/null || echo 0)"
QD="$(sysctl -n net.core.default_qdisc 2>/dev/null || echo '?')"
IFACE="$(ip route show default 2>/dev/null | awk '/default/{print $5; exit}')"
LIVEQ="$(tc qdisc show dev "${IFACE:-lo}" 2>/dev/null | head -1 | awk '{print $2}')"
printf "  %-26s %s\n" "net.core.wmem_max"        "$WMEM"
printf "  %-26s %s\n" "tcp_notsent_lowat"        "$LOWAT"
printf "  %-26s %s\n" "default_qdisc"            "$QD"
printf "  %-26s %s\n" "live qdisc on ${IFACE:-?}" "${LIVEQ:-?}"
# Compare against the EXACT values tune-latency.sh writes. A threshold test
# would call the kernel default "fine" — it is not oversized, but it is also
# not the fix, and that distinction is the whole point of this check.
WANT_MEM=4194304
WANT_LOWAT=131072
APPLIED=yes
if [ "$WMEM" != "$WANT_MEM" ]; then
  APPLIED=no
  if [ "${WMEM:-0}" -gt 8000000 ] 2>/dev/null; then
    bad "buffers are still OVERSIZED (${WMEM}) — this IS the bufferbloat"
  else
    bad "wmem_max is ${WMEM}, not the tuned ${WANT_MEM} — tuning was never applied here"
  fi
fi
# The kernel default is UINT_MAX (printed 4294967295), i.e. no cap at all.
if [ "$LOWAT" != "$WANT_LOWAT" ]; then
  APPLIED=no
  bad "tcp_notsent_lowat is ${LOWAT}, not ${WANT_LOWAT} — no cap on queued data"
fi
case "$LIVEQ" in fq_codel|cake) ;; *) APPLIED=no; warn "live qdisc is '${LIVEQ:-none}' — no active queue management";; esac
if [ "$APPLIED" = yes ]; then
  ok "bufferbloat tuning is live"
else
  echo
  echo "  ${y}=> tune-latency.sh has NOT been run on this box.${z}"
  echo "     The latency-growing-over-time symptom is still unfixed. Run:"
  echo "       sudo ./tune-latency.sh"
fi

# ---------------------------------------------------------------------------
# 3. Restart history. The 30-50ms baseline was measured while the broken
#    watchdog restarted xray every ~3.4 minutes. Every restart empties every
#    queue, so queues never had time to fill — which is exactly the condition
#    under which bufferbloat is invisible. Fixing the watchdog did not add
#    latency; it stopped hiding it.
# ---------------------------------------------------------------------------
hd "3. RESTART HISTORY (queues only grow between restarts)"
RC="$(journalctl -u xray --since '24 hours ago' 2>/dev/null | grep -c 'Started\|Starting' | head -1)"
[ -n "${RC:-}" ] || RC=0
UP="$(systemctl show xray -p ActiveEnterTimestamp --value 2>/dev/null)"
echo "  restarts in last 24h : ${RC}"
echo "  running since        : ${UP:-unknown}"
if [ "${RC:-0}" -gt 50 ]; then
  warn "still restarting constantly — sessions are being killed"
elif [ "${RC:-0}" -le 5 ]; then
  ok "stable (this is correct, and it is why queues now have time to fill)"
fi

# ---------------------------------------------------------------------------
# 4. Rollback points
# ---------------------------------------------------------------------------
hd "4. AVAILABLE ROLLBACK POINTS"
ls -1t /etc/xray/config.json.pre-* 2>/dev/null | head -5 | sed 's/^/  /' || echo "  (none)"

# ---------------------------------------------------------------------------
# Rollback actions
# ---------------------------------------------------------------------------
apply(){ # description
  if ! /usr/local/bin/xray -test -config "$CFG" >/dev/null 2>&1; then
    bad "resulting config is invalid — restoring"; cp "${CFG}.rbk" "$CFG"; return 1
  fi
  systemctl restart xray; sleep 2
  systemctl is-active --quiet xray && ok "$1 — xray restarted" || { bad "xray failed; restoring"; cp "${CFG}.rbk" "$CFG"; systemctl restart xray; }
}

case "$ROLLBACK" in
  quic)
    hd "ROLLING BACK: removing the QUIC inbound"
    cp "$CFG" "${CFG}.rbk"
    python3 -c "
import json;p='$CFG';c=json.load(open(p))
n=len(c['inbounds'])
c['inbounds']=[i for i in c['inbounds'] if i.get('tag')!='quic-in']
json.dump(c,open(p,'w'),indent=2)
print(f'  removed {n-len(c[\"inbounds\"])} quic inbound(s)')"
    apply "QUIC removed, WebSocket untouched"
    ;;
  sockopt)
    hd "ROLLING BACK: removing per-socket tuning (keepalive + per-socket BBR)"
    echo "  System-wide BBR from sysctl is unaffected, so congestion control does"
    echo "  not change. This restores the exact socket behaviour from before the"
    echo "  keepalive commit, for a clean A/B."
    cp "$CFG" "${CFG}.rbk"
    python3 -c "
import json;p='$CFG';c=json.load(open(p))
n=0
for grp in ('inbounds','outbounds'):
    for e in c.get(grp,[]):
        ss=e.get('streamSettings') or {}
        if ss.pop('sockopt',None) is not None: n+=1
        if grp=='outbounds' and not ss: e.pop('streamSettings',None)
json.dump(c,open(p,'w'),indent=2)
print(f'  removed sockopt from {n} entr(ies)')"
    apply "sockopt removed"
    ;;
  buffers)
    hd "ROLLING BACK: restoring the ORIGINAL oversized buffers"
    warn "This re-introduces the bufferbloat. Only do this to prove a point."
    cat > /etc/sysctl.d/99-ccsu-latency.conf <<'SYSCTL'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.core.rmem_max=16777216
net.core.wmem_max=16777216
net.ipv4.tcp_rmem=4096 87380 16777216
net.ipv4.tcp_wmem=4096 65536 16777216
SYSCTL
    sysctl --system >/dev/null 2>&1
    [ -n "${IFACE:-}" ] && tc qdisc replace dev "$IFACE" root fq 2>/dev/null
    systemctl restart xray
    ok "original buffers restored"
    ;;
  "") ;;
  *) bad "unknown rollback target '$ROLLBACK' (quic|sockopt|buffers)"; exit 1;;
esac

# ---------------------------------------------------------------------------
hd "WHAT TO DO NEXT"
cat <<'TXT'
  Measure before changing anything else. From a CLIENT, with the tunnel up:

      DOMAIN=vpn.codescriet.dev VPS_IP=<your-ip> ./latency-check.sh

  Read the two numbers it prints together:

    RAW high, WARM high    -> the network PATH regressed. Nothing on this box
                              caused it and nothing on this box fixes it. Your
                              path already moved 203ms -> 30ms once before.
    RAW low, WARM high     -> the tunnel is adding the delay. That is queueing:
                              run tune-latency.sh, then measure again after
                              15-20 minutes of real use.
    Both low               -> you are measuring a COLD request (what v2rayNG's
                              "real delay" reports), not your actual latency.
TXT
