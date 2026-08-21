# Lab testing report

The whole stack was built and exercised in an **isolated 3-node network lab**
(Linux network namespaces), not just reasoned about. This documents the test
rig, what passed, what the real limits are, and the vulnerabilities found.

## The rig

```
 namespace: cli            namespace: fw                    namespace: vps
 ┌───────────────┐   DNAT   ┌────────────────────┐          ┌──────────────────┐
 │ xray client   │─────────▶│ sophos_sim.py      │─────────▶│ xray server      │
 │ (uTLS chrome) │  :443    │ inline DPI:         │  :443    │ VLESS+WS+TLS     │
 │ SOCKS :2080   │◀─────────│  • SNI extraction   │◀─────────│ real-CA cert     │
 └───────────────┘          │  • JA3 + JA4 finger │          │ + test origins   │
                            │  • policy engine    │          └──────────────────┘
                            └────────────────────┘
```

- **sophos_sim.py** is an inline TLS middlebox that does what the writeup
  attributes to Sophos XG: it reads the plaintext SNI from the ClientHello,
  computes the client's **JA3** and (structural) **JA4** fingerprint, applies a
  policy (allow / block by fingerprint / block by SNI), and either forwards or
  silently drops — exactly the real appliance's behaviour.
- Server and client configs are **byte-for-byte the shape the repo generates**
  (VLESS + WebSocket + TLS, `alpn: http/1.1`, uTLS `chrome`, `tcpNoDelay`).
- xray is the real upstream binary (v26.x), not a mock.

Reproduce: the scripts live under `scratchpad/lab/` in the working session
(`run_all.sh`, `sophos_sim.py`, `enterprise_test.sh`, `ja4_test.sh`,
`concurrency_test.sh`). They are test harness, not shipped code.

## Results

### Fingerprint / DPI evasion — the core question

| Test | Result |
|---|---|
| uTLS actually rewrites the ClientHello | **YES** — JA3 `ba41d1…` (Go default) → `3c3af4…` (uTLS chrome); different cipher list, curves, extension set |
| uTLS matches Chrome's structure | **YES** — cipher suites, ALPN, `key_share`, `supported_versions`, `session_ticket`, `compress_certificate`, GREASE all present |
| JA3 randomises per connection (like real Chrome) | **YES** — 8 handshakes → **8 distinct JA3 hashes** |
| Structural JA4 is stable (what real DPI keys on) | **YES** — same 8 handshakes → **1 JA4** |
| DPI keyed on Chrome's JA4, policy=block-non-browser | uTLS client **ALLOWED**, naive Go-TLS client **BLOCKED** |
| SNI blocklist contains our domain | **BLOCKED** (the one thing that still stops us — see limits) |
| SNI blocklist = `workers.dev`/`pages.dev` (not us) | **ALLOWED** |

The key finding: because Chrome itself randomises JA3, a firewall **cannot**
use exact-JA3 allowlisting without blocking real browsers, and against the
robust JA4 fingerprint our client is indistinguishable from Chrome. This is the
structural reason the approach works, now demonstrated rather than asserted.

### Security / auth

| Test | Result |
|---|---|
| Wrong UUID | **Rejected** — no tunnel (`http=000`) |
| Wrong WebSocket path (`/wrong`, `/admin`, `/`) | **404**, only `/cdn` upgrades (**101**) |
| Forged certificate MITM (firewall serves its own cert for the domain) | **Refused** — client aborts with `bad certificate`; **fails closed** |
| Certificate contents | leaks only the domain CN (expected for any HTTPS site) |

### Performance

| Metric | Result |
|---|---|
| Steady-state RTT overhead through the tunnel (warm connection) | **~0.8 ms** (0.25 → 1.03 ms) |
| Per-request overhead (new TLS+WS handshake each time) | ~50 ms — **setup cost only**, not steady-state |
| Throughput through the tunnel | line-rate (~1 Gbps in-lab; real cap is the VPS NIC) |

The ~50 ms per-request figure is why keep-alive matters: gaming and browsing
reuse the connection and pay ~1 ms, not 50.

### Concurrency — 8 devices on one box

| Metric | Result |
|---|---|
| Devices completing 25 MB downloads at once | **8 / 8** |
| Per-device throughput | min 261 / median 295 / max 341 Mbps |
| Fairness (min/max) | **0.76** (`fq` qdisc gives each flow a share) |
| Gamer-device RTT while 7 others saturate the link | **median 1.27 ms** (vs 1.03 idle), one 59 ms spike |

One 1 GB box handles 7–8 concurrent devices comfortably. On the real Oracle box
the ceiling is the **NIC bandwidth** (E2.1.Micro bursts ~50 Mbps; ARM A1 more)
and the **10 TB/month egress**, not xray or CPU/RAM. `fq` + `tcpNoDelay` keep
one device's download from wrecking another's latency.

## Vulnerabilities & limitations found

1. **SNI is plaintext (unavoidable with this design).** The firewall can read
   `vpn.codescriet.dev` from every ClientHello. If it ever categorises or
   blocklists that exact domain, you're blocked (demonstrated). Mitigations, in
   order: use your own never-categorised domain (done); rotate to a new
   subdomain if one gets flagged; last resort, Cloudflare-proxied (orange)
   mode so the SNI is a Cloudflare-fronted host. True fix would be ECH
   (Encrypted Client Hello), which xray+WS doesn't do here.

2. **Active probing.** A censor that connects to `:443` and speaks HTTP sees a
   bare **404** and a valid cert for a domain with no real website — anomalous
   *if actively hunted*. Sophos blocks by fingerprint, not origin-probing, so
   this isn't the current threat, but the closing move is an nginx front serving
   a real page and reverse-proxying only `/cdn` to xray. Not enabled by default
   because it adds a component to something that already works.

3. **UDP over TCP.** UDP (game traffic, QUIC) rides the TCP tunnel, so packet
   loss causes head-of-line blocking — worse jitter than native UDP under a
   lossy link. Latency stays low; stability under loss is the tradeoff.

4. **Single credential = shared blast radius (fixed).** Originally one UUID for
   everyone. Now **one UUID per device**, so a lost phone is revoked with
   `add-device.sh --remove <uuid>` without disturbing the others.

5. **Silent rot (fixed).** A wedged xray, an unreachable WS path, or a renewed
   cert not reloaded would fail quietly. The **self-healing timer**
   (`healthcheck.sh`, every 3 min) proves a real `101` upgrade and restarts /
   renews when it doesn't — verified in-lab: healthy path → 101 (no action),
   broken path → non-101 (restart).

6. **IPv6 / DNS leak / clock skew / hairpin NAT** — all addressed earlier
   (see README "Failure modes"), several of them things that would look like
   "it just doesn't work" with no obvious cause.

## What was NOT tested here

- **Real Sophos XG.** This is a faithful simulation of its documented behaviour
  (SNI read, JA3/JA4 fingerprinting, policy drop), not the appliance itself.
  The fingerprint results are exact; a specific site's specific policy can only
  be confirmed on that site.
- **Physical Meerut↔Mumbai RTT.** The lab base link is ~0.3 ms, so latency
  numbers here are *tunnel overhead only*. Real ping = that overhead (~1 ms) +
  the geographic RTT, which `latency-check.sh` measures on the real box.
