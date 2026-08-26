# Scoping: UDP transport, and where efficiency actually comes from

Written after the bufferbloat fix, to answer two questions: how to stop video
calls suffering from TCP-over-TCP, and whether a rewrite (Rust or otherwise)
would make this faster.

## The short answer on rewriting

**No. It would gain approximately nothing, and it is the wrong lever.**

The evidence is in this project's own history. Every real problem we hit was:

| Problem | Actual cause | Language relevance |
|---|---|---|
| 300 ms ping | Network path/routing | none |
| Sessions dropping | A bash bug in my watchdog | none |
| Latency growing over time | 16 MB buffers — bufferbloat | none |
| Cold-connection latency | Redundant DoH inside the tunnel | none |
| BBR never applied | A mis-cased JSON key | none |

Xray is Go, and at **30–40 % CPU under peak load** the language is nowhere near
the bottleneck. A Rust proxy might use ~20 % less CPU on the crypto path — which
buys you nothing when you have 60 % headroom. Meanwhile you would lose xray's
uTLS fingerprinting, REALITY, ECH, and years of adversarial hardening that is
the entire reason this works against Sophos. Rewriting would trade a proven
circumvention stack for a marginal CPU saving you do not need.

**Efficiency here comes from protocol and path, not from instructions per
second.**

## The real fix for video calls: stop tunnelling TCP inside TCP

Today: `UDP call traffic → TCP tunnel → TLS → TCP`. When one packet is lost,
TCP stalls the whole stream until it is retransmitted (head-of-line blocking),
and the call's own loss-concealment never gets the chance to do its job. This is
inherent to the transport, not a tuning parameter.

The fix is a UDP-native transport, so lost packets stay lost instead of stalling
everything behind them.

### Verified: your existing xray already supports this

Checked against your actual binary (26.3.27):

| Capability | Status |
|---|---|
| XHTTP transport | `Configuration OK` — accepted |
| QUIC stack (quic-go) | present (~3200 refs) |
| Hysteria congestion control | present (~600 refs) |
| ECH / Encrypted Client Hello | present (~53 refs) |
| REALITY | present |

The deprecation warning we have been ignoring on every restart —
*"WebSocket transport is deprecated… migrate to XHTTP H2 & H3"* — is upstream
telling us exactly this.

So **no new software is required**. Same box, same domain, same certificate,
same installer.

## THE decision point: does UDP even reach your VPS?

Everything above is moot if Sophos blocks UDP/443. Many enterprise firewalls
block QUIC outright *precisely because* they cannot inspect it — and your own
writeup records Sophos blocking WireGuard UDP.

**Test this before any work.** From the campus network:

```bash
# does UDP/443 reach the VPS at all?
# on the VPS:   sudo nc -u -l 443
# on the client: nc -u <vps-ip> 443   (type something; see if it arrives)
```

| Result | Meaning | Path |
|---|---|---|
| UDP arrives | QUIC/H3 is viable | Option A below — big win for calls |
| UDP blocked | Sophos drops it | Option B — stay on TCP, optimise it |

Do not skip this. It decides the entire plan, and it takes five minutes.

---

## Option A — XHTTP over H3 (if UDP passes)

Add a *second* inbound on UDP/443 alongside the existing WS one. Nothing
existing breaks; devices migrate one at a time.

- Transport `xhttp`, `mode: auto` (falls back H3 → H2 → H1 automatically)
- ALPN `["h3","h2","http/1.1"]`
- Same domain, same Let's Encrypt cert, same `/cdn` path

**Gains:** no TCP-over-TCP, so no head-of-line blocking; QUIC's own loss
recovery; connection migration (your phone switching WiFi→5G keeps the session);
0-RTT resumption.

**Costs:** QUIC is more CPU-hungry per byte than TCP+TLS (userspace congestion
control) — fine at your 30–40 %, worth watching. Some networks throttle QUIC.

**Effort:** roughly a day, including a rollback path.

## Option B — stay on TCP, tune it properly (if UDP is blocked)

Still meaningful improvement without changing transport:

1. **Finish the bufferbloat work** — `tune-latency.sh` is written; measure with
   `bufferbloat-test.sh`. This is the single biggest available win and is
   already in the repo.
2. **XHTTP over H2** — even without QUIC, XHTTP is the maintained path and
   handles multiplexing better than the deprecated WS transport.
3. **Right-size xray's internal buffers** (`policy.levels.0.bufferSize`)
   — defaults are tuned for throughput, not latency.

## Option C — infrastructure (independent of the above)

Honestly the highest ratio of benefit to effort left:

- **ARM `A1.Flex`** instead of the 1/8-OCPU micro: 4 OCPU, 24 GB, same free
  tier, far more network headroom. Removes CPU as a variable permanently.
- **Fix the path.** Your raw RTT went 203 ms → 30–50 ms by changing the route,
  and that dwarfed every software change combined. If it regresses, that is
  where to look first.

## Also available, worth knowing

**ECH is compiled into your binary.** This is the fix for the plaintext-SNI
weakness flagged in `TESTING.md` as the main thing capping this below
state-firewall grade — your domain currently appears in every ClientHello. ECH
encrypts it. It needs DNS-side support (HTTPS RRs) and Cloudflare cooperation,
so it is a separate piece of work, but it is *available* rather than requiring a
different stack.

## Recommended order

1. **Measure bufferbloat** (`bufferbloat-test.sh`) — confirm the fix landed.
2. **Test whether UDP/443 passes Sophos** — five minutes, decides everything.
3. If UDP passes → **Option A**, added alongside, migrate gradually.
4. If not → **Option B**, and consider **Option C** regardless.

Do not start with a rewrite. Nothing in this project's failure history would
have been prevented by a different language.
