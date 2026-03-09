const http = require('http');
const WebSocket = require('ws');
const net = require('net');

const UUID = process.env.UUID || '49189805-e1ed-4627-820a-806adb82c169';
const PORT = process.env.PORT || 3000;

const server = http.createServer((req, res) => {
  res.writeHead(200);
  res.end('OK');
});

const wss = new WebSocket.Server({ server });

wss.on('connection', (ws) => {
  ws.once('message', (msg) => {
    const uuid = msg.slice(1, 17);
    const uuidStr = [...uuid].map(b => b.toString(16).padStart(2,'0')).join('');
    const formatted = `${uuidStr.slice(0,8)}-${uuidStr.slice(8,12)}-${uuidStr.slice(12,16)}-${uuidStr.slice(16,20)}-${uuidStr.slice(20)}`;
    if (formatted !== UUID) { ws.close(); return; }
    const optLen = msg[17];
    const cmd = msg[18 + optLen];
    const port = msg.readUInt16BE(18 + optLen + 1);
    const atype = msg[18 + optLen + 3];
    let addr, dataStart;
    if (atype === 1) {
      addr = `${msg[18+optLen+4]}.${msg[18+optLen+5]}.${msg[18+optLen+6]}.${msg[18+optLen+7]}`;
      dataStart = 18 + optLen + 8;
    } else if (atype === 2) {
      const len = msg[18 + optLen + 4];
      addr = msg.slice(18 + optLen + 5, 18 + optLen + 5 + len).toString();
      dataStart = 18 + optLen + 5 + len;
    } else { ws.close(); return; }
    const resp = Buffer.from([msg[0], 0]);
    ws.send(resp);
    const tcp = net.connect(port, addr, () => {
      tcp.write(msg.slice(dataStart));
    });
    tcp.on('data', d => ws.readyState === 1 && ws.send(d));
    tcp.on('close', () => ws.close());
    tcp.on('error', () => ws.close());
    ws.on('message', d => tcp.write(d));
    ws.on('close', () => tcp.destroy());
  });
});

server.listen(PORT, () => console.log(`Listening on ${PORT}`));
```
Commit changes.

**Step 3:** Back in Render — change the **Start Command** from `yarn start` to:
```
npm install && node index.js
