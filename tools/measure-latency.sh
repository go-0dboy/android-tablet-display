#!/usr/bin/env bash
#
# Measure end-to-end latency: Mac draws a frame -> tablet displays it.
#
# Method: latencyclock draws a millisecond timestamp encoded as blocks on the
# virtual display. This script screencaps the tablet, notes the wall-clock time
# either side of the capture, and decodes the timestamp the tablet was actually
# showing. The difference is how long that frame took to arrive.
#
# The capture instant sits somewhere between the two readings, so the result is
# reported as a range rather than a single number that pretends to more
# precision than the method has. `adb screencap` is not instant, and its cost
# is inside the upper bound.
#
# Both clocks must be the same clock. That is automatic for an emulator, which
# shares the host's clock. For a real handset, run this first:
#
#     adb shell su -c "date $(date +%m%d%H%M%Y.%S)"     # needs root, or
#     # simply enable "Set time automatically" on both, and accept ~tens of ms
#     # of NTP skew in the result.
#
# Usage:
#     ./tools/measure-latency.sh <adb-serial> [samples]

set -euo pipefail

SERIAL="${1:?usage: measure-latency.sh <adb-serial> [samples]}"
SAMPLES="${2:-30}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "Measuring $SAMPLES samples against $SERIAL ..."
echo

RESULTS="$WORK/results.txt"
: > "$RESULTS"

for i in $(seq 1 "$SAMPLES"); do
    BEFORE=$(python3 -c 'import time; print(int(time.time()*1000))')
    adb -s "$SERIAL" exec-out screencap -p > "$WORK/shot.png" 2>/dev/null
    AFTER=$(python3 -c 'import time; print(int(time.time()*1000))')

    LOWER=$(python3 "$ROOT/tools/decode-clock.py" "$WORK/shot.png" \
            --taken-at-ms "$BEFORE" 2>/dev/null | grep latency_ms | cut -d= -f2 || true)
    UPPER=$(python3 "$ROOT/tools/decode-clock.py" "$WORK/shot.png" \
            --taken-at-ms "$AFTER" 2>/dev/null | grep latency_ms | cut -d= -f2 || true)

    if [ -n "$LOWER" ] && [ -n "$UPPER" ]; then
        echo "$LOWER $UPPER $((AFTER - BEFORE))" >> "$RESULTS"
        printf "  sample %2d: %4s - %4s ms  (screencap took %d ms)\n" \
               "$i" "$LOWER" "$UPPER" "$((AFTER - BEFORE))"
    else
        printf "  sample %2d: clock not readable\n" "$i"
    fi
    sleep 0.25
done

echo
python3 - "$RESULTS" <<'PY'
import statistics, sys

rows = []
with open(sys.argv[1]) as handle:
    for line in handle:
        parts = line.split()
        if len(parts) == 3:
            rows.append(tuple(int(p) for p in parts))

if not rows:
    print("No readable samples. Is latencyclock running on the virtual display?")
    raise SystemExit(1)

lower = sorted(r[0] for r in rows)
upper = sorted(r[1] for r in rows)
overhead = sorted(r[2] for r in rows)

def summarise(name, values):
    print(f"{name:<28} min {min(values):4d}   median {int(statistics.median(values)):4d}"
          f"   p90 {values[int(len(values) * 0.9) - 1]:4d}   max {max(values):4d}")

print(f"samples: {len(rows)}")
summarise("latency, lower bound (ms)", lower)
summarise("latency, upper bound (ms)", upper)
summarise("screencap overhead (ms)", overhead)
print()
print("The true figure lies between the bounds. The lower bound excludes all")
print("screencap cost; the upper bound includes all of it.")
print()
median_overhead = int(statistics.median(overhead))
if median_overhead > 40:
    print(f"WARNING: `adb screencap` is costing about {median_overhead} ms per")
    print("sample, which is far more than the latency being measured. That")
    print("makes the bounds too far apart to be a useful figure. This happens")
    print("on emulators and on slow USB links.")
    print()
    print("For a real number, film both screens at 120fps or better and count")
    print("frames between the Mac's clock changing and the tablet's changing.")
    print("No software on either machine can measure its own display scanout.")
PY
