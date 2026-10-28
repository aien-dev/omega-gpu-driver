#!/bin/sh
# tests/rmchan_diff.sh: builds the .om RM channel trace (gsp/rpc.om + gsp/sysinfo.om + chan/params.om +
# gsp/boot.om + chan/dma.om + chan/gmmu.om + chan/mem.om + chan/chan.om + chan/sim.om + chan/complete.om +
# chan/rmchan.om + tests/rmchan_trace.om) and the C reference trace tests/rmchan_ref.c (compiled fresh
# against NVIDIA open-gpu-kernel-modules 580.173.02 headers) and requires byte-identical stdout. Host only.
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
OMC=${OMC:-$here/build/omc}
RMCHAN_OM=${RMCHAN_OM:-$here/chan/rmchan.om}
OGKM_SRC=${OGKM_SRC:-/home/drakestapleton/workspace/_ext/open-gpu-kernel-modules-580.173.02/src}
RMCHAN_REF=${RMCHAN_REF:-}
OMC_SHA=$(sed -n 's/^OMC_SHA256=//p' "$here/tools/omc.pin")
run() { nice -n 19 taskset -c 10-14 "$@"; }

got=$(sha256sum "$OMC" | cut -d' ' -f1)
if [ "$got" != "$OMC_SHA" ]; then
  echo "rmchan_diff: FAIL omc sha256 $got, pinned $OMC_SHA"; exit 2
fi

t=$(mktemp -d /tmp/rmchan_diff.XXXXXX) || exit 2
trap 'rm -rf "$t"' EXIT

if [ -n "$RMCHAN_REF" ]; then
  [ -s "$RMCHAN_REF" ] || { echo "rmchan_diff: FAIL RMCHAN_REF $RMCHAN_REF missing or empty"; exit 2; }
  cp "$RMCHAN_REF" "$t/c.txt" || exit 2
else
  S=$OGKM_SRC
  if ! run cc -std=c11 -O1 -Wall -Werror \
      -I"$S/common/sdk/nvidia/inc" -I"$S/nvidia/arch/nvalloc/common/inc" -I"$S/common/uproc/os/common/include" \
      -I"$S/nvidia/inc/kernel" -I"$S/nvidia/inc" -I"$S/nvidia/generated" -I"$S/common/shared/msgq/inc" \
      -I"$S/nvidia/interface" -I"$S/common/inc" -o "$t/cref" "$here/tests/rmchan_ref.c"; then
    echo "rmchan_diff: FAIL C reference build"; exit 2
  fi
  run "$t/cref" > "$t/c.txt" || { echo "rmchan_diff: FAIL C reference run"; exit 2; }
fi

if ! cat "$here/gsp/rpc.om" "$here/gsp/replay.om" "$here/gsp/sysinfo.om" "$here/chan/params.om" "$here/gsp/boot.om" \
         "$here/chan/dma.om" "$here/chan/gmmu.om" "$here/chan/mem.om" "$here/chan/chan.om" \
         "$here/chan/sim.om" "$here/chan/complete.om" "$RMCHAN_OM" "$here/tests/rmchan_trace.om" \
         | run "$OMC" > "$t/omtrace"; then
  echo "rmchan_diff: FAIL omc build"; exit 3
fi
chmod +x "$t/omtrace"
run "$t/omtrace" > "$t/om.txt"
rc=$?
if [ "$rc" -ne 0 ]; then
  echo "rmchan_diff: FAIL om trace exit $rc"; exit 1
fi
n=$(wc -l < "$t/c.txt")
if [ "$n" -eq 0 ]; then
  echo "rmchan_diff: FAIL empty C trace"; exit 2
fi
if ! cmp -s "$t/c.txt" "$t/om.txt"; then
  echo "rmchan_diff: FAIL traces differ ($(diff "$t/c.txt" "$t/om.txt" | grep -c '^[<>]') differing lines; C $n lines, om $(wc -l < "$t/om.txt"))"
  exit 1
fi
echo "rmchan_diff: PASS ($n lines identical, .om vs C reference)"
