const { execSync } = require('child_process');
const fs = require('fs');
const os = require('os');

const UUID = process.env.UUID || '49189805-e1ed-4627-820a-806adb82c169';
const PORT = process.env.PORT || 3000;

const config = {
  inbounds: [{
    port: parseInt(PORT),
    protocol: "vless",
    settings: { clients: [{ id: UUID }], decryption: "none" },
    streamSettings: { network: "ws", wsSettings: { path: "/" } }
  }],
  outbounds: [{ protocol: "freedom" }]
};

fs.writeFileSync('/tmp/config.json', JSON.stringify(config));

const arch = os.arch() === 'arm64' ? 'arm64' : '64';
execSync(`
  cd /tmp &&
  curl -sL https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${arch}.zip -o xray.zip &&
  unzip -o xray.zip xray &&
  chmod +x xray &&
  ./xray run -config config.json
`, { stdio: 'inherit' });
```

**2. Commit changes** → Render auto-redeploys.

Wait for it to go live, then try this VLESS link in Hiddify (note path changed to just `/`):
```
vless://49189805-e1ed-4627-820a-806adb82c169@ccsu-bypass.onrender.com:443?encryption=none&security=tls&sni=ccsu-bypass.onrender.com&fp=randomized&type=ws&host=ccsu-bypass.onrender.com&path=%2F#Render-Bypass
