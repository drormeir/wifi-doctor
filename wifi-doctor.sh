#!/usr/bin/env bash
# wifi-doctor: diagnose THIS network connection *toward a chosen server* and suggest
# NetworkManager settings (MTU + IPv4/IPv6) that get you through.
# Read-only: it changes nothing. It only prints commands you may choose to run.
#
# Usage:
#   wifi-doctor.sh                 # show the target menu and pick one
#   wifi-doctor.sh <alias>         # test a named target (e.g. pypi, claude, israel)
#   wifi-doctor.sh <url|hostname>  # test any server you paste
#   wifi-doctor.sh -l              # just list the targets and exit
#
# Why a target matters: path MTU, IPv6 health and resets all depend on the route to
# the destination. A connection can be fine to one server and broken to another.
#
# Run it while connected to the network you want checked (e.g. your phone hotspot).

set -u

TEST_BYTES=5000000   # cap data used per test (~5 MB via HTTP range)
DL_TIMEOUT=12        # hard cap (s) per transfer test — we sample, not wait for the full file
STALL_RATE=5000      # bytes/s; if throughput stays below this for STALL_SECS, abort early
STALL_SECS=5         # ...so a dead transfer ends in ~5 s instead of running the full cap

# --- editable target list:  alias|description|url ---------------------------
# Add your own lines below. Use __PYPI__ to fetch a live PyPI wheel at run time.
TARGETS="
pypi|PyPI — pip install (Python packages)|__PYPI__
claude|Claude / Anthropic|https://claude.ai/
openai|OpenAI / ChatGPT|https://chatgpt.com/
google|Google|https://www.google.com/
github|GitHub (code + release downloads)|https://github.com/
israel|Israeli sites (gov.il)|https://www.gov.il/
cloudflare|Generic internet health (Cloudflare)|https://speed.cloudflare.com/__down?bytes=5000000
"

b(){ printf '\033[1m%s\033[0m\n' "$*"; }
ok(){ printf '  \033[32mOK\033[0m  %s\n' "$*"; }
warn(){ printf '  \033[33m!!\033[0m  %s\n' "$*"; }
bad(){ printf '  \033[31mXX\033[0m  %s\n' "$*"; }
line(){ printf -- '------------------------------------------------------------\n'; }
host_of(){ printf '%s' "$1" | sed -E 's#^[a-z]+://##; s#[/?].*$##; s#:[0-9]+$##'; }

print_targets(){
  local n=0 alias name url
  while IFS='|' read -r alias name url; do
    [ -z "$alias" ] && continue
    n=$((n+1)); printf "   %d) %-11s %s\n" "$n" "$alias" "$name"
  done <<EOF
$TARGETS
EOF
}
resolve_choice(){ # $1 = number or alias -> echoes url, or returns 1
  local want="$1" n=0 alias name url
  while IFS='|' read -r alias name url; do
    [ -z "$alias" ] && continue
    n=$((n+1))
    if [ "$want" = "$alias" ] || [ "$want" = "$n" ]; then printf '%s' "$url"; return 0; fi
  done <<EOF
$TARGETS
EOF
  return 1
}
pypi_wheel_url(){ # a current PyPI wheel URL; robust on slow links (curl fetch + python parse)
  command -v python3 >/dev/null 2>&1 || return 1
  local json
  # 'pip' has a small JSON doc; fetch with curl (retry + generous timeout), parse offline
  json=$(curl -s -m 30 --retry 2 --retry-all-errors -A 'wifi-doctor' https://pypi.org/pypi/pip/json 2>/dev/null)
  [ -z "$json" ] && return 1
  printf '%s' "$json" | python3 -c '
import sys,json
try: d=json.load(sys.stdin)
except Exception: sys.exit(1)
for f in d.get("urls",[]):
    if f["filename"].endswith(".whl"):
        print(f["url"]); break
'
}

# --- 0. choose the target server -------------------------------------------
arg="${1:-}"
case "$arg" in
  -l|--list|list) b "Available targets:"; print_targets; exit 0 ;;
  -h|--help) sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
esac

choice="$arg"
if [ -z "$choice" ]; then
  b "Pick a target to test (the server you're having trouble reaching):"
  print_targets
  if [ -t 0 ]; then
    printf "\nEnter a number, an alias, or paste any URL/host: "
    read -r choice
  else
    printf "\n"; warn "Non-interactive: re-run with an alias or URL, e.g.  wifi-doctor.sh pypi"; exit 1
  fi
fi
[ -z "$choice" ] && { warn "No target chosen."; exit 1; }

if printf '%s' "$choice" | grep -q '://'; then TARGET_URL="$choice"
elif TARGET_URL="$(resolve_choice "$choice")"; then :
else TARGET_URL="https://$choice/"; fi      # treat bare input as a hostname

target_note=""
if [ "$TARGET_URL" = "__PYPI__" ]; then
  TARGET_URL="$(pypi_wheel_url)"
  if [ -z "$TARGET_URL" ]; then
    # PyPI's metadata lookup failed (often on a slow link). Fall back to a real,
    # fixed-size file so the transfer test stays meaningful instead of fetching
    # a near-empty page and falsely reporting "healthy".
    TARGET_URL="https://speed.cloudflare.com/__down?bytes=${TEST_BYTES}"
    target_note="(couldn't reach PyPI for a test file — using a generic ${TEST_BYTES}-byte file instead)"
  fi
fi
HOST="$(host_of "$TARGET_URL")"
host_v4=$(getent ahostsv4 "$HOST" 2>/dev/null | awk 'NR==1{print $1}')
host_v6=$(getent ahostsv6 "$HOST" 2>/dev/null | awk 'NR==1{print $1}')

# --- 1. identify the active connection -------------------------------------
dev=$(nmcli -t -f DEVICE,TYPE device status 2>/dev/null | awk -F: '$2=="wifi"{print $1; exit}')
[ -z "${dev:-}" ] && dev=$(ip -o route get 1.1.1.1 2>/dev/null | sed -n 's/.* dev \([^ ]*\).*/\1/p')
conn=$(nmcli -t -f NAME,DEVICE connection show --active 2>/dev/null | awk -F: -v d="$dev" '$2==d{print $1; exit}')
ctype=$(nmcli -t -f TYPE,DEVICE connection show --active 2>/dev/null | awk -F: -v d="$dev" '$2==d{print $1; exit}')
mtu=$(cat /sys/class/net/"$dev"/mtu 2>/dev/null)
loc_v4=$(ip -4 addr show dev "$dev" scope global 2>/dev/null | grep -c 'inet ')
loc_v6=$(ip -6 addr show dev "$dev" scope global 2>/dev/null | grep -c 'inet6 ')
have_v4=0; [ "${loc_v4:-0}" -gt 0 ] && [ -n "$host_v4" ] && have_v4=1
have_v6=0; [ "${loc_v6:-0}" -gt 0 ] && [ -n "$host_v6" ] && have_v6=1

case "$ctype" in
  802-11-wireless) MTU_KEY="802-11-wireless.mtu" ;;
  802-3-ethernet)  MTU_KEY="802-3-ethernet.mtu" ;;
  *)               MTU_KEY="${ctype}.mtu" ;;
esac

# Wi-Fi signal strength (local radio link quality) — only relevant for wifi
sig_dbm=""; sig_show=""; sig_label=""; sig_weak=0; freq=""; band=""
if [ "$ctype" = "802-11-wireless" ]; then
  iwlink=$(iw dev "$dev" link 2>/dev/null)
  sig_dbm=$(printf '%s\n' "$iwlink" | sed -n 's/.*signal:[[:space:]]*\(-\{0,1\}[0-9]\{1,\}\)[[:space:]]*dBm.*/\1/p')
  freq=$(printf '%s\n' "$iwlink" | sed -n 's/.*freq:[[:space:]]*\([0-9]\{3,\}\).*/\1/p' | head -1)
  [ -z "$freq" ] && freq=$(nmcli -t -f IN-USE,FREQ device wifi 2>/dev/null | awk -F: '$1=="*"{print $2; exit}' | tr -dc '0-9')
  if [ -n "$sig_dbm" ]; then
    sig_show="${sig_dbm} dBm"
    if   [ "$sig_dbm" -ge -60 ]; then sig_label="strong"
    elif [ "$sig_dbm" -ge -70 ]; then sig_label="ok"
    elif [ "$sig_dbm" -ge -78 ]; then sig_label="weak"; sig_weak=1
    else sig_label="very weak"; sig_weak=1; fi
  else
    sig_pct=$(nmcli -t -f IN-USE,SIGNAL device wifi 2>/dev/null | awk -F: '$1=="*"{print $2; exit}')
    if [ -n "${sig_pct:-}" ]; then
      sig_show="${sig_pct}%"
      if   [ "$sig_pct" -ge 55 ]; then sig_label="strong"
      elif [ "$sig_pct" -ge 40 ]; then sig_label="ok"
      else sig_label="weak"; sig_weak=1; fi
    fi
  fi
  if [ -n "$freq" ]; then
    if   [ "$freq" -ge 2400 ] && [ "$freq" -le 2500 ]; then band="2.4 GHz"
    elif [ "$freq" -ge 4900 ] && [ "$freq" -le 5895 ]; then band="5 GHz"
    elif [ "$freq" -ge 5925 ]; then band="6 GHz"; fi
  fi
fi

b "wifi-doctor — checking THIS connection toward your chosen server"
line
printf "  target host : %s\n" "${HOST:-?}"
[ -n "$target_note" ] && printf "  note        : %s\n" "$target_note"
printf "  target IPv4 : %s\n" "${host_v4:-<none>}"
printf "  target IPv6 : %s\n" "${host_v6:-<none>}"
printf "  device      : %s\n" "${dev:-unknown}"
printf "  connection  : %s\n" "${conn:-<not NetworkManager-managed>}"
printf "  interface MTU: %s\n" "${mtu:-unknown}"
[ -n "$sig_label" ] && printf "  wifi signal : %s (%s)\n" "${sig_show}" "$sig_label"
if [ -n "$band" ]; then printf "  wifi band   : %s (%s MHz)\n" "$band" "$freq"
elif [ -n "$freq" ]; then printf "  wifi band   : %s MHz\n" "$freq"; fi
line

# --- 2. transfer tests (detect resets / slow / one family broken) ----------
run_dl(){ # $1 = -4 or -6 ; echoes "http;bytes;speed;time;rc"
  local out rc
  # --speed-limit/--speed-time abort a dead transfer early; -m is the hard cap.
  out=$(curl "$1" -sL -A 'Mozilla/5.0' -o /dev/null --range 0-$((TEST_BYTES-1)) \
        -m "$DL_TIMEOUT" --speed-limit "$STALL_RATE" --speed-time "$STALL_SECS" \
        -w '%{http_code};%{size_download};%{speed_download};%{time_total}' \
        "$TARGET_URL" 2>/dev/null); rc=$?
  echo "${out};${rc}"
}
# Conclude from a short sample, not by waiting for the whole file:
#   good = completed; slow = kept moving but hit the cap; stalled = died/aborted;
#   reset = dropped mid-transfer; fail = never got anything.
verdict(){ # $1=bytes $2=rc $3=speed -> good|slow|reset|stalled|fail
  local bytes="${1:-0}" rc="$2" spd="${3:-0}"; spd=${spd%%.*}
  case "$rc" in
    0)     echo good;;
    28)    if [ "${spd:-0}" -ge "$STALL_RATE" ]; then echo slow; else echo stalled; fi;;
    18|56) echo reset;;
    *)     if [ "$bytes" -gt 0 ]; then echo reset; else echo fail; fi;;
  esac
}
works(){ case "$1" in good|slow) return 0;; *) return 1;; esac; }   # usable
broke(){ case "$1" in reset|stalled|fail) return 0;; *) return 1;; esac; }  # failed to get through
human_speed(){ awk -v s="${1:-0}" 'BEGIN{printf (s>=1048576)?"%.1f MB/s":"%.0f KB/s", (s>=1048576)?s/1048576:s/1024}'; }

v4v=""; v6v=""; v4res=""; v6res=""
b "Transfer test from $HOST (up to ${DL_TIMEOUT}s each, ≤${TEST_BYTES} bytes)"
if [ "$have_v4" -eq 1 ]; then
  printf "  testing IPv4 (up to %ss)...\r" "$DL_TIMEOUT"
  IFS=';' read -r h4 by4 s4 t4 r4 <<<"$(run_dl -4)"; printf '\033[K'
  v4v=$(verdict "$by4" "$r4" "$s4"); v4res="$s4"
  case "$v4v" in
    good)    ok   "IPv4: completed, $(human_speed "$s4") (${t4}s)";;
    slow)    warn "IPv4: works but slow, $(human_speed "$s4")";;
    reset)   warn "IPv4: dropped/reset after ${by4} bytes (curl exit $r4)";;
    stalled) warn "IPv4: stalled — almost no data in ${t4}s (${by4} bytes)";;
    fail)    bad  "IPv4: failed (curl exit $r4)";;
  esac
else warn "IPv4: not testable (no IPv4 on this machine or target)"; fi
if [ "$have_v6" -eq 1 ]; then
  printf "  testing IPv6 (up to %ss)...\r" "$DL_TIMEOUT"
  IFS=';' read -r h6 by6 s6 t6 r6 <<<"$(run_dl -6)"; printf '\033[K'
  v6v=$(verdict "$by6" "$r6" "$s6"); v6res="$s6"
  case "$v6v" in
    good)    ok   "IPv6: completed, $(human_speed "$s6") (${t6}s)";;
    slow)    warn "IPv6: works but slow, $(human_speed "$s6")";;
    reset)   warn "IPv6: dropped/reset after ${by6} bytes (curl exit $r6)";;
    stalled) warn "IPv6: stalled — almost no data in ${t6}s (${by6} bytes)";;
    fail)    bad  "IPv6: failed (curl exit $r6)";;
  esac
else warn "IPv6: not testable (no IPv6 on this machine or target)"; fi
line

# --- 3. path-MTU vs packet-loss analysis toward the target -----------------
# Tells a real MTU limit (a SHARP size cliff: small packets pass, big ones drop
# ~100%) apart from weak-signal/interference loss (a FUZZY gradient at all sizes),
# so a lossy link is not misread as a small MTU. Measures loss% per size.
PASS_LOSS=40    # a size "works" if its loss% <= this
CLIFF_LOSS=70   # bigger-than-MTU sizes "clearly fail" if loss% >= this (a cliff)
BASE_LOSSY=25   # baseline small-packet loss above this => link itself is lossy
K_BASE=6; K_PROBE=3
MTU_CANDS="1500 1492 1480 1460 1420 1400 1360 1320 1280"
ping_loss(){ # $1=-4|-6 $2=payload $3=ip $4=count -> loss% (100 if unreachable)
  local out l
  out=$(ping "$1" -M do -s "$2" -c "$4" -W 1 -i 0.2 "$3" 2>/dev/null)
  l=$(printf '%s\n' "$out" | sed -n 's/.*[^0-9]\([0-9]\{1,3\}\)% packet loss.*/\1/p' | head -1)
  [ -z "$l" ] && l=100; echo "$l"
}
pmtu_measure(){ # $1=-4|-6 $2=overhead $3=ip -> "verdict|mtu|baseloss|aboveloss"
  command -v ping >/dev/null 2>&1 || { echo "blocked|||"; return; }
  local fam=$1 oh=$2 ip=$3 base above="" best="" l c iface=${mtu:-1500}
  base=$(ping_loss "$fam" 56 "$ip" "$K_BASE")
  [ "$base" -ge 100 ] && { echo "blocked||$base|"; return; }
  [ "$base" -gt "$BASE_LOSSY" ] && { echo "lossy||$base|"; return; }   # too lossy to trust MTU
  # The expensive cliff search only matters if a transfer stalled; skip it otherwise.
  [ "${need_cliff:-1}" -eq 0 ] && { echo "okbase||$base|"; return; }
  for c in $MTU_CANDS; do
    [ "$c" -gt "$iface" ] && continue
    l=$(ping_loss "$fam" $((c-oh)) "$ip" "$K_PROBE")
    if [ "$l" -le "$PASS_LOSS" ]; then best=$c; break; else above=$l; fi
  done
  [ -z "$best" ] && { echo "lossy||$base|${above:-}"; return; }
  [ "$best" -ge "$iface" ] && { echo "fullok|$best|$base|${above:-}"; return; }
  [ -z "$above" ] && above=$(ping_loss "$fam" $((iface-oh)) "$ip" "$K_PROBE")
  if [ "${above:-0}" -ge "$CLIFF_LOSS" ]; then echo "clean_mtu|$best|$base|$above"
  else echo "soft|$best|$base|$above"; fi
}
b "Path MTU / packet-loss analysis toward $HOST"
# Only do the full size-cliff search if a transfer broke (that's the only case the
# MTU value is actionable). Otherwise just a quick baseline-loss check.
need_cliff=0; { broke "$v4v" || broke "$v6v"; } && need_cliff=1
st4=""; st6=""
if [ "$have_v4" -eq 1 ]; then printf "  probing IPv4 (sending pings)...\r"; st4=$(pmtu_measure -4 28 "$host_v4"); printf '\033[K'; fi
if [ "$have_v6" -eq 1 ]; then printf "  probing IPv6 (sending pings)...\r"; st6=$(pmtu_measure -6 48 "$host_v6"); printf '\033[K'; fi
report_mtu(){ local v m base above; IFS='|' read -r v m base above <<<"$2"
  case "$v" in
    okbase)    ok   "$1: baseline loss ${base}% — link looks clean (cliff search skipped; transfer was fine)";;
    fullok)    ok   "$1: full-size packets OK (up to ${m}; loss ${base}%) — no MTU problem";;
    clean_mtu) ok   "$1: path MTU = ${m} (carries up to ${m}, not full ${mtu:-1500}; harmless if the transfer above worked)";;
    soft)      warn "$1: path MTU looks ~${m} but not a clean cliff (baseline loss ${base}%) — uncertain";;
    lossy)     warn "$1: high packet loss (baseline ${base}%) — lossy link (weak signal/interference); MTU not reliably measurable";;
    blocked)   warn "$1: could not measure (server/network blocks ping)";;
    *)         warn "$1: no result";;
  esac; }
[ "$have_v4" -eq 1 ] && report_mtu "IPv4" "$st4"
[ "$have_v6" -eq 1 ] && report_mtu "IPv6" "$st6"
rec_mtu=""; lossy_link=0
for s in "$st4" "$st6"; do
  [ -n "$s" ] || continue
  IFS='|' read -r v m _b _a <<<"$s"
  case "$v" in
    clean_mtu) if [ -n "$m" ] && { [ -z "$rec_mtu" ] || [ "$m" -lt "$rec_mtu" ]; }; then rec_mtu="$m"; fi;;
    soft)      [ -z "$rec_mtu" ] && [ -n "$m" ] && rec_mtu="$m";;
    lossy)     lossy_link=1;;
  esac
done
line

# --- 4. recommendations ----------------------------------------------------
b "RECOMMENDATIONS for this connection${conn:+ (\"$conn\")} toward $HOST"
nmcli_recs=0; advice=0; broke_explained=0
target=${conn:-<connection-name>}

# Weak signal is a LOCAL radio problem, below IP — it hits IPv4 and IPv6 alike,
# and none of the nmcli tweaks fix it. Address it first, with in-the-moment actions
# that need no other network.
if [ "$sig_weak" -eq 1 ]; then
  advice=1
  warn "Weak Wi-Fi signal (${sig_show}). This slows traffic and drops packets on ANY network, IPv4 and IPv6 alike."
  printf "      Best action now: get closer to the router, or remove what's between you and it\n"
  printf "      (walls, floors, a closed door, large metal objects/appliances). Even a small move can help.\n"
  printf "      If you can't move, just get the job done despite the drops — use a resume-capable download:\n"
  printf "        curl -C - -O <url>      # or:   wget -c <url>\n"
  if broke "$v4v" || broke "$v6v" || [ "$lossy_link" -eq 1 ]; then
    printf "      (The stalls/loss above are the weak signal — not a packet-size/MTU issue.)\n"
  fi
fi

if [ "$have_v6" -eq 1 ] && broke "$v6v" && works "$v4v" && [ "$sig_weak" -eq 0 ]; then
  nmcli_recs=$((nmcli_recs+1)); advice=1; broke_explained=1
  warn "IPv6 fails to this server but IPv4 works. Use IPv4 only on THIS network:"
  printf "      nmcli connection modify \"%s\" ipv6.method ignore\n" "$target"
fi
if [ "$have_v6" -eq 1 ] && works "$v6v" && works "$v4v" && [ "$sig_weak" -eq 0 ] \
   && [ "${by4:-0}" -ge 500000 ] && [ "${by6:-0}" -ge 500000 ] \
   && awk -v a="${v6res:-0}" -v c="${v4res:-1}" 'BEGIN{exit !(c>0 && a>0 && c/a>3)}'; then
  nmcli_recs=$((nmcli_recs+1)); advice=1
  warn "IPv6 works but is much slower than IPv4 here. Optional, prefer IPv4 on THIS network:"
  printf "      nmcli connection modify \"%s\" ipv6.method ignore\n" "$target"
fi
# Lower MTU only on a genuine STALL (timeout/hang) with a measured size-cliff — the
# signature of broken PMTUD. A clean reset (exit 56) is a carrier drop, not MTU; and a
# path MTU below 1500 is normal/harmless on its own (TCP copes via PMTUD).
if { [ "$v4v" = stalled ] || [ "$v6v" = stalled ]; } && [ "$sig_weak" -eq 0 ] && [ "$lossy_link" -eq 0 ] \
   && [ -n "$rec_mtu" ] && [ -n "${mtu:-}" ] && [ "$rec_mtu" -lt "$mtu" ]; then
  nmcli_recs=$((nmcli_recs+1)); advice=1; broke_explained=1
  warn "A transfer stalled and big packets are being dropped (broken PMTUD). Lower MTU on THIS network to $rec_mtu:"
  printf "      nmcli connection modify \"%s\" %s %s\n" "$target" "$MTU_KEY" "$rec_mtu"
fi
# Lossy link while the signal is fine -> interference/congestion, not packet size.
if [ "$lossy_link" -eq 1 ] && [ "$sig_weak" -eq 0 ]; then
  advice=1
  warn "High packet loss to this server, but Wi-Fi signal looks fine — likely interference or a congested/long link."
  printf "      Best action now: retry, reduce interference, or use a resume-capable download:\n"
  printf "        curl -C - -O <url>      # or:   wget -c <url>\n"
fi
# Transfer broke and nothing above explained it -> likely a server-side reset/throttle.
if { broke "$v4v" || broke "$v6v"; } && [ "$sig_weak" -eq 0 ] \
   && [ "$lossy_link" -eq 0 ] && [ "$broke_explained" -eq 0 ]; then
  advice=1
  warn "A transfer dropped, but it isn't your signal, MTU or packet loss — likely a server-side reset/throttle."
  printf "      Best action now: use a resume-capable download so resets just continue:\n"
  printf "        curl -C - -O <url>      # or:   wget -c <url>\n"
fi
# Works but slow, with nothing else wrong -> not a setting; just the link's capacity.
if { [ "$v4v" = slow ] || [ "$v6v" = slow ]; } && [ "$nmcli_recs" -eq 0 ] && [ "$advice" -eq 0 ]; then
  advice=1
  warn "Connection works but is slow on this link (likely the link/uplink capacity, not a setting)."
  printf "      For big files, a resume-capable download avoids restarts if it hiccups:\n"
  printf "        curl -C - -O <url>      # or:   wget -c <url>\n"
fi

if [ "$nmcli_recs" -eq 0 ] && [ "$advice" -eq 0 ]; then
  ok "No changes needed — this connection looks healthy toward $HOST."
fi
if [ "$nmcli_recs" -gt 0 ]; then
  printf "\n  After applying any nmcli command above, re-activate the connection:\n"
  printf "      nmcli connection up \"%s\"\n" "$target"
  printf "  To undo later:\n"
  printf "      nmcli connection modify \"%s\" ipv6.method auto\n" "$target"
  printf "      nmcli connection modify \"%s\" %s 0   # 0 = automatic/default\n" "$target" "$MTU_KEY"
fi
line
if [ "$nmcli_recs" -gt 0 ]; then
  printf "Note: the nmcli commands above change ONLY \"%s\". Other Wi-Fi networks are unaffected.\n" "$target"
fi
