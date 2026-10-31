#!/bin/sh
# params_diff.sh: builds the .om params dump (chan/params.om + tests/params_dump.om) and the C referee
# tests/params_ref.c (TEST-ONLY, compiled fresh into a temp dir against the NVIDIA open-gpu-kernel-modules
# 580.173.02 headers) and requires byte-identical stdout: every record's bytes, every record size
# against NVIDIA's sizeof, the refused cases and the exported constants. Host only.
# Env: OMC (pinned omc), PARAMS_OM (unit to test; mutants use it), OGKM_SRC (NVIDIA src/ tree),
# PARAMS_REF (referee output already produced by this script, so a mutant run skips the rebuild).
# Exit: 0 PASS, 1 outputs differ, 2 setup, 3 omc failure.
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
OMC=${OMC:-$here/build/omc}
PARAMS_OM=${PARAMS_OM:-$here/chan/params.om}
OGKM_SRC=${OGKM_SRC:-/home/drakestapleton/workspace/_ext/open-gpu-kernel-modules-580.173.02/src}
PARAMS_REF=${PARAMS_REF:-}
OMC_SHA=$(sed -n 's/^OMC_SHA256=//p' "$here/tools/omc.pin")
run() { nice -n 19 taskset -c 10-14 "$@"; }

got=$(sha256sum "$OMC" | cut -d' ' -f1)
if [ "$got" != "$OMC_SHA" ]; then
  echo "params_diff: FAIL omc sha256 $got, pinned $OMC_SHA"; exit 2
fi
if grep -n 'vfio\|mapnew\|/dev/\|/sys/' "$PARAMS_OM" "$here/tests/params_dump.om"; then
  echo "params_diff: FAIL params unit or dump names a device"; exit 2
fi

t=$(mktemp -d /tmp/params_diff.XXXXXX) || exit 2
trap 'rm -rf "$t"' EXIT
if [ -n "$PARAMS_REF" ]; then
  [ -s "$PARAMS_REF" ] || { echo "params_diff: FAIL PARAMS_REF $PARAMS_REF missing or empty"; exit 2; }
  cp "$PARAMS_REF" "$t/c.txt" || exit 2
else
  S=$OGKM_SRC
  if ! run cc -std=c11 -O1 -Wall -Werror \
      -I"$S/common/sdk/nvidia/inc" -I"$S/nvidia/arch/nvalloc/common/inc" -I"$S/common/uproc/os/common/include" \
      -I"$S/nvidia/inc/kernel" -I"$S/nvidia/inc" -I"$S/nvidia/generated" -I"$S/common/shared/msgq/inc" \
      -I"$S/nvidia/interface" -I"$S/common/inc" -o "$t/pref" "$here/tests/params_ref.c"; then
    echo "params_diff: FAIL C referee build"; exit 2
  fi
  run "$t/pref" > "$t/c.txt" || { echo "params_diff: FAIL C referee run"; exit 2; }
fi
if ! cat "$PARAMS_OM" "$here/tests/params_dump.om" | run "$OMC" > "$t/pd"; then
  echo "params_diff: FAIL omc build"; exit 3
fi
chmod +x "$t/pd"
run "$t/pd" > "$t/om.txt"
rc=$?
if [ "$rc" -ne 0 ]; then
  echo "params_diff: FAIL om dump exit $rc"; exit 1
fi
n=$(wc -l < "$t/c.txt")
if [ "$n" -eq 0 ]; then
  echo "params_diff: FAIL empty C output"; exit 2
fi
if ! cmp -s "$t/c.txt" "$t/om.txt"; then
  echo "params_diff: FAIL outputs differ ($(diff "$t/c.txt" "$t/om.txt" | grep -c '^[<>]') differing lines; C $n lines, om $(wc -l < "$t/om.txt"))"
  exit 1
fi
# negative control: the comparison must see a single corrupted byte (first record byte 01 -> 00)
sed '2s/^01/00/' "$t/om.txt" > "$t/bad.txt"
if cmp -s "$t/c.txt" "$t/bad.txt"; then
  echo "params_diff: FAIL negative control: a corrupted byte was not detected"; exit 2
fi
echo "params_diff: PASS ($n lines identical, .om vs C referee; corrupted-byte control refused)"
