#!/usr/bin/env bash
#
# latency-check.sh — run this FROM A CLIENT (e.g. the campus Mac) to see where
# your ping actually goes. It separates the two things that make up your number:
#
#   1. RAW path Meerut<->Mumbai VPS  = the physical floor. Nothing in this repo
#      can make the tunnel faster than this.
#   2. TUNNEL overhead               = what VLESS+WS+TLS adds on top. Tuned to
#      near-zero by setup.sh (BBR + tcpNoDelay + TCP Fast Open).
#
# Target for this setup: 14-25 ms end-to-end. If RAW is already >25 ms, that's
# geography/routing, not the proxy — no config change fixes it.
#
# Usage:
#   DOMAIN=vpn.codescriet.dev VPS_IP=<ip> ./latency-check.sh
#   (SOCKS defaults to 127.0.0.1:2080 — the sing-box/xray client port.)
set -u

DOMAIN="${DOMAIN:-vpn.codescriet.dev}"
VPS_IP="${VPS_IP:-}"
SOCKS="${SOCKS:-127.0.0.1:2080}"
PORT="${PORT:-443}"

echo "== 1. RAW TCP handshake latency to the VPS (the physical floor) =="
# TCP connect time to :443 — works even where ICMP ping is blocked by Sophos.
host="${VPS_IP:-$DOMAIN}"
if command -v python3 >/dev/null 2>&1; then
  python3 - "$host" "$PORT" <<'PY'
import socket, time, sys
host, port = sys.argv[1], int(sys.argv[2])
times = []
for _ in range(10):
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(3)
    t = time.time()
    try:
        s.connect((host, port)); times.append((time.time()-t)*1000)
    except Exception as e:
        print("  connect failed:", e)
    finally:
        s.close()
    time.sleep(0.2)
if times:
    times.sort()
    print(f"  samples={len(times)}  min={min(times):.1f}ms  "
          f"median={times[len(times)//2]:.1f}ms  max={max(times):.1f}ms")
    print("  ^ this is your PHYSICAL FLOOR. End-to-end ping can't beat it.")
PY
else
  echo "  (python3 not found — using ping instead)"
  ping -c 10 "$host" | tail -n 2
fi

echo
echo "== 2. END-TO-END latency THROUGH the tunnel =="
echo "   (client -> Sophos -> VPS -> target, via SOCKS ${SOCKS})"
# Time a tiny HTTPS request to a Mumbai-region target through the proxy.
if command -v curl >/dev/null 2>&1; then
  for i in 1 2 3 4 5; do
    t=$(curl -s -o /dev/null -x "socks5h://${SOCKS}" \
         -w '%{time_connect}' https://www.google.com 2>/dev/null)
    [ -n "$t" ] && awk -v t="$t" 'BEGIN{printf "  connect #%d: %.1f ms\n", '"$i"', t*1000}'
  done
  echo "  (subtract the RAW floor above to see the tunnel's own overhead)"
else
  echo "  curl not found; skip."
fi

echo
echo "Interpretation:"
echo "  end-to-end ~= RAW floor + a few ms tunnel overhead."
echo "  If RAW <= ~20 ms you should land in the 14-25 ms band."
echo "  If RAW  > ~25 ms, the Meerut<->Mumbai path is the limit, not this setup."
