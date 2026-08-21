/*
 * ccsu-bypass — VLESS + WebSocket + TLS origin launcher
 * -----------------------------------------------------
 * Runs an Xray server that terminates real TLS (Let's Encrypt) and carries
 * VLESS inside a WebSocket. To a DPI firewall (e.g. Sophos XG) this looks
 * exactly like a browser opening an HTTPS WebSocket to a legitimate domain.
 *
 * This file just GENERATES the config and RUNS xray. Getting the TLS
 * certificate, opening the firewall and installing the systemd service is
 * done once by setup.sh. See README.md.
 *
 * Everything is configurable via environment variables:
 *   UUID       client secret (REQUIRED in production — do not use the default)
 *   DOMAIN     the domain the cert is for (default: vpn.codescriet.dev)
 *   PORT       TLS listen port                (default: 443)
 *   WS_PATH    WebSocket path                 (default: /cdn)
 *   CERT_FILE  fullchain.pem path             (default: LE path for DOMAIN)
 *   KEY_FILE   privkey.pem path               (default: LE path for DOMAIN)
 *   XRAY_CONFIG where to write the config     (default: /etc/xray/config.json,
 *                                              falls back to ./config.json)
 *   XRAY_BIN   path to xray binary            (auto-detected / downloaded)
 */
const { execSync, spawnSync } = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');

const UUID    = process.env.UUID    || '49189805-e1ed-4627-820a-806adb82c169';
const DOMAIN  = process.env.DOMAIN  || 'vpn.codescriet.dev';
const PORT    = parseInt(process.env.PORT || '443', 10);
const WS_PATH = process.env.WS_PATH || '/cdn';
const CERT_FILE = process.env.CERT_FILE || `/etc/letsencrypt/live/${DOMAIN}/fullchain.pem`;
const KEY_FILE  = process.env.KEY_FILE  || `/etc/letsencrypt/live/${DOMAIN}/privkey.pem`;

// One UUID per device is best: separate credentials mean you can revoke a lost
// phone without disturbing anyone else, and the server can tell flows apart.
// Pass several as UUIDS="uuid1,uuid2,..." (UUID stays the single-device form).
const UUIDS = (process.env.UUIDS || UUID)
  .split(',').map(s => s.trim()).filter(Boolean);

if (UUIDS.includes('49189805-e1ed-4627-820a-806adb82c169')) {
  console.warn('[warn] Using the built-in default UUID. This is PUBLIC (it is in git).');
  console.warn('[warn] Set your own:  export UUID=$(cat /proc/sys/kernel/random/uuid)');
}

// ---- Build the VLESS + WS + TLS server config --------------------------------
const config = {
  log: { loglevel: 'warning' },
  inbounds: [
    {
      listen: '0.0.0.0',
      port: PORT,
      protocol: 'vless',
      settings: {
        clients: UUIDS.map(id => ({ id })),
        decryption: 'none'
      },
      streamSettings: {
        network: 'ws',
        security: 'tls',
        tlsSettings: {
          // http/1.1 ONLY. A WebSocket upgrade is an HTTP/1.1 mechanism; if we
          // also advertise h2 the server may negotiate it and the WS handshake
          // then fails. Chrome offers [h2, http/1.1] and picking http/1.1 is
          // exactly what any non-h2 site does, so this stays unremarkable.
          alpn: ['http/1.1'],
          minVersion: '1.2',
          certificates: [
            { certificateFile: CERT_FILE, keyFile: KEY_FILE }
          ]
        },
        wsSettings: { path: WS_PATH },
        // Latency tuning for the client<->VPS leg:
        //   tcpNoDelay  -> disable Nagle so small interactive/game packets
        //                  are sent immediately instead of being buffered.
        //   tcpcongestion=bbr -> low-latency congestion control (module loaded
        //                  and enabled system-wide by setup.sh).
        // NOTE: TCP Fast Open is deliberately NOT used. Chrome disabled it by
        // default, so it makes us LESS browser-like, and some middleboxes drop
        // SYN packets carrying payload outright.
        sockopt: { tcpNoDelay: true, tcpcongestion: 'bbr' }
      }
    }
  ],
  outbounds: [
    // Same no-Nagle treatment on the VPS<->destination leg.
    { protocol: 'freedom', tag: 'direct', streamSettings: { sockopt: { tcpNoDelay: true, tcpcongestion: 'bbr' } } },
    { protocol: 'blackhole', tag: 'block' }
  ]
};

// ---- Decide where to write the config ---------------------------------------
let cfgPath = process.env.XRAY_CONFIG || '/etc/xray/config.json';
try {
  fs.mkdirSync(path.dirname(cfgPath), { recursive: true });
  fs.writeFileSync(cfgPath, JSON.stringify(config, null, 2));
} catch (e) {
  cfgPath = path.join(__dirname, 'config.json');
  fs.writeFileSync(cfgPath, JSON.stringify(config, null, 2));
}
console.log(`[ok] wrote config -> ${cfgPath}`);
console.log(`[ok] VLESS+WS+TLS  domain=${DOMAIN} port=${PORT} path=${WS_PATH}`);

// ---- Locate or download the xray binary (arch-aware) -------------------------
function xrayAssetForArch() {
  // Oracle "Always Free" is frequently ARM (Ampere A1); the AMD micro is x64.
  switch (os.arch()) {
    case 'x64':   return 'Xray-linux-64.zip';
    case 'arm64': return 'Xray-linux-arm64-v8a.zip';
    case 'arm':   return 'Xray-linux-arm32-v7a.zip';
    default:
      console.error(`[err] unsupported arch: ${os.arch()}`);
      process.exit(1);
  }
}

function resolveXray() {
  if (process.env.XRAY_BIN && fs.existsSync(process.env.XRAY_BIN)) return process.env.XRAY_BIN;
  for (const p of ['/usr/local/bin/xray', path.join(__dirname, 'xray'), '/tmp/xray']) {
    if (fs.existsSync(p)) return p;
  }
  // Download into the config's directory (writable) or cwd.
  const dir = fs.existsSync(path.dirname(cfgPath)) ? path.dirname(cfgPath) : __dirname;
  const asset = xrayAssetForArch();
  const url = `https://github.com/XTLS/Xray-core/releases/latest/download/${asset}`;
  console.log(`[..] downloading xray (${os.arch()}): ${url}`);
  execSync(
    `cd "${dir}" && curl -fsSL "${url}" -o xray.zip && unzip -o xray.zip xray && chmod +x xray`,
    { stdio: 'inherit' }
  );
  return path.join(dir, 'xray');
}

const xrayBin = resolveXray();
console.log(`[ok] xray binary  -> ${xrayBin}`);

if (!fs.existsSync(CERT_FILE) || !fs.existsSync(KEY_FILE)) {
  console.error(`[err] TLS certificate not found:`);
  console.error(`      ${CERT_FILE}`);
  console.error(`      ${KEY_FILE}`);
  console.error(`[err] Run ./setup.sh first to obtain a Let's Encrypt certificate for ${DOMAIN}.`);
  process.exit(1);
}

// ---- Run -------------------------------------------------------------------
const r = spawnSync(xrayBin, ['run', '-config', cfgPath], { stdio: 'inherit' });
process.exit(r.status === null ? 1 : r.status);
