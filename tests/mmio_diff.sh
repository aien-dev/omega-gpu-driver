#!/bin/sh
# mmio_diff.sh: builds the .om GSP start-up trace (gsp/mmio.om + gsp/sim.om + tests/mmio_trace.om) and the
# C reference trace (aienux PR #441 tests/gsp_boot_trace.c + gpu/gsp_mmio.c + gpu/gsp_sim.c, compiled
# fresh into a temp dir as a test-only referee) and requires byte-identical stdout. Host only.
# Env: AIENUX (aienux checkout), OMC (pinned omc), MMIO_OM (driver file to test; mutants use this).
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
AIENUX=${AIENUX:-/home/drakestapleton/work/OwnDriver/aienux}
OMC=${OMC:-$here/build/omc}
MMIO_OM=${MMIO_OM:-$here/gsp/mmio.om}
OMC_SHA=$(sed -n 's/^OMC_SHA256=//p' "$here/tools/omc.pin")
run() { nice -n 19 taskset -c 10-14 "$@"; }

got=$(sha256sum "$OMC" | cut -d' ' -f1)
if [ "$got" != "$OMC_SHA" ]; then
  echo "mmio_diff: FAIL omc sha256 $got, pinned $OMC_SHA"; exit 2
fi
# The host trace must stay on the simulator: mode 0 only, no device words in the test driver,
# while the BAR0 (mode 1) branch stays present in the driver.
if grep -n 'gspmode [0-9]* [1-9]\|gspbar\|vfio\|mapnew\|/dev/\|/sys/' "$here/tests/mmio_trace.om"; then
  echo "mmio_diff: FAIL test driver leaves simulator mode or names a device"; exit 2
fi
for w in 'ret mapget get gspbar 0 off 4' 'r = mapset get gspbar 0 off 4 v' 'r = sleepns get gsppns 0'; do
  if ! grep -qxF "$w" "$here/gsp/mmio.om"; then
    echo "mmio_diff: FAIL BAR0 branch line missing from gsp/mmio.om: $w"; exit 2
  fi
done

t=$(mktemp -d /tmp/mmio_diff.XXXXXX) || exit 2
trap 'rm -rf "$t"' EXIT
k=$AIENUX/native/kernel
if ! run cc -std=c11 -O1 -Wall -Werror -I"$k/gpu" -o "$t/ctrace" \
    "$k/tests/gsp_boot_trace.c" "$k/gpu/gsp_mmio.c" "$k/gpu/gsp_sim.c"; then
  echo "mmio_diff: FAIL C reference build"; exit 2
fi
run "$t/ctrace" > "$t/c.txt" || { echo "mmio_diff: FAIL C reference run"; exit 2; }
if ! cat "$MMIO_OM" "$here/gsp/sim.om" "$here/tests/mmio_trace.om" | run "$OMC" > "$t/omtrace"; then
  echo "mmio_diff: FAIL omc build"; exit 3
fi
chmod +x "$t/omtrace"
run "$t/omtrace" > "$t/om.txt"
rc=$?
if [ "$rc" -ne 0 ]; then
  echo "mmio_diff: FAIL om trace exit $rc"; exit 1
fi
n=$(wc -l < "$t/c.txt")
if [ "$n" -eq 0 ]; then
  echo "mmio_diff: FAIL empty C trace"; exit 2
fi
if ! cmp -s "$t/c.txt" "$t/om.txt"; then
  echo "mmio_diff: FAIL traces differ ($(diff "$t/c.txt" "$t/om.txt" | grep -c '^[<>]') differing lines; C $n lines, om $(wc -l < "$t/om.txt"))"
  exit 1
fi
echo "mmio_diff: PASS ($n lines identical, $(grep -c '^==' "$t/c.txt") scenarios, .om vs C reference)"
