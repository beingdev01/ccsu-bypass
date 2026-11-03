#!/usr/bin/env bash
#
# dl.sh — lazy downloader: full speed when idle, gaming-safe when playing.
# One command, no thinking. Uses segmented connections because fq gives
# per-flow fairness (8 flows ~= 8 shares on this box).
#
#   ./dl.sh "<url>"              # gaming-safe default: 4 segs, capped so ping survives
#   ./dl.sh --fast "<url>"       # full speed, ONLY when not gaming/calling
#
# Through the tunnel (blocked host). If the host is NOT blocked, downloading
# direct (no VPN) is always faster — this script is for must-go-via-VPS files.
set -u
SOCKS="${SOCKS:-127.0.0.1:2080}"
MODE="${1:-}"
[ "$MODE" = "--fast" ] && { shift; } || MODE="safe"
URL="${1:-}"; [ -n "$URL" ] || { echo "usage: $0 [--fast] \"<url>\""; exit 1; }

if ! command -v aria2c >/dev/null 2>&1; then
  echo "aria2c not found — single-stream fallback via curl (slower):"
  echo "  curl -x socks5h://$SOCKS -LO \"$URL\""
  curl -x "socks5h://$SOCKS" -LO "$URL"
  exit $?
fi

if [ "$MODE" = "--fast" ]; then
  echo "[fast] 8 segments, uncapped — do NOT game/call during this."
  aria2c -x 8 -s 8 -k 1M --all-proxy="socks5h://$SOCKS" -c "$URL"
else
  echo "[safe] 4 segments, capped — gaming/calling safe."
  aria2c -x 4 -s 4 -k 1M --max-download-limit=3M --all-proxy="socks5h://$SOCKS" -c "$URL"
fi
