#!/usr/bin/env bash
#
# add-domain.sh — add an alternate SNI domain to a running ccsu-bypass server.
#
# Why this exists: some networks (campus / carrier middleboxes doing
# SNI-based filtering, e.g. Sophos XG) let TCP/443 connect but then drop the
# TLS handshake once they see a blocklisted SNI. Symptom on the server:
#   http: TLS handshake error from <client-ip>:...: read tcp ...: i/o timeout
# in rapid bursts from the client's IP, while the server handshakes fine
# from the open internet. A fresh, innocuous-looking domain gets a new SNI
# the filter hasn't seen, and the tunnel works again.
#
#   sudo ./add-domain.sh static.codescriet.dev
#
# What it does:
#   1. Creates a grey-cloud (DNS-only) A record for the domain via the
#      Cloudflare API (creds: /home/ubuntu/.config/vm-mcp/cloudflare.env,
#      overridable with CF_API_TOKEN / CF_ZONE_ID env vars — never printed).
#   2. Issues a Let's Encrypt certificate with the DNS-01 challenge
#      (certbot-dns-cloudflare; no port juggling, no downtime for :80/:443).
#   3. Appends the cert to the VLESS inbound's tlsSettings.certificates.
#      Xray/Go selects the serving certificate by ClientHello SNI
#      automatically, so old and new domains work side by side on :443.
#   4. Validates with `xray -test`, restarts xray, verifies both SNIs.
#
# Client device UUIDs are NEVER touched: only the certificates[] array is
# modified, and a client-count guard aborts + restores the backup if the
# count ever changes. Idempotent: re-running with the same domain is a no-op.
set -euo pipefail
[ "$(id -u)" = 0 ] || exec sudo -E bash "$0" "$@"

c_g=$'\033[1;32m'; c_y=$'\033[1;33m'; c_r=$'\033[1;31m'; c_b=$'\033[1;34m'; c_0=$'\033[0m'
info(){ echo "${c_b}==>${c_0} $*"; }
ok(){   echo "${c_g} ok${c_0} $*"; }
warn(){ echo "${c_y} !!${c_0} $*"; }
err(){  echo "${c_r}err${c_0} $*" >&2; }
have(){ command -v "$1" >/dev/null 2>&1; }

NEW_DOMAIN="${1:-}"
[ -n "$NEW_DOMAIN" ] || { err "usage: sudo ./add-domain.sh <new-domain>"; exit 1; }
case "$NEW_DOMAIN" in
  *.*) ;;
  *) err "doesn't look like a domain: $NEW_DOMAIN"; exit 1;;
esac

CFG=/etc/xray/config.json
[ -f "$CFG" ] || { err "No $CFG — run setup.sh first."; exit 1; }

# Cloudflare credentials (server-side only, never printed).
CF_ENV="${CF_ENV:-/home/ubuntu/.config/vm-mcp/cloudflare.env}"
if [ -z "${CF_API_TOKEN:-}" ] && [ -f "$CF_ENV" ]; then
  # shellcheck disable=SC1090
  source "$CF_ENV"
fi
[ -n "${CF_API_TOKEN:-}" ] || { err "CF_API_TOKEN not set and $CF_ENV missing"; exit 1; }
[ -n "${CF_ZONE_ID:-}" ] || { err "CF_ZONE_ID not set"; exit 1; }

client_count(){
  python3 - "$CFG" <<'PY'
import json,sys
c=json.load(open(sys.argv[1]))
print(sum(len(ib.get('settings',{}).get('clients',[]))
          for ib in c.get('inbounds',[]) if ib.get('protocol')=='vless'))
PY
}
CP_BEFORE="$(client_count)"
info "Device UUIDs currently on the server: ${CP_BEFORE} (these will not be touched)"

PUBIP="$(dig +short vpn.codescriet.dev @1.1.1.1 | head -1)"
[ -n "$PUBIP" ] || PUBIP="$(curl -s -m 10 https://api.ip.sb/ip || true)"
[ -n "$PUBIP" ] || { err "cannot determine this server's public IP"; exit 1; }

# ---- 1. DNS: grey-cloud A record --------------------------------------------
info "Ensuring DNS-only A record ${NEW_DOMAIN} -> ${PUBIP} ..."
CF_HDR=(-s -m 20 -H "Authorization: Bearer ${CF_API_TOKEN}" -H "Content-Type: application/json")
EXISTING="$(curl "${CF_HDR[@]}" \
  "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records?type=A&name=${NEW_DOMAIN}" \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); r=d.get("result",[]); print(r[0]["id"] if r else "")')"
if [ -n "$EXISTING" ]; then
  ok "A record already exists for ${NEW_DOMAIN}"
else
  RESP="$(NEWD="$NEW_DOMAIN" IP="$PUBIP" python3 -c 'import json,os; print(json.dumps({"type":"A","name":os.environ["NEWD"],"content":os.environ["IP"],"ttl":120,"proxied":False}))')"
  curl "${CF_HDR[@]}" -X POST \
    "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records" \
    --data "$RESP" \
    | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d.get("success"), d.get("errors"); print("created:", d["result"]["id"])'
  ok "A record created (DNS-only, TTL 120)"
fi
info "Waiting for DNS propagation ..."
for i in $(seq 1 30); do
  RIP="$(dig +short "$NEW_DOMAIN" @1.1.1.1 | head -1)"
  if [ "$RIP" = "$PUBIP" ]; then ok "${NEW_DOMAIN} -> ${RIP}"; break; fi
  sleep 10
  if [ "$i" = 30 ]; then err "DNS did not propagate within 5 minutes"; exit 1; fi
done

# ---- 2. certificate via DNS-01 (no :80 juggling, no downtime) ----------------
info "Issuing Let's Encrypt certificate (DNS-01 challenge) ..."
export DEBIAN_FRONTEND=noninteractive
if ! dpkg -s python3-certbot-dns-cloudflare >/dev/null 2>&1; then
  apt-get update -y -q && apt-get install -y -q python3-certbot-dns-cloudflare
fi
CFINI=/root/.secrets/cloudflare.ini
mkdir -p /root/.secrets && chmod 700 /root/.secrets
printf 'dns_cloudflare_api_token = %s\n' "$CF_API_TOKEN" > "$CFINI"
chmod 600 "$CFINI"
APEX="${NEW_DOMAIN#*.}"
if [ ! -f "/etc/letsencrypt/live/${NEW_DOMAIN}/fullchain.pem" ]; then
  certbot certonly --dns-cloudflare --dns-cloudflare-credentials "$CFINI" \
    --dns-cloudflare-propagation-seconds 30 \
    --non-interactive --agree-tos -m "admin@${APEX}" -d "$NEW_DOMAIN" \
    || { err "certbot failed (DNS? API token permissions? see above)"; exit 1; }
  ok "certificate issued for ${NEW_DOMAIN} (renewals reuse the stored credentials)"
else
  ok "certificate already present for ${NEW_DOMAIN}"
fi

# ---- 3. patch xray config: append cert, UUIDs untouched ----------------------
info "Appending certificate to the VLESS inbound ..."
BAK="${CFG}.bak.$(date +%s)"; cp "$CFG" "$BAK"; echo "backup: $BAK"
TMP="$(mktemp --suffix=.json)"; cp "$CFG" "$TMP"
FULLCHAIN="/etc/letsencrypt/live/${NEW_DOMAIN}/fullchain.pem"
PRIVKEY="/etc/letsencrypt/live/${NEW_DOMAIN}/privkey.pem"
if ! FULLCHAIN="$FULLCHAIN" PRIVKEY="$PRIVKEY" python3 - "$TMP" <<'PY'; then
import json,os,sys
p=sys.argv[1]; fc=os.environ["FULLCHAIN"]; pk=os.environ["PRIVKEY"]
c=json.load(open(p)); n=0
for ib in c.get('inbounds',[]):
    if ib.get('protocol')!='vless': continue
    certs=ib.get('streamSettings',{}).get('tlsSettings',{}).setdefault('certificates',[])
    if all(x.get('certificateFile')!=fc for x in certs):
        certs.append({"certificateFile":fc,"keyFile":pk}); n+=1
json.dump(c,open(p,'w'),indent=2)
print(f"  cert appended to {n} inbound(s)")
PY
  err "config edit failed — live config untouched"; rm -f "$TMP"; exit 1
fi
if ! /usr/local/bin/xray -test -config "$TMP" >/dev/null 2>&1; then
  err "xray rejected the config — live untouched (backup $BAK)"; rm -f "$TMP"; exit 1
fi
mv "$TMP" "$CFG"
systemctl restart xray
CP_AFTER="$(client_count)"
if [ "$CP_BEFORE" != "$CP_AFTER" ]; then
  err "client count changed (${CP_BEFORE} -> ${CP_AFTER})! restoring backup"
  cp "$BAK" "$CFG"; systemctl restart xray; exit 1
fi
ok "xray restarted; device UUIDs intact (${CP_AFTER} clients)"

# ---- 4. verify both SNIs -----------------------------------------------------
sleep 2
systemctl is-active --quiet xray || { err "xray is not running after restart"; exit 1; }
info "Verifying served certificates ..."
for d in vpn.codescriet.dev "$NEW_DOMAIN"; do
  CN="$(echo | openssl s_client -connect 127.0.0.1:443 -servername "$d" 2>/dev/null \
        | openssl x509 -noout -subject 2>/dev/null | grep -o 'CN = [^,/]*' || echo MISSING)"
  echo "  SNI ${d} -> ${CN}"
done
echo
ok "done. Point clients at ${NEW_DOMAIN} (same UUID, same WS path /cdn)."
echo "  Generate a client config:  DOMAIN=${NEW_DOMAIN} UUID=<device-uuid> node gen-client.js"
