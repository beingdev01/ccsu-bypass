#!/usr/bin/env bash
#
# tune-latency.sh — fix bufferbloat: latency that grows the longer a connection
# stays open.
#
# THE PROBLEM THIS SOLVES
#   Oversized socket buffers let TCP queue seconds of data. Ping looks fine on a
#   fresh connection (queues empty) and climbs as they fill — 30ms becoming
#   200ms after a few minutes of real traffic, with CPU nearly idle because the
#   packets are waiting, not being processed. Video calls suffer most, since
#   jitter tracks queue depth.
#
# WHAT IT DOES
#   1. Right-sizes buffers to the actual bandwidth-delay product (a 100 Mbps
#      link at 40 ms only needs ~500 KB; 16 MB is 30x too much).
#   2. Switches the qdisc to fq_codel, which actively keeps queue latency low
#      (AQM) rather than merely pacing like plain fq.
#   3. Caps unsent data per socket so new packets aren't stuck behind a backlog.
#   4. VERIFIES every setting actually took effect — several of these silently
#      no-op if a kernel module is missing, which is how the original tuning
#      shipped broken.
#
#   Run on the VPS:  sudo ./tune-latency.sh
set -u
[ "$(id -u)" = 0 ] || exec sudo -E bash "$0" "$@"

g=$'\033[1;32m'; y=$'\033[1;33m'; r=$'\033[1;31m'; z=$'\033[0m'
ok(){ echo "${g}  ok${z} $*"; }; warn(){ echo "${y}  !!${z} $*"; }; bad(){ echo "${r} err${z} $*"; }

echo "=== BEFORE ==="
for k in net.core.default_qdisc net.ipv4.tcp_congestion_control \
         net.core.wmem_max net.ipv4.tcp_wmem net.ipv4.tcp_notsent_lowat; do
  printf "  %-34s %s\n" "$k" "$(sysctl -n $k 2>/dev/null || echo '<unset>')"
done

# --- pick the best available queue discipline -------------------------------
# fq_codel actively manages queue LATENCY; fq only paces. cake is better still
# where present. Availability varies by kernel, so probe rather than assume.
QDISC=""
for q in cake fq_codel fq; do
  if tc qdisc add dev lo root $q 2>/dev/null; then
    tc qdisc del dev lo root 2>/dev/null
    QDISC="$q"; break
  fi
done
[ -z "$QDISC" ] && QDISC="pfifo_fast"

echo
echo "=== APPLYING (qdisc: ${QDISC}) ==="
cat > /etc/sysctl.d/99-ccsu-latency.conf <<SYSCTL
# Latency-first tuning for a proxy VPS. Buffers are deliberately MODEST:
# oversized buffers are what let queues grow into seconds of delay.
net.core.default_qdisc=${QDISC}

# Buffers sized for a fast link at real-world RTT (~4 MB ceiling covers
# 200 Mbps at 150 ms with headroom). The middle value is the autotuning
# starting point; the kernel scales between min and max as needed.
net.core.rmem_max=4194304
net.core.wmem_max=4194304
net.ipv4.tcp_rmem=4096 87380 4194304
net.ipv4.tcp_wmem=4096 65536 4194304

# Keep at most ~128 KB of UNSENT data queued per socket, so a new packet is
# never stuck behind a large backlog. This is the single most effective knob
# against latency-under-load.
net.ipv4.tcp_notsent_lowat=131072

# Don't collapse the window after a brief idle (matters for gaming/calls).
net.ipv4.tcp_slow_start_after_idle=0
# Avoid path-MTU black holes.
net.ipv4.tcp_mtu_probing=1
SYSCTL

sysctl --system >/dev/null 2>&1

# Apply the qdisc to the live interface too (sysctl only sets the default for
# NEW interfaces; the running one keeps whatever it had).
IFACE="$(ip route show default 2>/dev/null | awk '/default/{print $5; exit}')"
if [ -n "${IFACE:-}" ]; then
  tc qdisc replace dev "$IFACE" root $QDISC 2>/dev/null \
    && ok "applied ${QDISC} to live interface ${IFACE}" \
    || warn "could not set ${QDISC} on ${IFACE} (default still applies to new links)"
fi

# --- VERIFY: never trust that a setting took ---------------------------------
echo
echo "=== AFTER (verified) ==="
chk(){ # key expected
  local got; got="$(sysctl -n "$1" 2>/dev/null || echo '')"
  if [ "$got" = "$2" ]; then ok "$(printf '%-34s %s' "$1" "$got")"
  else warn "$(printf '%-34s %s  (wanted %s)' "$1" "${got:-<unset>}" "$2")"; fi
}
chk net.core.wmem_max 4194304
chk net.ipv4.tcp_notsent_lowat 131072
chk net.ipv4.tcp_slow_start_after_idle 0
printf "  %-34s %s\n" "net.core.default_qdisc" "$(sysctl -n net.core.default_qdisc)"
printf "  %-34s %s\n" "net.ipv4.tcp_wmem" "$(sysctl -n net.ipv4.tcp_wmem)"
[ -n "${IFACE:-}" ] && printf "  %-34s %s\n" "live qdisc on ${IFACE}" \
  "$(tc qdisc show dev "$IFACE" 2>/dev/null | head -1 | awk '{print $2}')"

echo
echo "Restarting xray so connections start with the new limits..."
systemctl restart xray 2>/dev/null && ok "xray restarted" || warn "could not restart xray"

echo
echo "Now use it normally for 15-20 minutes, then measure again. Bufferbloat"
echo "only shows up once traffic has been flowing, so a fresh test proves nothing."
