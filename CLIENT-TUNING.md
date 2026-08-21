# Client latency tuning

The server is only half of your ping. Client defaults — especially **DNS** —
routinely add 100–250 ms to every new connection. This is the per-app checklist.

## First: understand what you're measuring

VPN apps report a **cold-connection** number, not round-trip latency:

| Number | What it includes | Typical vs. raw RTT |
|---|---|---|
| **Raw RTT** | TCP handshake to your VPS | 1× (the floor) |
| **Warm RTT** | round trip on an open tunnel connection — *what gaming feels* | ~1× + 1 ms |
| **Cold request** | DNS + TLS to VPS + TLS to the site — *what "real delay" tests show* | **4–6×** |

A "277 ms" real-delay result with a ~25 ms floor can be completely normal. Get
the real breakdown with `./latency-check.sh` (run it on the Mac — it prints all
three), and tune from that, not from the app's badge.

---

## v2rayNG (Android)

v2rayNG defaults to **DoH** for remote DNS, which forces a full TLS handshake to
the DNS server *inside* the tunnel before any lookup resolves — about 3 extra
round trips ahead of the destination's own handshake. The query already travels
inside the encrypted VLESS tunnel, so that second TLS layer protects nothing and
costs real time.

Open the **⚙ settings** (main screen, gear icon) and set:

| Setting | Change to | Why |
|---|---|---|
| **Remote DNS** | `1.1.1.1` (plain, **not** `https://...`) | removes a whole TLS handshake from every cold lookup — the single biggest win |
| **Domain Strategy** | `AsIs` | stops the app resolving names locally before routing; the VPS resolves them instead (also prevents DNS leaks to Sophos) |
| **Mux (multiplexing)** | **OFF** | mux shares one connection between streams, so one stalled stream blocks the others — bad for gaming jitter |
| **Prefer IPv6** | OFF | avoids IPv6 attempts that time out and fall back |

Leave the VLESS profile itself alone — the domain, port, path, `fp=chrome` and
TLS come from the share link and are already correct.

After changing DNS, **stop and restart the connection** so the old resolver
state is dropped.

> Note: `8.8.8.8` also works; keep it plain either way. Avoid `localhost` /
> `local` for Remote DNS — that resolves on-device and leaks every domain you
> visit to the campus firewall.

---

## sing-box (macOS / Linux)

Already handled — regenerate the config and it picks up the fix:

```bash
cd ccsu-bypass && git pull
DOMAIN=vpn.codescriet.dev UUID=<your-uuid> npm run client
sing-box run -c client-singbox.json
```

The generated config uses plain DNS through the tunnel (`1.1.1.1`, `detour:
proxy`) with caching, keeps the proxy's own hostname on the local resolver to
avoid a chicken-and-egg lookup, and routes private/LAN ranges direct.

When testing with curl, use **`socks5h`** (not `socks5`) so the hostname
resolves at the proxy end:

```bash
curl -x socks5h://127.0.0.1:2080 https://ifconfig.me    # should print your VPS IP
```

---

## Hiddify / V2Box (iPhone)

Same principle: find **Remote DNS** in settings and set it to plain `1.1.1.1`
rather than a `https://` DoH URL. If the app exposes a domain-resolution or
"routing" strategy, prefer the equivalent of `AsIs`.

---

## If latency is still high after this

Run on the Mac:

```bash
DOMAIN=vpn.codescriet.dev VPS_IP=<your-vps-ip> ./latency-check.sh
```

- **Warm ≈ raw** → the tunnel is healthy; a high app badge is its cold-start test.
- **Raw itself high** → routing/geography. Check with
  `traceroute -T -p 443 <vps-ip>` and look for the hop where time jumps.
  No client setting fixes this.
- **Warm ≫ raw** → a genuine tunnel problem: check the VPS with
  `npm run doctor` and look at CPU (`uptime`) — a 1/8-OCPU shape can be slow at
  TLS handshakes under load.
