# wifi-doctor

A single-file Bash tool that diagnoses your **current network connection toward a
specific server** and prints the concrete `nmcli` commands (or in-the-moment actions)
that would get you through. It is **read-only** — it changes nothing on your system; it
only measures and suggests.

Why "toward a server"? Path MTU, IPv6 health, packet loss and resets all depend on the
route to the destination. A connection can be perfectly fine to one server and broken to
another, so a generic "is the internet up?" check can be misleading. wifi-doctor tests
the server you actually care about.

## Requirements

Standard tools on any Linux + NetworkManager system — nothing to install in the common
case: `bash`, `curl`, `ping`, `iw`, `nmcli`, `getent`, `awk`, `sed`.

- `python3` is used **only** to look up a live PyPI wheel for the `pypi` target. If it's
  missing or PyPI can't be reached, the tool falls back to a generic fixed-size file and
  says so.
- It's a single self-contained script — copy `wifi-doctor.sh` anywhere and run it.

## Usage

```sh
wifi-doctor.sh                 # show the target menu and pick one
wifi-doctor.sh <alias>         # test a named target, e.g.  wifi-doctor.sh pypi
wifi-doctor.sh <url|hostname>  # test any server you paste
wifi-doctor.sh -l              # just list the targets and exit
```

Run it while connected to the network you want checked (home Wi-Fi, a phone hotspot, etc.).

### Built-in targets

| alias        | what it tests                         |
|--------------|---------------------------------------|
| `pypi`       | PyPI — the server behind `pip install`|
| `claude`     | Claude / Anthropic                    |
| `openai`     | OpenAI / ChatGPT                      |
| `google`     | Google                                |
| `github`     | GitHub (code + release downloads)     |
| `israel`     | Israeli sites (gov.il)                |
| `cloudflare` | Generic internet-health check         |

### Adding your own targets

Edit the `TARGETS` block near the top of the script. One line per target:

```
alias|description|url
```

Use `__PYPI__` as the URL to fetch a live PyPI wheel at run time. New lines show up in
the menu automatically.

## What it checks

1. **Connection info** — device, NetworkManager connection name, interface MTU, and (on
   Wi-Fi) signal strength in dBm and the band (2.4 / 5 / 6 GHz).
2. **Transfer test** — pulls a short sample over IPv4 and IPv6 (capped, via HTTP range, so
   it won't burn much data) to measure speed and catch resets/stalls.
3. **Path-MTU / packet-loss analysis** — distinguishes a real MTU limit (a sharp size
   "cliff") from weak-signal/interference loss (a fuzzy gradient). It only runs the full
   cliff search when a transfer actually broke; otherwise it just samples baseline loss.
4. **Recommendations** — copy-paste `nmcli` commands or in-the-moment actions, scoped to
   the current connection only.

## Reading the output

Per-family transfer verdict:

- **good** — completed.
- **slow** — kept moving but hit the time cap; works, just slow.
- **reset** — dropped mid-transfer (e.g. a carrier reset).
- **stalled** — barely moved / aborted; effectively dead.
- **fail** — got nothing.

What the recommendations mean:

- **Use IPv4 only** (`ipv6.method ignore`) — IPv6 fails to this server but IPv4 works.
- **Lower MTU** (`802-11-wireless.mtu <n>`) — only when a transfer *stalled* with a real
  size cliff (broken PMTUD). A path MTU below 1500 on its own is normal and harmless.
- **Weak signal** — move closer / clear obstructions, or use a resume-capable download.
- **High packet loss, signal fine** — interference or a congested/long link.
- **Dropped, nothing else explains it** — likely a server-side reset/throttle.

Every suggested `nmcli` change is **per-connection** — it affects only the network you're
on, and the output includes the commands to undo it.

## Notes & limitations

- It **never changes anything** — you run the suggested commands yourself.
- On a **phone hotspot**, the Wi-Fi link (laptop ↔ phone) is usually strong regardless of
  the room; the real bottleneck is the cellular uplink, which the tool reports as a
  congested/lossy link rather than a Wi-Fi problem.
- The **band is informational** — the tool does not recommend switching networks/bands.
- On a slow link, a run takes longer because the tool is sampling real transfers; that
  only happens when there's something real to measure.
