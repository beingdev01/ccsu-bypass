#!/usr/bin/env bash
#
# backup.sh — one-command backup of everything needed to rebuild this proxy
# without re-issuing UUIDs or certs. Zero hassle: run before any change.
#
#   sudo ./backup.sh                 # prints backup path, keeps last 7
#   sudo ./backup.sh --restore <tgz> # restores config+certs, re-tests, restarts
#
# Backs up: /etc/xray/config.json, /etc/letsencrypt (certs+hooks),
# /etc/systemd/system/{xray,ccsu-heal,ccsu-qdisc}.*, /etc/sysctl.d/99-ccsu-*,
# /usr/local/bin/{xray,ccsu-healthcheck,ccsu-apply-qdisc}.fr (marker only).
# Never includes credentials.txt contents in logs (paths only).
set -euo pipefail
[ "$(id -u)" = 0 ] || exec sudo -E bash "$0" "$@"

DIR="${BACKUP_DIR:-/root/ccsu-backups}"
mkdir -p "$DIR"
keep_last(){ ls -t "$DIR"/ccsu-backup-*.tgz 2>/dev/null | tail -n +8 | xargs -r rm -f; }

if [ "${1:-}" = "--restore" ]; then
  SRC="${2:-}"; [ -n "$SRC" ] || { echo "usage: $0 --restore <tgz>"; exit 1; }
  [ -f "$SRC" ] || { echo "no such file: $SRC"; exit 1; }
  cp /etc/xray/config.json "/etc/xray/config.json.pre-restore.$(date +%s)"
  tar -xzf "$SRC" -C /
  /usr/local/bin/xray -test -config /etc/xray/config.json \
    && systemctl daemon-reload && systemctl restart xray \
    && echo "restored from $SRC, xray restarted" \
    || { echo "restored files but config INVALID — pre-restore backup kept"; exit 1; }
  exit 0
fi

TS="$(date +%Y%m%d-%H%M%S)"
OUT="$DIR/ccsu-backup-$TS.tgz"
tar -czf "$OUT" \
  /etc/xray/config.json \
  /etc/letsencrypt \
  /etc/systemd/system/xray.service \
  /etc/systemd/system/ccsu-heal.service /etc/systemd/system/ccsu-heal.timer \
  /etc/systemd/system/ccsu-qdisc.service \
  /etc/sysctl.d/99-ccsu-latency.conf \
  /etc/logrotate.d/ccsu-heal 2>/dev/null
chmod 600 "$OUT"
keep_last
echo "backup: $OUT"
python3 -c "import json;c=json.load(open('/etc/xray/config.json'));print('clients backed up:',len(c['inbounds'][0]['settings']['clients']))"
