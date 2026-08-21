/*
 * gen-client.js — print a VLESS share link and write a sing-box client config.
 *
 *   node gen-client.js
 *   DOMAIN=vpn.codecriet.dev UUID=<uuid> node gen-client.js
 *
 * The share link imports into v2rayNG (Android), v2rayN (Windows),
 * Hiddify / V2Box (iOS), Nekobox, etc. The sing-box JSON is for macOS/Linux.
 */
const fs = require('fs');

const UUID    = process.env.UUID    || '49189805-e1ed-4627-820a-806adb82c169';
const DOMAIN  = process.env.DOMAIN  || 'vpn.codecriet.dev';
const PORT    = parseInt(process.env.PORT || '443', 10);
const WS_PATH = process.env.WS_PATH || '/cdn';
const SOCKS   = parseInt(process.env.SOCKS_PORT || '2080', 10);

const encPath = WS_PATH.replace(/\//g, '%2F');
const link =
  `vless://${UUID}@${DOMAIN}:${PORT}` +
  `?encryption=none&security=tls&sni=${DOMAIN}&fp=chrome` +
  `&type=ws&host=${DOMAIN}&path=${encPath}#CCSU-Bypass`;

const singbox = {
  log: { level: 'warn' },
  inbounds: [
    { type: 'mixed', listen: '127.0.0.1', listen_port: SOCKS }
  ],
  outbounds: [
    {
      type: 'vless',
      tag: 'proxy',
      server: DOMAIN,
      server_port: PORT,
      uuid: UUID,
      // Real TLS + Chrome fingerprint = looks like a browser to Sophos.
      tls: {
        enabled: true,
        server_name: DOMAIN,
        utls: { enabled: true, fingerprint: 'chrome' }
      },
      transport: { type: 'ws', path: WS_PATH, headers: { Host: DOMAIN } }
    },
    { type: 'direct', tag: 'direct' }
  ],
  // Never tunnel the connection to the VPS itself through the VPS.
  route: {
    rules: [{ domain: [DOMAIN], outbound: 'direct' }],
    final: 'proxy'
  }
};

fs.writeFileSync('client-singbox.json', JSON.stringify(singbox, null, 2));

console.log('\nVLESS share link (phones / Windows — import from clipboard):\n');
console.log('  ' + link + '\n');
console.log('sing-box client config written to: client-singbox.json');
console.log(`  run:   sing-box run -c client-singbox.json`);
console.log(`  then set your SOCKS5 proxy to 127.0.0.1:${SOCKS}\n`);
