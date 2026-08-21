#!/usr/bin/env bash
#
# latency-check.sh — run FROM A CLIENT. Splits your ping into the three numbers
# that actually mean different things, because VPN apps report the worst one:
#
#   1. RAW RTT        — TCP handshake to the VPS. The physical floor. No config
#                       can beat it.
#   2. WARM RTT       — a round trip on an ALREADY-OPEN tunnel connection. This
#                       is what gaming and normal browsing feel. Target: raw + ~1ms.
#   3. COLD REQUEST   — a brand-new connection to a remote site through the
#                       tunnel: DNS + TLS to the VPS + TLS to the site. This is
#                       what v2rayNG / Hiddify "real delay" tests measure, and it
#                       is legitimately 4-6x the raw RTT. A high number here does
#                       NOT mean your tunnel is slow.
#
# Usage:
#   DOMAIN=vpn.codescriet.dev VPS_IP=<ip> ./latency-check.sh
set -u

DOMAIN="${DOMAIN:-vpn.codescriet.dev}"
VPS_IP="${VPS_IP:-}"
SOCKS="${SOCKS:-127.0.0.1:2080}"
PORT="${PORT:-443}"
HOST="${VPS_IP:-$DOMAIN}"
SH="${SOCKS%%:*}"; SP="${SOCKS##*:}"

echo "ccsu-bypass latency — ${DOMAIN} (${HOST}:${PORT})"

# ---- 1. RAW ----------------------------------------------------------------
echo
echo "[1] RAW RTT to the VPS (physical floor, no tunnel)"
python3 - "$HOST" "$PORT" <<'PY'
import socket,sys,time
h,p=sys.argv[1],int(sys.argv[2]); ts=[]
for _ in range(12):
    s=socket.socket(); s.settimeout(5); t=time.time()
    try: s.connect((h,p)); ts.append((time.time()-t)*1000)
    except Exception as e: print("    connect error:",e); break
    finally: s.close()
    time.sleep(0.05)
if ts:
    ts.sort()
    print(f"    n={len(ts)}  min={ts[0]:.1f}  median={ts[len(ts)//2]:.1f}  max={ts[-1]:.1f} ms")
    m=ts[len(ts)//2]
    print(f"    -> your floor is {m:.0f} ms; end-to-end can never be lower")
PY

# ---- 2. WARM (the number that matters) -------------------------------------
echo
echo "[2] WARM RTT through an already-open tunnel connection"
echo "    (this is what gaming actually feels)"
python3 - "$SH" "$SP" <<'PY'
import socket,sys,time
sh,sp=sys.argv[1],int(sys.argv[2])
try:
    s=socket.create_connection((sh,sp),timeout=8)
    s.sendall(b'\x05\x01\x00')
    if s.recv(2)!=b'\x05\x00': raise RuntimeError('socks handshake failed')
    # CONNECT to a well-known echo-ish endpoint: cloudflare 1.1.1.1:80
    s.sendall(b'\x05\x01\x00\x01'+bytes([1,1,1,1])+(80).to_bytes(2,'big'))
    r=s.recv(10)
    if not r or r[1]!=0: raise RuntimeError(f'socks connect rejected ({r[1] if r else "no reply"})')
    s.setsockopt(socket.IPPROTO_TCP,socket.TCP_NODELAY,1)
    ts=[]
    req=b'HEAD / HTTP/1.1\r\nHost: 1.1.1.1\r\nConnection: keep-alive\r\n\r\n'
    for _ in range(15):
        t=time.time(); s.sendall(req)
        d=s.recv(4096)
        if not d: break
        ts.append((time.time()-t)*1000); time.sleep(0.05)
    s.close()
    if ts:
        ts.sort()
        print(f"    n={len(ts)}  min={ts[0]:.1f}  median={ts[len(ts)//2]:.1f}  max={ts[-1]:.1f} ms")
        print(f"    -> steady-state tunnel latency = {ts[len(ts)//2]:.0f} ms")
    else:
        print("    no samples (server closed the connection)")
except Exception as e:
    print(f"    could not test: {e}")
    print("    Is the client running and listening on "+f"{sh}:{sp}?")
PY

# ---- 3. COLD (what the app reports) ----------------------------------------
echo
echo "[3] COLD request through the tunnel (new DNS + TLS each time)"
echo "    (this is what the app's 'real delay' shows — expect 4-6x the floor)"
if command -v curl >/dev/null 2>&1; then
  for i in 1 2 3; do
    t=$(curl -s -o /dev/null -w '%{time_total}' --max-time 20 \
        -x "socks5h://${SOCKS}" https://www.google.com/generate_204 2>/dev/null || echo "")
    [ -n "$t" ] && awk -v t="$t" -v i="$i" 'BEGIN{printf "    attempt %d: %.0f ms\n", i, t*1000}'
  done
  echo "    (first is slowest — later ones reuse DNS cache + connection)"
else
  echo "    curl not found; skipped"
fi

echo
echo "─────────────────────────────────────────────────────────────"
echo "How to read this:"
echo "  [2] WARM near [1] RAW  -> the tunnel is healthy. Any big number your"
echo "      VPN app shows is its cold-start test, not your real latency."
echo "  [2] WARM much higher than [1] -> real tunnel problem; send me all three."
echo "  [1] RAW itself high    -> routing/geography; no config fixes it."
