/*
 * gen-client.js — generate client configs + share link.
 *
 *   npm run client
 *   DOMAIN=vpn.codescriet.dev UUID=<uuid> node gen-client.js
 *   PIN_IP=165.22.223.13 node gen-client.js     # survive DNS blocking (see below)
 *
 * Produces:
 *   client-singbox.json  — sing-box config (macOS/Linux/Windows)
 *   a vless:// share link — v2rayNG / v2rayN / Hiddify / V2Box / Nekobox
 *
 * Two hardening decisions worth understanding:
 *
 * 1. DNS GOES THROUGH THE TUNNEL.
 *    Sophos intercepts DNS at the gateway, so a plain setup leaks every domain
 *    you visit and lets the firewall block sites at the DNS layer even though
 *    the tunnel itself works. We therefore resolve names *inside* the tunnel.
 *    Note this is NOT the thing that failed before: pointing the client at
 *    DoH (https://1.1.1.1/dns-query) *directly* fails because Sophos blocks
 *    that connection. Here the DoH query is wrapped in the VLESS tunnel
 *    (`detour: "proxy"`), so the firewall only sees the tunnel.
 *    The proxy's own domain must still resolve locally, or we'd have a
 *    chicken-and-egg problem — that's the `local-dns` rule.
 *
 * 2. OPTIONAL IP PINNING (PIN_IP).
 *    If the firewall ever poisons or NXDOMAINs your domain, name resolution
 *    dies before the tunnel is even attempted. With PIN_IP the client dials the
 *    IP directly while still sending SNI/Host = your domain, so it still looks
 *    like ordinary HTTPS to that domain and no DNS lookup is needed at all.
 */
const fs = require('fs');

const UUID    = process.env.UUID    || '49189805-e1ed-4627-820a-806adb82c169';
const DOMAIN  = process.env.DOMAIN  || 'vpn.codescriet.dev';
const PORT    = parseInt(process.env.PORT || '443', 10);
const WS_PATH = process.env.WS_PATH || '/cdn';
const SOCKS   = parseInt(process.env.SOCKS_PORT || '2080', 10);
const PIN_IP  = process.env.PIN_IP || '';          // optional: dial IP, SNI stays DOMAIN

if (UUID === '49189805-e1ed-4627-820a-806adb82c169') {
  console.warn('[warn] Using the built-in default UUID — it is PUBLIC (it is in git).');
  console.warn('[warn] Pass the UUID that setup.sh generated: UUID=... npm run client\n');
}

// The address the client actually dials. SNI/Host stay DOMAIN either way, so
// the traffic still looks like normal HTTPS to your domain.
const dialTarget = PIN_IP || DOMAIN;

const encPath = WS_PATH.replace(/\//g, '%2F');
const link =
  `vless://${UUID}@${dialTarget}:${PORT}` +
  `?encryption=none&security=tls&sni=${DOMAIN}&fp=chrome` +
  `&type=ws&host=${DOMAIN}&path=${encPath}#CCSU-Bypass`;

const singbox = {
  log: { level: 'warn' },

  // See note 1 at the top of this file.
  dns: {
    servers: [
      // Resolved INSIDE the tunnel — the firewall sees only the tunnel.
      { tag: 'proxy-dns', address: 'https://1.1.1.1/dns-query', detour: 'proxy' },
      // Used only for the proxy's own hostname (chicken-and-egg).
      { tag: 'local-dns', address: 'local', detour: 'direct' }
    ],
    rules: [
      { domain: [DOMAIN], server: 'local-dns' }
    ],
    final: 'proxy-dns',
    strategy: 'prefer_ipv4',
    disable_cache: false
  },

  inbounds: [
    { type: 'mixed', listen: '127.0.0.1', listen_port: SOCKS }
  ],

  outbounds: [
    {
      type: 'vless',
      tag: 'proxy',
      server: dialTarget,
      server_port: PORT,
      uuid: UUID,
      // Real TLS + Chrome fingerprint: this is what gets past DPI. server_name
      // stays the DOMAIN even when dialing a pinned IP.
      tls: {
        enabled: true,
        server_name: DOMAIN,
        utls: { enabled: true, fingerprint: 'chrome' }
      },
      transport: { type: 'ws', path: WS_PATH, headers: { Host: DOMAIN } }
    },
    { type: 'direct', tag: 'direct' }
  ],

  route: {
    rules: [
      // Never tunnel the connection to the VPS through itself.
      { domain: [DOMAIN], outbound: 'direct' },
      ...(PIN_IP ? [{ ip_cidr: [`${PIN_IP}/32`], outbound: 'direct' }] : []),
      // Keep LAN/loopback off the tunnel (printers, routers, local dev).
      { ip_is_private: true, outbound: 'direct' }
    ],
    final: 'proxy'
  }
};

fs.writeFileSync('client-singbox.json', JSON.stringify(singbox, null, 2));

console.log('VLESS share link (phones / Windows — import from clipboard):\n');
console.log('  ' + link + '\n');
if (PIN_IP) {
  console.log(`  [pinned] dialing ${PIN_IP} directly, SNI/Host = ${DOMAIN}`);
  console.log('  Use this variant if DNS for your domain is blocked or poisoned.\n');
}
console.log('sing-box config written to: client-singbox.json');
console.log('  run:   sing-box run -c client-singbox.json');
console.log(`  proxy: SOCKS5 127.0.0.1:${SOCKS}\n`);
console.log('IMPORTANT when testing with curl: use socks5h (not socks5) so DNS');
console.log('resolves through the tunnel instead of leaking to the firewall:');
console.log(`  curl -x socks5h://127.0.0.1:${SOCKS} https://ifconfig.me`);
console.log(`  -> should print your VPS IP${PIN_IP ? ' (' + PIN_IP + ')' : ''}\n`);
