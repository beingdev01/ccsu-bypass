#!/usr/bin/env bash
#
# udp-probe.sh — does UDP/443 actually reach your VPS through the campus firewall?
#
# This single answer decides whether a QUIC/H3 transport is worth building.
# Many enterprise firewalls block QUIC outright precisely because they cannot
# inspect it, and Sophos is already known (from this project's own history) to
# block WireGuard UDP. If UDP does not pass, no amount of protocol work helps.
#
#   On the VPS:     sudo ./udp-probe.sh server
#   On the client:  ./udp-probe.sh client <vps-ip>
#
# Remember to open UDP 443 in the Oracle VCN Security List first, or you will
# be testing Oracle's firewall rather than the campus one.
set -u

MODE="${1:-}"
PORT="${UDP_PORT:-443}"

case "$MODE" in
  server)
    echo "Opening UDP/${PORT} in the host firewall..."
    iptables -C INPUT -p udp --dport "$PORT" -j ACCEPT 2>/dev/null || \
      iptables -I INPUT -p udp --dport "$PORT" -j ACCEPT
    echo
    echo "REMINDER: also add an Oracle VCN Ingress rule:"
    echo "  Source 0.0.0.0/0   Protocol UDP   Destination Port ${PORT}"
    echo
    echo "Listening on UDP/${PORT}. Run the client side now. Ctrl-C to stop."
    python3 - "$PORT" <<'PY'
import socket,sys
p=int(sys.argv[1])
s=socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(('0.0.0.0',p))
print(f"  [server] bound udp/{p}, waiting...", flush=True)
while True:
    data, addr = s.recvfrom(2048)
    print(f"  [server] GOT {len(data)} bytes from {addr[0]}: {data[:40]!r}", flush=True)
    s.sendto(b'PONG:'+data[:32], addr)
PY
    ;;

  client)
    HOST="${2:-}"
    [ -n "$HOST" ] || { echo "usage: $0 client <vps-ip>"; exit 1; }
    echo "Probing UDP/${PORT} -> ${HOST} (10 packets)..."
    python3 - "$HOST" "$PORT" <<'PY'
import socket,sys,time
h,p=sys.argv[1],int(sys.argv[2])
s=socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.settimeout(3)
got=0; rtts=[]
for i in range(10):
    try:
        t=time.time(); s.sendto(b'PING-%d'%i,(h,p))
        d,_=s.recvfrom(2048)
        rtts.append((time.time()-t)*1000); got+=1
    except socket.timeout:
        pass
    time.sleep(0.3)
print()
if got:
    rtts.sort()
    print(f"  UDP REACHES the VPS: {got}/10 replies, median {rtts[len(rtts)//2]:.0f} ms")
    print()
    print("  => QUIC / HTTP-3 transport is VIABLE.")
    print("     Follow Option A in ROADMAP.md — this is the real fix for video calls,")
    print("     because UDP is not subject to TCP-over-TCP head-of-line blocking.")
else:
    print("  UDP BLOCKED: 0/10 replies.")
    print()
    print("  => QUIC / HTTP-3 is NOT viable on this network.")
    print("     Before concluding that, double-check BOTH:")
    print("       - Oracle VCN has an Ingress rule for UDP 443")
    print("       - the server side of this script is actually running")
    print("     If both are correct, the campus firewall is dropping UDP.")
    print("     Follow Option B in ROADMAP.md (stay on TCP, tune it).")
PY
    ;;

  *)
    echo "usage:"
    echo "  on the VPS:    sudo $0 server"
    echo "  on the client: $0 client <vps-ip>"
    exit 1
    ;;
esac
