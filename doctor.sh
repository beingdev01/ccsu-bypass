#!/usr/bin/env bash
#
# doctor.sh — find out WHICH LAYER is broken, instead of guessing.
#
# The whole lesson of this project was that blind fixes waste days and layered
# isolation finds the answer in minutes. Each check below tests exactly one
# layer, so the FIRST failure tells you where the problem actually is.
#
# Run it on the VPS  -> checks the server side (service, cert, ports, firewall).
# Run it on a client -> checks the path (TCP, TLS, WebSocket, tunnel, DNS leak).
#
#   ./doctor.sh
#   DOMAIN=vpn.codescriet.dev SOCKS=127.0.0.1:2080 ./doctor.sh
set -u

DOMAIN="${DOMAIN:-vpn.codescriet.dev}"
PORT="${PORT:-443}"
WS_PATH="${WS_PATH:-/cdn}"
SOCKS="${SOCKS:-127.0.0.1:2080}"

g=$'\033[1;32m'; y=$'\033[1;33m'; r=$'\033[1;31m'; b=$'\033[1;34m'; z=$'\033[0m'
pass(){ echo "${g}  PASS${z} $*"; }
fail(){ echo "${r}  FAIL${z} $*"; }
warn(){ echo "${y}  WARN${z} $*"; }
step(){ echo; echo "${b}[$1]${z} $2"; }
have(){ command -v "$1" >/dev/null 2>&1; }

SERVER_MODE=0
[ -f /etc/xray/config.json ] && SERVER_MODE=1

echo "ccsu-bypass doctor — ${DOMAIN}:${PORT}${WS_PATH}"
echo "mode: $([ $SERVER_MODE = 1 ] && echo 'SERVER (this is the VPS)' || echo 'CLIENT')"

# =============================== SERVER SIDE =================================
if [ "$SERVER_MODE" = 1 ]; then

  step S1 "xray service"
  if systemctl is-active --quiet xray; then
    pass "running since $(systemctl show -p ActiveEnterTimestamp --value xray 2>/dev/null)"
  else
    fail "xray is NOT running"
    echo "       last 15 log lines:"
    journalctl -u xray --no-pager -n 15 2>/dev/null | sed 's/^/       /'
    echo "       fix: systemctl restart xray"
  fi

  step S2 "listening sockets"
  if have ss && ss -ltnH 2>/dev/null | grep -q ":${PORT}\b"; then
    pass "something is listening on :${PORT}"
    ss -ltnpH 2>/dev/null | grep ":${PORT}\b" | sed 's/^/       /'
  else
    fail "nothing is listening on :${PORT}"
    echo "       fix: systemctl restart xray; journalctl -u xray -n 30"
  fi

  step S3 "certificate"
  CERT="/etc/letsencrypt/live/${DOMAIN}/fullchain.pem"
  if [ -f "$CERT" ]; then
    END="$(openssl x509 -enddate -noout -in "$CERT" 2>/dev/null | cut -d= -f2)"
    if openssl x509 -checkend 604800 -noout -in "$CERT" >/dev/null 2>&1; then
      pass "valid, expires ${END}"
    else
      warn "expires within 7 days (${END}) — renewal may be stuck"
      echo "       check: certbot renew --dry-run"
    fi
    # The renewal hook must exist or xray keeps serving the OLD cert after renewal.
    if [ -x /etc/letsencrypt/renewal-hooks/deploy/reload-xray.sh ]; then
      pass "renewal reload hook installed"
    else
      fail "renewal hook MISSING — xray will serve an expired cert after renewal"
      echo "       fix: re-run setup.sh"
    fi
  else
    fail "no certificate at ${CERT}"
    echo "       fix: re-run setup.sh (needs port 80 reachable)"
  fi

  step S4 "config sanity"
  if have /usr/local/bin/xray && /usr/local/bin/xray -test -config /etc/xray/config.json >/dev/null 2>&1; then
    pass "xray accepts the config"
    CFG_PATH="$(grep -o '"path"[^,]*' /etc/xray/config.json | head -1 | cut -d'"' -f4)"
    [ -n "$CFG_PATH" ] && echo "       ws path on server: ${CFG_PATH}"
    if grep -q '"alpn"' /etc/xray/config.json && grep -q '"h2"' /etc/xray/config.json; then
      warn "ALPN advertises h2 — WebSocket needs http/1.1; this can break clients"
    fi
  else
    fail "xray rejects the config"
    /usr/local/bin/xray -test -config /etc/xray/config.json 2>&1 | sed 's/^/       /'
  fi

  step S5 "host firewall"
  for p in 80 "$PORT"; do
    if iptables -C INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null; then pass "iptables allows :${p}"
    else warn "no explicit iptables ACCEPT for :${p} (may still be allowed by policy)"; fi
  done
  echo "       NOTE: the Oracle VCN security list is a SEPARATE layer this cannot see."

  step S6 "local TLS + WebSocket (bypasses hairpin NAT)"
  UP="$(curl -sk --max-time 8 --resolve "${DOMAIN}:${PORT}:127.0.0.1" \
        -o /dev/null -w '%{http_code}' \
        -H "Connection: Upgrade" -H "Upgrade: websocket" \
        -H "Sec-WebSocket-Key: $(head -c 16 /dev/urandom | base64)" \
        -H "Sec-WebSocket-Version: 13" \
        "https://${DOMAIN}:${PORT}${WS_PATH}" 2>/dev/null || true)"
  UP="${UP:-000}"; UP="${UP: -3}"
  case "$UP" in
    101) pass "WebSocket upgrade accepted — server side is fully healthy" ;;
    400) fail "got 400: server is up but the PATH is wrong (client must use ${WS_PATH})" ;;
    000) fail "no TLS response locally — see S1/S3" ;;
    *)   warn "unexpected HTTP ${UP}" ;;
  esac

  step S7 "resources (1 GB box)"
  echo "       $(free -m 2>/dev/null | awk '/Mem:/{printf "RAM used %s/%s MB", $3, $2}')"
  echo "       $(uptime | sed 's/.*load average/load average/')"
  echo "       congestion control: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"

  echo
  echo "Server checks done. Now run this same script ON YOUR LAPTOP to test the path."
  exit 0
fi

# =============================== CLIENT SIDE =================================
# Each step isolates ONE layer. The first FAIL is your real problem.

step C1 "DNS resolution of ${DOMAIN}"
RIP=""
if have dig; then RIP="$(dig +short A "$DOMAIN" | grep -Eo '^[0-9.]+$' | tail -1)"
elif have getent; then RIP="$(getent hosts "$DOMAIN" | awk '{print $1;exit}')"; fi
if [ -n "$RIP" ]; then
  pass "${DOMAIN} -> ${RIP}"
  case "$RIP" in
    104.1[6-9].*|104.2[0-7].*|172.6[4-9].*|172.7[0-1].*|162.159.*|188.114.*|190.93.*|197.234.*|198.41.*)
      warn "that looks like a CLOUDFLARE IP — you are in PROXIED (orange) mode."
      warn "Expect ~400ms ping and throttled upload. Switch the record to GREY"
      warn "(DNS only) for the low-latency direct path." ;;
  esac
else
  fail "cannot resolve ${DOMAIN}"
  echo "       The firewall may be blocking/poisoning DNS for this domain."
  echo "       WORKAROUND: pin the IP so no DNS lookup is needed —"
  echo "         PIN_IP=<vps-ip> npm run client"
fi

step C2 "TCP reachability to ${DOMAIN}:${PORT} (layer 4)"
if have python3; then
  python3 - "$DOMAIN" "$PORT" <<'PY'
import socket,sys,time
h,p=sys.argv[1],int(sys.argv[2]); ts=[]
for _ in range(5):
    s=socket.socket(); s.settimeout(4); t=time.time()
    try: s.connect((h,p)); ts.append((time.time()-t)*1000)
    except Exception as e: print(f"       connect error: {e}")
    finally: s.close()
    time.sleep(0.1)
if ts:
    ts.sort()
    print(f"\033[1;32m  PASS\033[0m TCP connects — median {ts[len(ts)//2]:.1f} ms (this is your latency floor)")
else:
    print("\033[1;31m  FAIL\033[0m TCP cannot connect at all")
    print("       Either the VCN ingress rule for this port is missing,")
    print("       or the firewall is blocking layer 4 to this host.")
PY
else
  warn "python3 not available; skipping"
fi

step C3 "TLS handshake + certificate trust (layer 7)"
# Deliberately WITHOUT -k: we want to know the cert really validates, because
# a MITM'd or self-signed cert is exactly what breaks these setups.
if curl -s --max-time 10 -o /dev/null "https://${DOMAIN}:${PORT}/" 2>/dev/null; then
  pass "TLS OK and certificate is trusted"
else
  RAW="$(curl -sv --max-time 10 -o /dev/null "https://${DOMAIN}:${PORT}/" 2>&1 | tail -5)"
  if echo "$RAW" | grep -qi 'certificate'; then
    fail "certificate problem — the firewall may be MITM-ing this connection"
    echo "$RAW" | sed 's/^/       /'
  elif echo "$RAW" | grep -qi '400'; then
    pass "TLS OK (server returned 400 to a plain GET, which is expected)"
  else
    fail "TLS handshake failed"
    echo "$RAW" | sed 's/^/       /'
    echo "       If C2 passed but this fails, the firewall is killing the TLS"
    echo "       handshake — i.e. it dislikes the client fingerprint."
  fi
fi

step C4 "WebSocket upgrade on ${WS_PATH}"
UP="$(curl -sk --max-time 10 -o /dev/null -w '%{http_code}' \
      -H "Connection: Upgrade" -H "Upgrade: websocket" \
      -H "Sec-WebSocket-Key: $(head -c 16 /dev/urandom | base64)" \
      -H "Sec-WebSocket-Version: 13" \
      "https://${DOMAIN}:${PORT}${WS_PATH}" 2>/dev/null || true)"
  UP="${UP:-000}"; UP="${UP: -3}"
case "$UP" in
  101) pass "upgrade accepted (101) — the full path works end to end" ;;
  400) fail "400 — path mismatch. Server expects a different path than ${WS_PATH}" ;;
  000) fail "no response (see C2/C3)" ;;
  *)   warn "HTTP ${UP}" ;;
esac

step C5 "tunnel is actually carrying traffic (SOCKS ${SOCKS})"
if curl -s --max-time 6 -x "socks5h://${SOCKS}" -o /dev/null "https://ifconfig.me" 2>/dev/null; then
  EXIT_IP="$(curl -s --max-time 8 -x "socks5h://${SOCKS}" https://ifconfig.me 2>/dev/null)"
  if [ -n "$EXIT_IP" ]; then
    pass "exit IP through tunnel: ${EXIT_IP}"
    [ -n "$RIP" ] && [ "$EXIT_IP" = "$RIP" ] && pass "matches your VPS — traffic IS tunnelled" \
      || warn "does not match ${RIP:-VPS} — check you are hitting the right proxy"
  fi
else
  fail "cannot reach the internet through ${SOCKS}"
  echo "       Is the client running?  sing-box run -c client-singbox.json"
fi

step C6 "DNS leak check"
# socks5 (no h) resolves LOCALLY = the firewall sees every domain you visit.
# socks5h resolves through the tunnel. If only socks5h works, DNS is protected.
if curl -s --max-time 6 -x "socks5://${SOCKS}" -o /dev/null "https://ifconfig.me" 2>/dev/null; then
  warn "socks5 (local DNS) also works — make sure your apps use socks5h,"
  warn "otherwise domain names leak to the firewall even though traffic is tunnelled."
else
  pass "local-DNS SOCKS path not usable — clients are forced through socks5h"
fi

echo
echo "Read the FIRST failure above — that is the layer that is actually broken."
echo "  C2 fails ....... port blocked (VCN ingress, or firewall blocking layer 4)"
echo "  C2 ok, C3 fails  TLS killed = fingerprint problem, or cert/MITM issue"
echo "  C3 ok, C4 fails  wrong WebSocket path between client and server"
echo "  C4 ok, C5 fails  client app not running or misconfigured UUID"
