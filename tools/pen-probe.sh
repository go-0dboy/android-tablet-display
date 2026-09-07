#!/usr/bin/env bash
#
# Show what a tablet's digitiser actually reports.
#
# Turns on the client's pen diagnostics and tails the log. Draw, hover, and
# press the pen's side buttons; the axis values and button names appear here.
# Use it to confirm pressure/tilt/hover work on a given tablet before trusting
# them, rather than assuming the documented behaviour.
#
#     ./tools/pen-probe.sh <adb-serial>
#
# Ctrl-C to stop; diagnostics turn themselves off when the app restarts.

set -euo pipefail

SERIAL="${1:?usage: pen-probe.sh <adb-serial>}"
PACKAGE="com.usbtablet.display"

echo "Turning on pen diagnostics on $SERIAL ..."
adb -s "$SERIAL" shell am broadcast \
    -a "$PACKAGE.LOG_PEN" -p "$PACKAGE" --ez enabled true > /dev/null

echo
echo "Now, on the tablet:"
echo "  1. hover the pen just above the glass without touching"
echo "  2. draw a stroke, pressing lightly then hard"
echo "  3. tilt the pen right over and draw again"
echo "  4. hold the side button and tap"
echo "  5. if it has one, use the eraser end"
echo
echo "Watching (Ctrl-C to stop):"
echo

adb -s "$SERIAL" logcat -c
adb -s "$SERIAL" logcat -s USBDisplayPen:I
