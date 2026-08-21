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

Default domain: **`vpn.codescriet.dev`**. Everything is `DOMAIN`-driven, so you
can point it at any record you control.

---

## Complete Oracle VPS walkthrough (zero → connected)

Follow these in order. Steps 1–4 are in web consoles (Oracle + Cloudflare);
step 5 is one command on the box; step 6 is your phone/laptop. Budget ~15 min.

### 1. Create the Oracle instance

1. Sign in at <https://cloud.oracle.com> → **Menu → Compute → Instances →
   Create instance**.
2. **Placement:** pick the **Mumbai** region (`ap-mumbai-1`) — lowest ping from
   Meerut of Oracle's India regions.
3. **Image and shape:**
   - Image: **Canonical Ubuntu 22.04** (or 24.04).
   - Shape: **Always Free eligible.** Either `VM.Standard.E2.1.Micro` (AMD,
     1 GB) or, better if offered, `VM.Standard.A1.Flex` (ARM — set 1 OCPU /
     6 GB, still free, more bandwidth). The installer auto-detects x86 vs ARM.
4. **Networking:** leave it to create a new VCN, and **"Assign a public IPv4
   address" = Yes**.
5. **SSH keys:** *Save the private key it offers* (or paste your own public
   key). You need it to log in.
6. **Create.** When it's **Running**, copy the **Public IP address** — call it
   `<VPS_IP>`.

### 2. Open the ports in Oracle's cloud firewall (VCN)

This is the layer people miss — it is separate from the OS firewall the
installer handles.

1. On the instance page, click the **Virtual Cloud Network** link → **Security
   Lists** → the **Default Security List**.
2. **Add Ingress Rules** (Add Ingress Rule, twice):

   | Stateless | Source CIDR | IP Protocol | Destination Port |
   |---|---|---|---|
   | No | `0.0.0.0/0` | TCP | `443` |
   | No | `0.0.0.0/0` | TCP | `80` |

   (443 is the proxy; 80 is only for the TLS certificate challenge + renewals.)

### 3. Point your domain at the box (Cloudflare)

1. Cloudflare dashboard → your domain (`codescriet.dev`) → **DNS → Records →
   Add record**:

   | Type | Name | IPv4 address | Proxy status |
   |---|---|---|---|
   | A | `vpn` | `<VPS_IP>` | **DNS only (grey cloud)** |

2. **The cloud must be grey, not orange.** Grey = direct connection = best ping
   and full-duplex unlimited up/down, and it is *required* for the certificate
   step to succeed. (Orange/proxied also works but adds ~200–400 ms — only use
   it as a fallback; see *Cloudflare modes* below.)
3. Give DNS a minute. From your laptop, `nslookup vpn.codescriet.dev` should
   return `<VPS_IP>` (not a `104.*`/`172.*` Cloudflare address).

### 4. Log in to the box

```bash
chmod 600 /path/to/your-private-key.key
ssh -i /path/to/your-private-key.key ubuntu@<VPS_IP>
```

(The default user is `ubuntu` on Ubuntu images, `opc` on Oracle Linux.)

### 5. Run the one-command installer

```bash
sudo apt update && sudo apt install -y git
git clone https://github.com/beingdev01/ccsu-bypass.git
cd ccsu-bypass
bash setup.sh
```

It re-runs itself with `sudo` and then, on its own: installs everything,
confirms `vpn.codescriet.dev` points at this box, opens the OS firewall, gets
the Let's Encrypt certificate, applies the low-latency tuning, generates **one
UUID per device** (it asks how many — default 8), writes `/etc/xray/config.json`,
starts the `xray` service, installs the self-healing watchdog, and finally
prints a **share link + QR code for each device** and saves them to
`credentials.txt`.

Just press **Enter** at each prompt to accept the defaults (domain
`vpn.codescriet.dev`, port 443, path `/cdn`, 8 devices). If DNS isn't ready it
will show you the exact record to add and wait.

When it finishes you'll see, per device:

```
vless://<uuid>@vpn.codescriet.dev:443?encryption=none&security=tls&sni=vpn.codescriet.dev&fp=chrome&type=ws&host=vpn.codescriet.dev&path=%2Fcdn#CCSU-dev1
```

### 6. Connect a device

- **Android** — install **v2rayNG** → `+` → *Import config from clipboard*
  (paste one device's link) → tap the connect button.
- **iPhone** — **Hiddify** or **V2Box** → *Add from clipboard*.
- **Windows** — **v2rayN** → *Import from clipboard*.
- **Mac / Linux** — `brew install sing-box`, then on the VPS run
  `DOMAIN=vpn.codescriet.dev UUID=<one-uuid> npm run client` to get a
  `client-singbox.json`, copy it over, `sing-box run -c client-singbox.json`,
  and set your system SOCKS5 proxy to `127.0.0.1:2080`.

Give each device a **different** link from `credentials.txt`.

### 7. Verify it's working

On the VPS: `npm run doctor` (checks service, cert, ports, WS upgrade).
From your laptop on the campus network: `DOMAIN=vpn.codescriet.dev
VPS_IP=<VPS_IP> ./doctor.sh` walks the whole path and the **first failing check
is the real problem.** To see your actual ping floor, run `latency-check.sh`
from the laptop (see *Latency* below).

That's the whole thing. Everything past here is reference and tuning.

---

## What's in here

| File | Purpose |
|---|---|
| `setup.sh` | **One-command installer.** Interactive: installs deps, verifies DNS, opens ports, gets the cert, tunes latency, writes every file, starts the service, prints link + QR. |
| `index.js` | Generates the VLESS+WS+TLS Xray config and runs Xray (arch-aware download). Used by `npm start` for manual runs. |
| `gen-client.js` | Prints the VLESS share link and writes a `sing-box` client config. `npm run client`. |
| `latency-check.sh` | Run from a client to measure the raw floor vs. tunnel overhead and confirm the 14–25 ms target is reachable. |
| `doctor.sh` | **Layered diagnostics.** Run on the VPS or a client; the first failing check tells you exactly which layer is broken. `npm run doctor` |
| `healthcheck.sh` | **Self-healing watchdog** (installed as a 3-min systemd timer): proves a real WebSocket `101`, restarts/renews on failure. |
| `add-device.sh` | Add or revoke a device on the running server, no downtime. `sudo ./add-device.sh` |
| `TESTING.md` | Isolated-lab test report: DPI/fingerprint, security, latency, 8-device concurrency, and the vulnerabilities found. |

---

## Deploy — one command (quick reference)

The full click-by-click version is the **walkthrough** above. In short: create
an A record `vpn → <VPS_IP>` (grey cloud) in Cloudflare, add Oracle VCN ingress
rules for TCP 443 + 80, then on the box:

```bash
git clone https://github.com/beingdev01/ccsu-bypass.git
cd ccsu-bypass
bash setup.sh          # re-runs itself with sudo; asks for anything it needs
```

That's it. The installer re-execs with `sudo` and then, on its own: installs
every dependency (`curl`, `certbot`, `xray`, `qrencode`, …); prompts for
domain / port / path / device-count (just press Enter for defaults) and
**generates one UUID per device**; auto-detects the public IP and **verifies DNS
points at it** (looping with the exact record to add until it does); opens
ports 80 + the TLS port in the host firewall; obtains the Let's Encrypt
certificate; applies the low-latency tuning (BBR + `fq`, `tcpNoDelay`, buffer
sizing); writes `/etc/xray/config.json`; installs the systemd service, the
cert-renewal hook, and the self-healing watchdog; self-tests; and saves a
**share link + QR code per device** to `credentials.txt`.

Fully non-interactive (automation) — pass everything as env vars:

```bash
sudo DOMAIN=vpn.codescriet.dev DEVICES=8 bash setup.sh
# or supply your own UUIDs:
sudo DOMAIN=vpn.codescriet.dev UUIDS=uuid1,uuid2,uuid3 bash setup.sh
```

Oracle "Always Free" boxes are fine — the 1 GB `E2.1.Micro` (AMD) or an ARM
`A1.Flex` slice both work; Xray idles at ~20–40 MB RAM, and the installer
auto-detects x86_64 vs ARM.

### Manual run (testing, no systemd)

```bash
export UUID=<your-uuid>
export DOMAIN=vpn.codescriet.dev
sudo -E npm start        # sudo: binds :443. Needs the cert from setup.sh first.
```

---

## Connect your devices

Generate the share link + macOS/Linux config any time:

```bash
DOMAIN=vpn.codescriet.dev UUID=<your-uuid> npm run client
```

- **Android** — v2rayNG → `+` → *Import config from clipboard* → paste link → connect.
- **Windows** — v2rayN → *Import from clipboard*.
- **iPhone** — Hiddify or V2Box → *Add from clipboard*.
- **macOS / Linux** — `brew install sing-box`, then
  `sing-box run -c client-singbox.json`, and point your SOCKS5 proxy at
  `127.0.0.1:2080`.

The link looks like:

```
vless://<uuid>@vpn.codescriet.dev:443?encryption=none&security=tls&sni=vpn.codescriet.dev&fp=chrome&type=ws&host=vpn.codescriet.dev&path=%2Fcdn#CCSU-Bypass
```

---

## Cloudflare modes: DNS-only vs Proxied

| | DNS only (grey) | Proxied (orange) |
|---|---|---|
| DNS returns | your VPS IP | a Cloudflare IP |
| Latency | your raw RTT + ~1 ms (direct) | +200–400 ms (CDN hop) |
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
| `slow_start_after_idle=0` | window doesn't collapse after brief idle (matters for gaming) |
| `tcp_mtu_probing=1` | avoids path-MTU black-hole stalls (Oracle networking quirk) |
| `tcp_notsent_lowat` | keeps the send queue short so new data isn't stuck behind a backlog |
| ALPN `http/1.1` only | prevents an h2 negotiation that would break the WebSocket upgrade |
| Cloudflare **DNS-only** | mandatory — proxied/CDN adds 200–400 ms |

**Verify the real floor** (run from the campus client, e.g. the Mac):

```bash
DOMAIN=vpn.codescriet.dev VPS_IP=<your-vps-ip> ./latency-check.sh
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

---

## Failure modes this setup handles (and the ones it can't)

Everything below was found by auditing the design against how Sophos XG
actually behaves. Fixed items are already in the code.

### Fixed

| Failure | Why it breaks | Fix |
|---|---|---|
| **ALPN negotiated `h2`** | A WebSocket upgrade is an HTTP/1.1 mechanism. Advertising `h2` lets the server pick it, and the WS handshake then fails — intermittently, which is the worst kind. | Server offers `http/1.1` only. Chrome still offers both, and picking http/1.1 is what any non-h2 site does. |
| **TCP Fast Open** | Chrome disabled TFO by default, so using it makes you *less* browser-like — and some middleboxes drop SYNs carrying payload. It was a latency "optimization" that worked against the core goal. | Removed from both the socket options and sysctl. |
| **Stray `AAAA` record** | Clients *prefer* IPv6. One leftover AAAA and your traffic goes somewhere other than the verified address — looks like a random, unfixable failure. | Installer detects it and tells you to remove it. |
| **IPv6 firewall** | `iptables` rules don't cover IPv6, so v6 clients get silently dropped. | `ip6tables` rules added and persisted. |
| **Clock skew** | A wrong system clock fails TLS validation and cert issuance with confusing errors. | Installer enables NTP and verifies sync. |
| **Hairpin NAT self-test** | Connecting to your own public IP from inside the VPS often fails on Oracle — the old self-test reported failure on a perfectly healthy server. | Tests via `--resolve` to 127.0.0.1, and separately checks the public path. |
| **Cryptic certbot failure** | The #1 real-world blocker is a missing Oracle VCN ingress rule on port 80, which certbot reports as an opaque challenge error. | Failure now prints the four actual causes, ranked. |
| **Weak self-test** | A `400` only proves TLS works, not that the WebSocket path is right — a path typo passed the old test and failed at connect time. | Now performs a real WS upgrade and requires `101`. |
| **DNS leak / DNS-level blocking** | Sophos intercepts DNS at the gateway. With traffic tunnelled but DNS local, it still sees every domain you visit and can block sites at the DNS layer. | Client resolves DNS **inside the tunnel** (`detour: proxy`). See below. |
| **Boot ordering** | `network.target` fires before the network is usable; xray could restart-loop at boot. | Unit uses `network-online.target` plus a start-limit. |

### The DNS fix, specifically

Your writeup records that pointing the client at DoH (`https://1.1.1.1/dns-query`)
**failed** — Sophos blocks that connection, so nothing resolved. That is correct,
and this is *not* a repeat of it: the DoH query is now sent **through the VLESS
tunnel** (`detour: "proxy"`), so the firewall only ever sees the tunnel. The
proxy's own hostname is the one exception — it must resolve locally, or you'd
have a chicken-and-egg problem.

When testing with curl, use **`socks5h`**, not `socks5` — the `h` is what makes
the resolver run at the proxy end. `socks5` leaks every hostname to the firewall
even though the payload is tunnelled.

### If DNS for your domain is ever blocked

Name resolution dies before the tunnel is even attempted. Pin the IP instead —
the client dials the address directly while still sending SNI/Host = your domain,
so it still looks like ordinary HTTPS and needs no lookup at all:

```bash
PIN_IP=<your-vps-ip> DOMAIN=vpn.codescriet.dev UUID=<uuid> npm run client
```

### Known limits — worth understanding

- **Active probing.** Xray answers any non-WebSocket request with a bare `400`.
  A domain serving a valid certificate but no actual website is anomalous if
  anyone deliberately probes it. Sophos blocks by *fingerprint*, not by probing
  origins, so this is not your current failure mode — but if you ever want to
  close it, the fix is to put a real site in front (nginx serving a static page,
  proxying only the WS path to xray). That adds a component to something that
  currently works, so it is deliberately not the default.
- **UDP and gaming.** UDP is carried over the TCP tunnel. It works, but
  TCP-over-TCP means a lost packet stalls the stream (head-of-line blocking), so
  jitter under packet loss is worse than native UDP. Ping stays low; stability
  under a lossy campus link is the tradeoff.
- **The raw path.** No configuration beats the physical Meerut↔Mumbai RTT.
  `latency-check.sh` tells you what that floor actually is.
- **Single port.** If port 443 to your host is ever blocked outright, you need
  a plan B — flip the Cloudflare record to orange (proxied). It costs latency
  (~400 ms) and upload throughput, but your writeup proved it works when direct
  does not. Server config needs no change.

### When something breaks, run the doctor

```bash
npm run doctor                    # on the VPS: service, cert, ports, config
DOMAIN=vpn.codescriet.dev npm run doctor   # on your laptop: the whole path
```

It checks one layer at a time. The **first** failure is the real problem:

| First failure | Meaning |
|---|---|
| C2 (TCP) | Port blocked — VCN ingress rule missing, or firewall blocking layer 4 |
| C3 (TLS) | Handshake killed — fingerprint rejected, or a certificate/MITM problem |
| C4 (WebSocket) | Client and server disagree on the path |
| C5 (tunnel) | Client app not running, or wrong UUID |


---

## Many devices + self-healing

**One credential per device.** `setup.sh` asks how many devices will connect
(default 8) and generates a separate UUID for each — `credentials.txt` then
holds one share link per device. Separate credentials mean a lost phone is
revoked without disturbing anyone else. Add or remove devices later without
downtime:

```bash
sudo ./add-device.sh --name laptop     # add one, prints its link + QR
sudo ./add-device.sh --list            # list devices
sudo ./add-device.sh --remove <uuid>   # revoke one
```

A single 1 GB box comfortably serves **7–8 concurrent devices** — lab-tested at
8/8 devices downloading at once (261–341 Mbps each) with a gaming device holding
~1.3 ms RTT under that load. On the real box the ceiling is Oracle's NIC and the
10 TB/month egress, not xray. The `fq` qdisc + `tcpNoDelay` keep one device's
download from spoiling another's latency. Details in `TESTING.md`.

**Self-healing.** A systemd timer runs `healthcheck.sh` every 3 minutes and does
more than check the process is alive — it proves the tunnel actually answers a
WebSocket upgrade with `101`, and if not (wedged xray, unreachable path, a
renewed cert not yet loaded) it restarts or renews. Combined with the service's
`Restart=always`, the proxy recovers on its own from crashes, reboots, and cert
renewals. Watch it with `systemctl list-timers ccsu-heal.timer` and
`journalctl -u ccsu-heal`.

## Config knobs (env vars)

| Var | Default | Notes |
|---|---|---|
| `DOMAIN` | `vpn.codescriet.dev` | Must be a domain you control and pointed at this VPS. |
| `UUID` | *(built-in — do not use in prod)* | Your client secret. Generate with `cat /proc/sys/kernel/random/uuid`. |
| `PORT` | `443` | TLS listen port. Keep 443 — least likely to be blocked. |
| `WS_PATH` | `/cdn` | WebSocket path; must match on client and server. |
| `EMAIL` | `admin@<domain>` | Let's Encrypt expiry notices (`setup.sh` only). |
| `PIN_IP` | *(unset)* | `gen-client.js` only. Dial this IP directly, keeping SNI/Host = `DOMAIN`. Use when DNS for the domain is blocked or poisoned. |
| `SOCKS_PORT` | `2080` | Local SOCKS5 port in the generated client config. |
| `DEVICES` | `8` | `setup.sh` — how many per-device UUIDs to generate. |
| `UUIDS` | *(unset)* | Comma-separated UUIDs to use as-is instead of generating (server side). |

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
