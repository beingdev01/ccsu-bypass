const http = require('http');
const { WebSocketServer } = require('ws');

const PORT = process.env.PORT || 3000;
const UUID = process.env.UUID || '49189805-e1ed-4627-820a-806adb82c169';

const server = http.createServer((req, res) => {
  res.writeHead(200, {'Content-Type': 'text/plain'});
  res.end('OK');
});

server.listen(PORT, () => console.log(`Running on port ${PORT}`));
```

Actually wait — this approach needs more setup. Let me give you a single working repo instead.

**Use this repo URL in Render:**
```
https://github.com/3andero/async-v2ray
