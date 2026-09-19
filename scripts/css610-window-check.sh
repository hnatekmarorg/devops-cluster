#!/usr/bin/env bash
# css610-window-check.sh — before/after checks for the CSS610 cut-over window.
#
# Run this on the **Hermes host (.180)**: it sits in compat and the router routes it to mgmt and lab,
# so one machine can see every plane involved. Read-only throughout — pings, a TCP probe, HTTP GETs and
# a systemd status. Nothing is configured, nothing is written to any device.
#
#   ./css610-window-check.sh pre     # before touching anything: record the baseline
#   ./css610-window-check.sh post    # after the window: verify, with expected values printed
#
# The agent cannot help inside the window: its own inference runs on the Sparks through lmproxy, so the
# moment spark1 is re-addressed the agent goes dark until lmproxy points at the lab address. That is why
# this script exists as something a human runs.
set -uo pipefail

LMCFG=/opt/lmproxy/config.yaml     # lives on the Hermes host; absent elsewhere
MODE="${1:-}"
case "$MODE" in pre|post) ;; *) echo "usage: $0 pre|post" >&2; exit 64 ;; esac

# Spark management NICs: their flat address today, their prepared static lab lease after the move.
declare -A FLAT=( [spark1]=172.16.100.136 [spark2]=172.16.100.137 [spark3]=172.16.100.112 [spark4]=172.16.100.110 )
declare -A LAB=(  [spark1]=172.16.30.136  [spark2]=172.16.30.137  [spark3]=172.16.30.112  [spark4]=172.16.30.110 )
ORDER=(spark1 spark2 spark3 spark4)

ok=0; bad=0
line() { printf '  %-28s %-22s %s\n' "$1" "$2" "$3"; }
up()   { printf '  %-28s %-22s %s\n' "$1" "$2" "UP"; ok=$((ok+1)); }
down() { printf '  %-28s %-22s %s\n' "$1" "$2" "unreachable"; bad=$((bad+1)); }

ping1() { # host label
  if ping -c1 -W2 -q "$1" >/dev/null 2>&1; then up "$2" "$1"; else down "$2" "$1"; fi
}
http1() { # url label
  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 6 "$1" 2>/dev/null)" || true
  [ -n "$code" ] || code=000          # curl prints 000 itself on a refusal; empty means it never ran
  if [ "$code" = "200" ]; then up "$2" "$1"; else line "$2" "$1" "HTTP ${code}"; bad=$((bad+1)); fi
}

echo "=== css610 window check ($MODE), $(date -u +%FT%TZ), from $(hostname) ==="
echo

echo "-- the fixed points (must never change) --"
ping1 172.16.100.1   "router (compat 172.16.100.1)"
ping1 172.16.100.2   "main switch (compat .2)"
ping1 172.16.10.201  "spine CRS804 (mgmt .201 — compat .113 retired 2026-09-15)"
ping1 172.16.100.117 "CSS610 itself (compat .117)"
ping1 172.16.10.1    "router (mgmt .10.1)"
ping1 172.16.10.2    "main switch (mgmt .10.2)"

if [ "$MODE" = pre ]; then
  echo
  echo "-- Sparks on their FLAT addresses (the baseline to lose and to restore) --"
  for s in "${ORDER[@]}"; do
    ping1 "${FLAT[$s]}" "$s (${FLAT[$s]})"
    http1 "http://${FLAT[$s]}:8000/v1/models" "$s inference :8000"
  done
  echo
  echo "-- charon, the work PC, on the flat address it has today --"
  ping1 172.16.100.227 "charon (flat .227)"
  echo
  echo "-- what the agent's brain depends on --"
  if [ -f "$LMCFG" ]; then
    echo "  lmproxy: $(systemctl is-active lmproxy 2>/dev/null) | endpoints in $LMCFG:"
    grep -nE '^ *- host:' "$LMCFG" 2>/dev/null | sed 's/^/    /'
  else
    echo "  lmproxy: NOT ON THIS HOST — that check only means something on the Hermes host (.180)."
    echo "           From anywhere else it proves nothing, so it is skipped, not counted."
  fi
  echo
  echo "BASELINE: ${ok} up, ${bad} not answering. Keep this output — it is the 'before' record."
  exit 0
fi

echo
echo "-- Sparks on their LAB leases (expected after the move) --"
for s in "${ORDER[@]}"; do
  ping1 "${LAB[$s]}" "$s (${LAB[$s]})"
  # Only spark1 serves inference; the others answer on SSH, so a refused :8000 is not a failure there.
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://${LAB[$s]}:8000/v1/models" 2>/dev/null)" || true
  [ -n "$code" ] || code=000
  line "$s inference :8000" "${LAB[$s]}:8000" "HTTP ${code}"
done

echo
echo "-- did the flat addresses leave? (they should be gone: the NIC moved VLAN) --"
for s in "${ORDER[@]}"; do
  if ping -c1 -W2 -q "${FLAT[$s]}" >/dev/null 2>&1; then
    line "$s" "${FLAT[$s]}" "STILL ANSWERING — lease may be lingering in the flat pool"
    bad=$((bad+1))
  else
    line "$s" "${FLAT[$s]}" "gone (expected)"
  fi
done

echo
echo "-- the agent's brain: lmproxy must now point at the lab address --"
if [ -f "$LMCFG" ]; then
  echo "  lmproxy: $(systemctl is-active lmproxy 2>/dev/null)"
  grep -nE '^ *- host:' "$LMCFG" 2>/dev/null | grep -q '172.16.30.136' \
    && line "lmproxy config" "172.16.30.136" "updated" \
    || { line "lmproxy config" "still 172.16.100.136?" "NOT updated — the agent stays dark"; bad=$((bad+1)); }
else
  echo "  lmproxy: not present on this host — nothing to check from here."
  echo "  Run this mode on the Hermes host (.180) for that line to mean anything:"
  echo "    sudo sed -i 's|http://172.16.100.136:8000|http://172.16.30.136:8000|' $LMCFG && sudo systemctl restart lmproxy"
fi

echo
echo "-- charon: its flat address must be gone; its mgmt lease is in 172.16.10.200-250 --"
if ping -c1 -W2 -q 172.16.100.227 >/dev/null 2>&1; then
  line "charon" "172.16.100.227" "still on the flat address (hasn't moved, or moved back)"
else
  line "charon" "172.16.100.227" "gone (expected if Port2 moved to mgmt)"
fi
echo "  read its new address from the router, do not guess it:"
echo "    ssh into the RB5009 or use WinBox → IP → DHCP Server → Leases, filter host-name 'charon'"
echo "    (expected: 172.16.10.20x from dhcp-mgmt)"

echo
echo "RESULT: ${ok} up, ${bad} to look at. Remember: Port4 (spine mgmt) and Port1 (perch) stay compat"
echo "in this window; the Sparks must keep the same address *suffix* (.136/.137/.112/.110)."
