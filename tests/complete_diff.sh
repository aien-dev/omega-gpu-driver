#!/bin/sh
# tests/complete_diff.sh: builds the .om completion trace (chan/dma.om + chan/gmmu.om + chan/mem.om +
# chan/chan.om + chan/sim.om + chan/complete.om + tests/complete_trace.om) and the C reference trace
# tests/complete_ref.c (compiled fresh into a temp dir against NVIDIA open-gpu-kernel-modules 580.173.02
# clc96f.h headers) and requires byte-identical stdout. Host only.
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
OMC=${OMC:-$here/build/omc}
COMPLETE_OM=${COMPLETE_OM:-$here/chan/complete.om}
OGKM_SRC=${OGKM_SRC:-/home/drakestapleton/workspace/_ext/open-gpu-kernel-modules-580.173.02/src}
COMPLETE_REF=${COMPLETE_REF:-}
OMC_SHA=$(sed -n 's/^OMC_SHA256=//p' "$here/tools/omc.pin")
run() { nice -n 19 taskset -c 10-14 "$@"; }

got=$(sha256sum "$OMC" | cut -d' ' -f1)
if [ "$got" != "$OMC_SHA" ]; then
  echo "complete_diff: FAIL omc sha256 $got, pinned $OMC_SHA"; exit 2
fi

t=$(mktemp -d /tmp/complete_diff.XXXXXX) || exit 2
trap 'rm -rf "$t"' EXIT

if [ -n "$COMPLETE_REF" ]; then
  [ -s "$COMPLETE_REF" ] || { echo "complete_diff: FAIL COMPLETE_REF $COMPLETE_REF missing or empty"; exit 2; }
  cp "$COMPLETE_REF" "$t/c.txt" || exit 2
else
  S=$OGKM_SRC
  if ! run cc -std=c11 -O1 -Wall -Werror \
      -I"$S/common/sdk/nvidia/inc" -I"$S/nvidia/arch/nvalloc/common/inc" -I"$S/common/uproc/os/common/include" \
      -I"$S/nvidia/inc/kernel" -I"$S/nvidia/inc" -I"$S/nvidia/generated" -I"$S/common/shared/msgq/inc" \
      -I"$S/nvidia/interface" -I"$S/common/inc" -o "$t/cref" "$here/tests/complete_ref.c"; then
    echo "complete_diff: FAIL C reference build"; exit 2
  fi
  run "$t/cref" > "$t/c.txt" || { echo "complete_diff: FAIL C reference run"; exit 2; }
fi

if ! cat "$here/chan/dma.om" "$here/chan/gmmu.om" "$here/chan/mem.om" "$here/chan/chan.om" "$here/chan/sim.om" "$COMPLETE_OM" "$here/tests/complete_trace.om" | run "$OMC" > "$t/omtrace"; then
  echo "complete_diff: FAIL omc build"; exit 3
fi
chmod +x "$t/omtrace"
run "$t/omtrace" > "$t/om.txt"
rc=$?
if [ "$rc" -ne 0 ]; then
  echo "complete_diff: FAIL om trace exit $rc"; exit 1
fi
n=$(wc -l < "$t/c.txt")
if [ "$n" -eq 0 ]; then
  echo "complete_diff: FAIL empty C trace"; exit 2
fi
if ! cmp -s "$t/c.txt" "$t/om.txt"; then
  echo "complete_diff: FAIL traces differ ($(diff "$t/c.txt" "$t/om.txt" | grep -c '^[<>]') differing lines; C $n lines, om $(wc -l < "$t/om.txt"))"
  exit 1
fi
echo "complete_diff: PASS ($n lines identical, .om vs C reference)"
