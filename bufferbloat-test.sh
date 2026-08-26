#!/usr/bin/env bash
#
# bufferbloat-test.sh — measure latency IDLE vs UNDER LOAD through the tunnel.
#
# This is the number that matters for video calls and gaming. A tunnel can show
# a perfect 30 ms idle ping and still be unusable, because what you actually
# feel is the latency while data is flowing. The gap between the two is
# bufferbloat.
#
# Run FROM A CLIENT with the tunnel connected:
#   DOMAIN=vpn.codescriet.dev VPS_IP=<ip> ./bufferbloat-test.sh
set -u

VPS_IP="${VPS_IP:-}"
DOMAIN="${DOMAIN:-vpn.codescriet.dev}"
HOST="${VPS_IP:-$DOMAIN}"
PORT="${PORT:-443}"
SOCKS="${SOCKS:-127.0.0.1:2080}"

echo "Bufferbloat test -> ${HOST}:${PORT}"
echo

lat(){ # label — 20 TCP handshakes, report median and p95
  python3 - "$HOST" "$PORT" "$1" <<'PY'
import socket,sys,time
h,p,label=sys.argv[1],int(sys.argv[2]),sys.argv[3]
ts=[]
for _ in range(20):
    s=socket.socket(); s.settimeout(6); t=time.time()
    try: s.connect((h,p)); ts.append((time.time()-t)*1000)
    except Exception: pass
    finally: s.close()
    time.sleep(0.1)
if ts:
    ts.sort()
    med=ts[len(ts)//2]; p95=ts[int(len(ts)*0.95)-1]
    print(f"  {label:<18} median={med:6.1f} ms   p95={p95:6.1f} ms   max={ts[-1]:6.1f} ms")
    open('/tmp/.bb_%s'%label.replace(' ','_'),'w').write(str(med))
else:
    print(f"  {label:<18} no samples")
PY
}

echo "[1] IDLE latency (nothing flowing)"
lat idle
sleep 1

echo
echo "[2] Generating load through the tunnel (20s)..."
# saturate the tunnel with parallel downloads while we measure
for i in 1 2 3 4; do
  ( curl -s --max-time 25 -x "socks5h://${SOCKS}" -o /dev/null \
      https://speed.cloudflare.com/__down?bytes=104857600 2>/dev/null ) &
done
sleep 4   # let queues actually build

echo "[3] LOADED latency (measured while saturated)"
lat loaded
wait 2>/dev/null

echo
python3 - <<'PY'
try:
    idle=float(open('/tmp/.bb_idle').read())
    load=float(open('/tmp/.bb_loaded').read())
    d=load-idle
    print(f"  idle {idle:.0f} ms  ->  loaded {load:.0f} ms   (+{d:.0f} ms under load)")
    print()
    if d < 30:   print("  EXCELLENT — queues are well controlled. Calls/gaming will be smooth.")
    elif d < 80: print("  OK — mild bufferbloat, usually not noticeable.")
    elif d < 200:print("  BAD — noticeable lag in calls when anything else is downloading.")
    else:        print("  SEVERE bufferbloat — this is what makes video calls unusable.")
    print("  Fix on the VPS: sudo ./tune-latency.sh")
except Exception:
    print("  (could not compare — one of the measurements failed)")
PY
rm -f /tmp/.bb_idle /tmp/.bb_loaded 2>/dev/null
