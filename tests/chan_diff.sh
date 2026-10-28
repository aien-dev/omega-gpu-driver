#!/bin/sh
# chan_diff.sh: builds the .om channel trace (chan/gmmu.om + chan/mem.om + chan/chan.om + chan/sim.om +
# tests/chan_trace.om) and the C reference trace (aienux PR #441 tests/gpu_chan_trace.c + gpu/gmmu.c +
# gpu/gpu_mem.c + gpu/gpu_chan.c + gpu/gpu_sim.c, compiled fresh into a temp dir as a test-only referee)
# and requires byte-identical stdout. Host only: the trace runs on the simulator (mmmode 0).
# Env: AIENUX (aienux checkout), OMC (pinned omc), GMMU_OM / MEM_OM / CHAN_OM / GSIM_OM (unit files to
# test; mutants use these), CHAN_REF (a C trace already produced by this script's referee build, so a
# mutant run skips the rebuild; the file must be non-empty).
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
AIENUX=${AIENUX:-/home/drakestapleton/work/OwnDriver/aienux}
OMC=${OMC:-$here/build/omc}
GMMU_OM=${GMMU_OM:-$here/chan/gmmu.om}
MEM_OM=${MEM_OM:-$here/chan/mem.om}
CHAN_OM=${CHAN_OM:-$here/chan/chan.om}
GSIM_OM=${GSIM_OM:-$here/chan/sim.om}
CHAN_REF=${CHAN_REF:-}
OMC_SHA=$(sed -n 's/^OMC_SHA256=//p' "$here/tools/omc.pin")
run() { nice -n 19 taskset -c 10-14 "$@"; }

got=$(sha256sum "$OMC" | cut -d' ' -f1)
if [ "$got" != "$OMC_SHA" ]; then
  echo "chan_diff: FAIL omc sha256 $got, pinned $OMC_SHA"; exit 2
fi
# The host trace must stay on the simulator: mode 0 only, no device words in the test driver,
# while the BAR0 (mode 1) branch stays present in the register seam.
if grep -n 'mmmode [0-9]* [1-9]\|mmbar\|vfio\|mapnew\|/dev/\|/sys/' "$here/tests/chan_trace.om"; then
  echo "chan_diff: FAIL test driver leaves simulator mode or names a device"; exit 2
fi
for w in 'ret mapget get mmbar 0 off 4' 'r = mapset get mmbar 0 off 4 v'; do
  if ! grep -qxF "$w" "$GMMU_OM"; then
    echo "chan_diff: FAIL BAR0 branch line missing from chan/gmmu.om: $w"; exit 2
  fi
done

t=$(mktemp -d /tmp/chan_diff.XXXXXX) || exit 2
trap 'rm -rf "$t"' EXIT
if [ -n "$CHAN_REF" ]; then
  [ -s "$CHAN_REF" ] || { echo "chan_diff: FAIL CHAN_REF $CHAN_REF missing or empty"; exit 2; }
  cp "$CHAN_REF" "$t/c.txt" || exit 2
else
  k=$AIENUX/native/kernel
  if ! run cc -std=c11 -O1 -Wall -Werror -I"$k/gpu" -o "$t/ctrace" \
      "$k/tests/gpu_chan_trace.c" "$k/gpu/gmmu.c" "$k/gpu/gpu_mem.c" "$k/gpu/gpu_chan.c" "$k/gpu/gpu_sim.c"; then
    echo "chan_diff: FAIL C reference build"; exit 2
  fi
  run "$t/ctrace" > "$t/c.txt" || { echo "chan_diff: FAIL C reference run"; exit 2; }
fi
if ! cat "$here/chan/dma.om" "$GMMU_OM" "$MEM_OM" "$CHAN_OM" "$GSIM_OM" "$here/tests/chan_trace.om" | run "$OMC" > "$t/omtrace"; then
  echo "chan_diff: FAIL omc build"; exit 3
fi
chmod +x "$t/omtrace"
run "$t/omtrace" > "$t/om.txt"
rc=$?
if [ "$rc" -ne 0 ]; then
  echo "chan_diff: FAIL om trace exit $rc"; exit 1
fi
n=$(wc -l < "$t/c.txt")
if [ "$n" -eq 0 ]; then
  echo "chan_diff: FAIL empty C trace"; exit 2
fi
if ! cmp -s "$t/c.txt" "$t/om.txt"; then
  echo "chan_diff: FAIL traces differ ($(diff "$t/c.txt" "$t/om.txt" | grep -c '^[<>]') differing lines; C $n lines, om $(wc -l < "$t/om.txt"))"
  exit 1
fi
echo "chan_diff: PASS ($n lines identical, .om vs C reference)"
