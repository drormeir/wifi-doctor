# Technical notes

Background and design rationale behind `wifi-doctor`, aimed at a technical reader. These
are the non-obvious lessons that shaped the tool. Examples are generic; no specific
network names, devices, or addresses.

## 1. Diagnose toward a specific server, not "the internet"

Path MTU, IPv6 reachability, packet loss, and resets are all properties of the **route to
a destination**, not of "the connection" in the abstract. On the same link at the same
moment, one CDN can be perfectly healthy while another silently resets large transfers.

Implication: a generic "is the internet up?" test can give a false all-clear. The tool
always measures toward a chosen target (the actual server you care about) and resolves
that target's own IPv4/IPv6 addresses for the probes.

## 2. Carrier IPv6 can be intermittently broken for large transfers

Observed on a cellular uplink: small requests (TLS handshakes, metadata) succeed, but a
sustained large transfer over **IPv6** resets mid-stream (curl exit 56), while the same
transfer over **IPv4** completes. Crucially this was **intermittent** — present in one
session, absent an hour later — varying with tower/load/time.

Lessons:
- "It works now" does not mean the problem is fixed; intermittent faults need repeat runs.
- The fix that "gets through" is to prefer IPv4 on that connection
  (`nmcli ... ipv6.method ignore`), scoped to that network only.

## 3. A path MTU below 1500 is normal; only *broken PMTUD* is a problem

A path MTU under 1500 (e.g. 1492 from PPPoE, ~1460 from tunneling/encapsulation) is
completely normal. TCP discovers it via Path MTU Discovery and clamps its segment size —
transfers still work fine.

The actual failure mode is a **PMTUD black hole**: oversized packets are dropped *and* the
ICMP "fragmentation needed / packet too big" never gets back, so TCP never learns to
shrink. The connection then **stalls** (hangs, then times out) once it tries to send full
-size segments.

Design consequence: do **not** recommend lowering MTU just because the measured path MTU
is below 1500 — that produces false positives on healthy links. Recommend it **only** when
a transfer actually **stalled** (timeout signature), and then set the new MTU to the
*measured* cliff value. A clean reset (RST) is a carrier/server drop, not an MTU issue.

## 4. Telling an MTU limit apart from packet loss: cliff vs gradient

Weak signal / interference and a real MTU limit can both stall a transfer, but their
*signatures differ* when you measure **loss rate per packet size** (DF pings of increasing
size):

- **Real MTU limit** → a sharp **cliff**: sizes ≤ M pass ~100%, sizes > M fail ~100%,
  with low baseline loss at small sizes.
- **Random loss** (weak signal, congestion) → a fuzzy **gradient**: even small packets
  drop sometimes, even large ones get through sometimes; baseline loss is already high.

Method: first measure baseline loss at a small size. If it's already high, declare the
link **lossy** and refuse to report an MTU number (it would be meaningless). Otherwise
binary-search the size cliff and require a crisp pass→fail transition to call it a real
MTU limit. This prevents misreporting a lossy link as "small MTU."

Tooling note: `tracepath` is the textbook PMTU tool but can hang for many seconds on hops
that don't reply. `ping -M do` (don't-fragment) at varying sizes is a fast, robust
stand-in — with the caveat that some hosts/networks block ICMP entirely, in which case
PMTU simply can't be measured and the tool says so.

## 5. Local Wi-Fi link vs upstream bottleneck

A strong Wi-Fi signal with slow or dropping transfers means the bottleneck is **upstream**
of the access point, not the radio link. The clearest demonstration: a LAN throughput test
(`iperf3` between two devices on the same network) showing the local link doing hundreds of
Mbit/s with zero retransmits, while *internet* transfers through the same AP crawl at tens
of KB/s and reset. That gap localizes the fault to the upstream (e.g. a cellular backhaul),
which a public speedtest alone cannot reveal.

On a phone hotspot specifically, the AP travels with the user, so the laptop↔phone link
stays strong regardless of location — the variability lives in the cellular uplink.

## 6. Signal strength is layer-1 and frequency-independent in cause

Signal (dBm) describes the radio link between client and AP. It affects IPv4 and IPv6
**equally** — it cannot, on its own, break one address family and not the other. So a
per-family difference (e.g. IPv6 resets, IPv4 works) is never explained by signal.

dB intuition (logarithmic): **3 dB = half the power, 10 dB = 10×, 30 dB = 1000×.** A move
of a few meters through a wall and a closed door can easily cost ~30 dB. Roughly: ≥ -60
dBm strong, ~ -70 dBm is the usable edge, below that the link rate collapses and
retransmissions climb. Distance contributes free-space loss; walls/doors add material
attenuation (worse at 5 GHz than 2.4 GHz).

Design consequence: when signal is weak, attribute stalls/loss to the radio link — do not
blame MTU or IPv6 — and give in-the-moment, resource-free advice (move closer / reduce
obstructions / use a resume-capable download), never "switch to another network" (the user
may not have one).

## 7. Measure by sampling, not by waiting

Don't wait for a whole file to transfer to reach a verdict. A few seconds of transfer is
enough to (a) estimate throughput and (b) detect a reset. Practical recipe:

- Cap each transfer with a short hard timeout, and add an early-abort on stall
  (`curl --speed-limit/--speed-time`) so a dead transfer ends in seconds.
- Bound data use with an HTTP range request rather than downloading the entire object.
- Read curl exit codes: `0` complete, `28` timeout (hit cap or stalled), `18` partial,
  `56` connection reset. Combine with bytes/speed to classify
  good / slow / reset / stalled / fail.
- Run the *expensive* probes (e.g. the MTU cliff search) only when a cheap signal says
  they're needed (a transfer actually broke). When everything's fine, a quick baseline
  check is enough — keep the common case fast.

## 8. Don't let a degraded link corrupt the test itself

Two traps seen today:
- **Degenerate fallback target.** If the intended target can't be resolved/reached and the
  tool silently falls back to a near-empty page, it can report a meaningless transfer as
  "healthy." Fix: fall back to a *real, fixed-size* object and disclose the substitution.
- **Heavy metadata lookups over a slow link.** Fetching a large JSON index (some packages'
  metadata is multiple MB) can time out on a slow connection. Fetch with a generous timeout
  + retry, choose a small index, and parse offline — keep the slow part in a tool built for
  it (curl), not a language runtime's default short timeout.

## 9. Comparing Wi-Fi bands: speedtest vs iperf

A public internet speedtest measures `min(ISP plan, Wi-Fi link, test server)`. Therefore:

- A **slow plan hides** band differences (both 2.4 and 5 GHz tie at the plan ceiling).
- A **fast plan reveals** them (the speedtest reflects the Wi-Fi link).

So an internet speedtest is a fine band-comparison **only where Wi-Fi is the bottleneck**
(weak-signal spot, or a plan faster than the radio). To compare bands free of the ISP
ceiling, use a **LAN `iperf3`** test to a peer on the same network. Strongly prefer iperf
when the internet is *not* the bottleneck: fast plans, strong-signal comparisons,
LAN-only workloads (NAS/casting/backups), and access-point/mesh placement decisions
(measure node-to-node backhaul, which a speedtest can't isolate).

## 10. Terminology gotcha: Wi-Fi 6 ≠ 6 GHz

"Wi-Fi 6" is a generation (802.11ax) on 2.4/5 GHz. The **6 GHz** band is **Wi-Fi 6E**
(the "E") and **Wi-Fi 7** (802.11be). 6 GHz availability is also subject to regional
regulation, and a client needs 6 GHz-capable hardware to use it at all — a Wi-Fi 5
(802.11ac) adapter never will, regardless of what the AP broadcasts.

---

### One-line summary of the diagnostic philosophy

Measure toward the real server; sample instead of waiting; separate the radio link from
the path from the server by their distinct signatures (signal vs loss-gradient vs
size-cliff vs reset); and only recommend a change when a symptom — not just a measurement —
justifies it.
