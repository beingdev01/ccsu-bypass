#!/usr/bin/env bash
#
# apply-qdisc.sh — re-apply the latency qdisc to the live default-route
# interface. `net.core.default_qdisc` only affects NEW interfaces; the running
# interface keeps whatever it had across reboot, so without this the box boots
# with pfifo_fast despite sysctl saying cake/fq_codel (exactly what was
# observed live: sysctl=cake, live=pfifo_fast on enp0s6).
#
# Idempotent. Installed by setup.sh / tune-latency.sh as
# /usr/local/bin/ccsu-apply-qdisc.sh + ccsu-qdisc.service (oneshot at boot).
set -u
[ "$(id -u)" = 0 ] || exec sudo -E bash "$0" "$@"

WANT="${1:-$(sysctl -n net.core.default_qdisc 2>/dev/null || echo fq_codel)}"
IFACE="$(ip route show default 2>/dev/null | awk '/default/{print $5; exit}')"
[ -n "${IFACE:-}" ] || { echo "no default route interface found"; exit 0; }

# Only touch it if it differs — avoids flapping an otherwise healthy queue.
CUR="$(tc qdisc show dev "$IFACE" 2>/dev/null | head -1 | awk '{print $2}')"
if [ "$CUR" = "$WANT" ]; then
  echo "qdisc on $IFACE already $WANT"
  exit 0
fi
if tc qdisc replace dev "$IFACE" root "$WANT" 2>/dev/null; then
  echo "applied $WANT to $IFACE (was ${CUR:-none})"
else
  echo "could not set $WANT on $IFACE (kernel module missing?)" >&2
  exit 1
fi
