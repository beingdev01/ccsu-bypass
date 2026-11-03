#!/usr/bin/env bash
#
# udp-echo-test.sh — prove UDP actually goes through the tunnel or not.
#
# TCP working (195 Mbps, WS 101) while calls/games drop = UDP-broken until
# proven otherwise. This sends real UDP datagrams through the SOCKS UDP
# ASSOCIATE path and reports loss/jitter — one command, no server change.
#
#   ./udp-echo-test.sh                      # via 127.0.0.1:2080 to Cloudflare 1.1.1.1:80 echo
#   SOCKS=127.0.0.1:2080 ./udp-echo-test.sh # custom SOCKS
#
# Reads: loss 0% + low jitter = UDP relay healthy (look at client capture/VPN
# mode next). Loss 100% / timeout = UDP never traverses (client not in VPN/TUN
# mode, or UDP ASSOCIATE blocked) — fix capture before touching the server.
set -u
SH="${SOCKS%%:*}"; SH="${SH:-127.0.0.1}"
SP="${SOCKS##*:}"; SP="${SP:-2080}"
# Cloudflare DNS responds to UDP; we use a lightweight UDP echo via DNS query
# shape but only measure reachability, never parsing — keeps it dependency-free.
python3 - "$SH" "$SP" <<'PY'
import socket,sys,time,os
sh,sp=sys.argv[1],int(sys.argv[2])
def via_socks_udp(target,port,n=10):
    # Minimal SOCKS5 UDP ASSOCIATE: TCP handshake, request association, then
    # send UDP datagrams wrapped per RFC1928 to a public echo (1.1.1.1:53).
    # We count replies, not DNS validity — reachability is the question.
    try:
        t=socket.create_connection((sh,sp),timeout=8)
    except Exception as e:
        print(f"  SOCKS TCP {sh}:{sp} unreachable: {e}")
        print("  Is the client running? sing-box/xray/v2rayNG listening on "+f"{sh}:{sp}?");
        return None
    try:
        t.sendall(b'\x05\x01\x00')
        if t.recv(2)!=b'\x05\x00':
            print("  SOCKS handshake rejected"); return None
        # ASSOCIATE 0.0.0.0:0, let server pick relay endpoint
        t.sendall(b'\x05\x03\x00\x01\x00\x00\x00\x00\x00\x00')
        r=t.recv(10)
        if not r or r[1]!=0:
            print("  UDP ASSOCIATE rejected"); return None
        # relay endpoint: IPv4 per RFC1928 reply (last 6 bytes)
        rip='.'.join(str(b) for b in r[4:8]); rport=int.from_bytes(r[8:10],'big')
        u=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); u.settimeout(3)
        # bind locally so replies route back (OS picks port)
        try: u.bind(('0.0.0.0',0))
        except Exception: pass
        got=0; rtts=[]
        # minimal DNS A query for example.com (any payload works for echo test;
        # unanswered = still informative as timeout vs reject)
        import struct,random
        for i in range(n):
            qid=random.randint(1,65535)
            q=struct.pack('>H',qid)+b'\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00\x07example\x03com\x00\x00\x01\x00\x01'
            # SOCKS UDP wrapper: RSV FRAG ATYP DST.ADDR DST.PORT DATA
            pkt=b'\x00\x00\x00\x01'+bytes([1,1,1,1])+bytes([0,53])+q
            t0=time.time()
            try:
                u.sendto(pkt,(rip,rport))
                d,_=u.recvfrom(2048)
                rtts.append((time.time()-t0)*1000); got+=1
            except socket.timeout:
                pass
            time.sleep(0.2)
        u.close()
        return got,rtts
    finally:
        try: t.close()
        except Exception: pass

print(f"UDP via SOCKS {sh}:{sp} -> 1.1.1.1:53  (10 datagrams)")
res=via_socks_udp('1.1.1.1',53,10)
if not res:
    print("  RESULT: UDP path unusable — fix client capture (VPN/TUN mode) first.")
elif res[0]==0:
    print("  RESULT: 0/10 replies — UDP does NOT traverse the tunnel.")
    print("  Next: enable VPN/TUN mode (not SOCKS-only) so WA/games UDP is captured.")
else:
    got,rtts=res; rtts.sort()
    print(f"  RESULT: {got}/10 replies, median {rtts[len(rtts)//2]:.0f} ms  max {rtts[-1]:.0f} ms")
    if got>=8 and rtts[-1]-rtts[0]<80: print("  UDP relay healthy — investigate app/VPN-mode next, not server.")
    else: print("  UDP passes but jittery/lossy — TCP-over-TCP HOL under loss; keep bulk off while calling.")
PY
