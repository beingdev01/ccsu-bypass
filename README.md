# ccsu-bypass

VLESS + WebSocket + **real TLS** proxy origin, built on [Xray-core], designed to
pass through DPI / TLS-fingerprinting firewalls (e.g. **Sophos XG**) by looking
exactly like an ordinary browser opening an HTTPS WebSocket to a legitimate
domain.

This is the **"Direct TLS"** architecture — a real Let's Encrypt certificate on
your own domain, Chrome uTLS fingerprint on the client, VLESS carried inside a
standard WebSocket. There are no protocol tricks in the handshake (unlike
Reality), so there is nothing for the firewall to flag.

```
your device (uTLS Chrome)  --HTTPS/WSS 443-->  firewall  -->  your VPS (Xray, real cert)  -->  internet
        SOCKS 127.0.0.1:2080        looks like normal browsing            terminates TLS, unwraps VLESS
```

> ⚠️ **Domain note:** the default domain here is `vpn.codecriet.dev` (as you
> gave it). Your engineering writeup uses `vpn.codescriet.dev` (with an **s**).
> These are different domains — a wrong one means the cert won't issue and
> nothing connects. Everything is driven by the `DOMAIN` env var, so set it to
> whichever you actually own. Change it in **one place** (the command line) and
> it flows through the server, the cert, and the share link.

---

## What's in here

| File | Purpose |
|---|---|
| `setup.sh` | One-shot VPS bootstrap: packages, firewall, Let's Encrypt cert, Xray config, systemd service, renewal hook. |
| `index.js` | Generates the VLESS+WS+TLS Xray config and runs Xray (arch-aware download). Used by `npm start` for manual runs. |
| `gen-client.js` | Prints the VLESS share link and writes a `sing-box` client config. `npm run client`. |
| `latency-check.sh` | Run from a client to measure the raw floor vs. tunnel overhead and confirm the 14–25 ms target is reachable. |

---

## Before you touch the VPS (console steps)

1. **Cloudflare DNS** — add an `A` record:

   | Type | Name | Content | Proxy |
   |---|---|---|---|
   | A | `vpn` | *your VPS public IP* | **DNS only (grey cloud)** |

   Grey cloud = direct connection = ~60 ms (best for gaming). Orange/proxied
   (CDN) also works but adds ~200–400 ms — see *Cloudflare modes* below.

2. **Oracle VCN Security List / NSG** — add **Ingress** rules from `0.0.0.0/0`:
   - TCP **443** (the proxy)
   - TCP **80** (only for the cert challenge + renewals)

   This is the layer people forget — the OS firewall is separate and `setup.sh`
   handles that part for you.

---

## Deploy (on the VPS)

Oracle "Always Free" boxes are fine here — the 1 GB `E2.1.Micro` (AMD) or an ARM
`A1.Flex` slice both work; Xray idles at ~20–40 MB RAM. `setup.sh` auto-detects
x86_64 vs ARM.

```bash
git clone https://github.com/beingdev01/ccsu-bypass.git
cd ccsu-bypass

sudo DOMAIN=vpn.codecriet.dev \
     UUID=$(cat /proc/sys/kernel/random/uuid) \
     ./setup.sh
```

The script installs everything, obtains the certificate, starts Xray under
systemd, and prints your **UUID** and a ready-to-import **VLESS share link**.
Save both.

**Self-test from the VPS** (a plain GET to the WS path should return `400` —
that is Xray correctly rejecting a non-WebSocket request):

```bash
curl -sk https://vpn.codecriet.dev/cdn -o /dev/null -w '%{http_code}\n'   # -> 400
```

### Manual run (testing, no systemd)

```bash
export UUID=<your-uuid>
export DOMAIN=vpn.codecriet.dev
sudo -E npm start        # sudo: binds :443. Needs the cert from setup.sh first.
```

---

## Connect your devices

Generate the share link + macOS/Linux config any time:

```bash
DOMAIN=vpn.codecriet.dev UUID=<your-uuid> npm run client
```

- **Android** — v2rayNG → `+` → *Import config from clipboard* → paste link → connect.
- **Windows** — v2rayN → *Import from clipboard*.
- **iPhone** — Hiddify or V2Box → *Add from clipboard*.
- **macOS / Linux** — `brew install sing-box`, then
  `sing-box run -c client-singbox.json`, and point your SOCKS5 proxy at
  `127.0.0.1:2080`.

The link looks like:

```
vless://<uuid>@vpn.codecriet.dev:443?encryption=none&security=tls&sni=vpn.codecriet.dev&fp=chrome&type=ws&host=vpn.codecriet.dev&path=%2Fcdn#CCSU-Bypass
```

---

## Cloudflare modes: DNS-only vs Proxied

| | DNS only (grey) | Proxied (orange) |
|---|---|---|
| DNS returns | your VPS IP | a Cloudflare IP |
| Latency | ~60 ms (direct) | ~200–400 ms (CDN hop) |
| Upload | full | throttled |
| What the firewall sees | Chrome → an unknown-but-valid HTTPS site | Chrome → Cloudflare (very high-trust) |
| Best for | **gaming / low latency** | maximum stealth on aggressive DPI |

This repo's config (real cert on origin, port 443) works in **both** modes with
no server change — you only flip the Cloudflare cloud colour. Start on **DNS
only**; switch to proxied only if the firewall ever starts flagging direct
connections. (Proxied mode can also use Cloudflare *Flexible SSL* + a port-80
plaintext origin, but keeping real TLS on 443 means one config for both modes.)

---

## Latency — holding 14–25 ms (Mumbai VPS)

Your end-to-end ping is:

```
ping  =  raw Meerut<->Mumbai RTT  +  tunnel overhead
         └── physics/routing ──┘     └── tuned to a few ms here ──┘
```

Nothing in software beats the **raw** leg — that's geography. Oracle's only
India regions are **Mumbai** and Hyderabad; **Mumbai is the right choice** for
Meerut (Hyderabad is farther). This box is dedicated to the proxy, so the whole
network stack is tuned for interactive latency rather than throughput fairness.

**What's tuned (applied automatically by `setup.sh`):**

| Setting | Effect |
|---|---|
| `tcpNoDelay` (Xray sockopt, both legs) | disables Nagle — small game/interactive packets go out immediately instead of being buffered |
| BBR + `fq` qdisc | low queueing delay, no bufferbloat under load |
| TCP Fast Open (`tcp_fastopen=3`) | saves a round trip on connection setup |
| `slow_start_after_idle=0` | window doesn't collapse after brief idle (matters for gaming) |
| `tcp_mtu_probing=1` | avoids path-MTU black-hole stalls (Oracle networking quirk) |
| Cloudflare **DNS-only** | mandatory — proxied/CDN adds 200–400 ms |

**Verify the real floor** (run from the campus client, e.g. the Mac):

```bash
DOMAIN=vpn.codecriet.dev VPS_IP=<your-vps-ip> ./latency-check.sh
```

It reports the **raw TCP handshake** time to the VPS (the floor) and the
**end-to-end** time through the tunnel. Reading the result:

- **raw ≤ ~20 ms** → you'll sit in the **14–25 ms** band. 
- **raw > ~25 ms** → the Meerut↔Mumbai path itself is the limit; no config
  change fixes that. The only levers left are ISP/route (not this repo).

> If you ever need lower overhead than WebSocket gives, VLESS + **XTLS-Vision**
> over plain TLS (real cert, same domain) shaves a few ms more and is *not* the
> Reality setup that Sophos flagged. Keep WS as default — it's the proven one —
> and treat Vision as an experiment only if measurements say WS overhead is your
> bottleneck (it usually isn't; the raw leg dominates).

### Adding a storage system later

When you add storage, keep it **off this instance** (a separate Object Storage
bucket or a second VM), or at least don't route heavy transfers through the
proxy. Bulk I/O on the same box competes for CPU/network and shows up as latency
spikes — `slow_start_after_idle=0` and BBR soften this, but the clean fix is
isolation. Do large syncs on home internet or direct to the bucket, not through
the tunnel.

## Config knobs (env vars)

| Var | Default | Notes |
|---|---|---|
| `DOMAIN` | `vpn.codecriet.dev` | Must be a domain you control and pointed at this VPS. |
| `UUID` | *(built-in — do not use in prod)* | Your client secret. Generate with `cat /proc/sys/kernel/random/uuid`. |
| `PORT` | `443` | TLS listen port. Keep 443 — least likely to be blocked. |
| `WS_PATH` | `/cdn` | WebSocket path; must match on client and server. |
| `EMAIL` | `admin@<domain>` | Let's Encrypt expiry notices (`setup.sh` only). |

---

## Operations

```bash
systemctl status xray         # is it running?
journalctl -u xray -f         # live logs
systemctl restart xray        # after config or cert changes
```

- **Cert renewal** is automatic (Let's Encrypt / certbot timer). A deploy hook
  restarts Xray so it picks up the new cert — installed by `setup.sh`.
- **Add / revoke users:** give each person a **separate UUID** (add more entries
  to `clients` in `/etc/xray/config.json`, then `systemctl restart xray`).
  Revoking = delete that UUID.

---

## Bandwidth (Oracle Always Free)

- **10 TB/month egress** included on the free tier, aggregated across resources;
  **inbound is free**. That's effectively unlimited for browsing and gaming.
- Note the *volume* cap (10 TB) is separate from *throughput*: the 1 GB
  `E2.1.Micro` bursts modestly (~50 Mbps range); ARM `A1.Flex` shapes get more.
- Gaming is ~60–150 MB/hour — trivial. The real consumers are **game/OS
  downloads** (50–150 GB each); do those on home internet, use the tunnel for
  gameplay and blocked sites.

---

## Security notes

- The UUID is the only credential — treat it like a password, one per person.
- Traffic device→VPS is TLS 1.3; the firewall sees only encrypted bytes to your
  domain. VPS→destination is whatever the destination uses (HTTPS stays E2E).
- Use this on infrastructure **you own** and within your network's acceptable-use
  rules.

[Xray-core]: https://github.com/XTLS/Xray-core
