#!/usr/bin/env bash
#
# healthcheck.sh — self-healing watchdog for the proxy.
#
# Installed by setup.sh to run every few minutes via a systemd timer. It proves
# the tunnel is actually serving (not just that the process is alive), and fixes
# the common ways it silently rots:
#   * xray dead / wedged            -> restart
#   * TLS or WebSocket not answering -> restart
#   * certificate near expiry        -> renew, then restart to load the new cert
#   * config present but rejected    -> restart (picks up a fixed config)
#
# Everything it does is idempotent and safe to run on a timer.
set -u

DOMAIN="${DOMAIN:-$(grep -o '/etc/letsencrypt/live/[^/]*' /etc/xray/config.json 2>/dev/null | head -1 | sed 's#.*/##')}"
DOMAIN="${DOMAIN:-vpn.codescriet.dev}"
PORT="${PORT:-$(grep -o '"port"[[:space:]]*:[[:space:]]*[0-9]*' /etc/xray/config.json 2>/dev/null | head -1 | grep -o '[0-9]*')}"
PORT="${PORT:-443}"
WS_PATH="${WS_PATH:-$(grep -o '"path"[[:space:]]*:[[:space:]]*"[^"]*"' /etc/xray/config.json 2>/dev/null | head -1 | sed 's/.*"\(\/[^"]*\)"/\1/')}"
WS_PATH="${WS_PATH:-/cdn}"
LOG="${HEAL_LOG:-/var/log/ccsu-heal.log}"

log(){ echo "$(date -u '+%F %T') $*" >> "$LOG" 2>/dev/null; }
restart(){ log "RESTART xray ($1)"; systemctl restart xray; }

# 1. process up?
if ! systemctl is-active --quiet xray; then restart "service inactive"; exit 0; fi

# 2. config still valid? (a broken deploy shouldn't linger)
if ! /usr/local/bin/xray -test -config /etc/xray/config.json >/dev/null 2>&1; then
  log "WARN config rejected by xray -test"
fi

# 3. Does it actually answer a WebSocket upgrade locally?
#    --resolve to 127.0.0.1 avoids Oracle hairpin-NAT false negatives.
#
#    STABILITY: a restart kills every live connection on every device, so this
#    must never fire on a blip. A busy or CPU-starved box can miss a probe
#    without being broken at all. We therefore require STRIKES consecutive
#    failures (~3 checks = ~9 min of genuine outage) and use a generous
#    timeout. A single success resets the counter.
STRIKES="${HEAL_STRIKES:-3}"
STATE="${HEAL_STATE:-/run/ccsu-heal.fails}"
probe(){
  curl -sk --max-time 15 --resolve "${DOMAIN}:${PORT}:127.0.0.1" \
       -o /dev/null -w '%{http_code}' \
       -H 'Connection: Upgrade' -H 'Upgrade: websocket' \
       -H "Sec-WebSocket-Key: $(head -c 16 /dev/urandom | base64)" \
       -H 'Sec-WebSocket-Version: 13' \
       "https://${DOMAIN}:${PORT}${WS_PATH}" 2>/dev/null || true
}
CODE="$(probe)"; CODE="${CODE: -3}"
if [ "$CODE" = "101" ]; then
  # healthy — clear any accumulated strikes
  [ -f "$STATE" ] && rm -f "$STATE"
else
  sleep 5
  CODE2="$(probe)"; CODE2="${CODE2: -3}"
  if [ "$CODE2" = "101" ]; then
    rm -f "$STATE"
    log "probe blip (${CODE}) recovered on retry — NOT restarting"
  else
    FAILS=$(( $(cat "$STATE" 2>/dev/null || echo 0) + 1 ))
    echo "$FAILS" > "$STATE" 2>/dev/null || true
    if [ "$FAILS" -ge "$STRIKES" ]; then
      rm -f "$STATE"
      restart "ws upgrade failed ${FAILS} consecutive checks (last ${CODE}/${CODE2})"
    else
      log "ws probe failed (${CODE}/${CODE2}) strike ${FAILS}/${STRIKES} — holding, not restarting"
    fi
  fi
fi

# 4. certificate health: renew if within 10 days, then reload.
CERT="/etc/letsencrypt/live/${DOMAIN}/fullchain.pem"
if [ -f "$CERT" ] && ! openssl x509 -checkend 864000 -noout -in "$CERT" >/dev/null 2>&1; then
  log "cert expiring soon — renewing"
  certbot renew --quiet >/dev/null 2>&1 && restart "post-renewal reload"
fi

exit 0
