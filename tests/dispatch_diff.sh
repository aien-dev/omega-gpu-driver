#!/bin/sh
# tests/dispatch_diff.sh: builds the .om GSP sequencer dispatcher (gsp/dispatch.om)
# and the C referee (tests/dispatch_ref.c against gsp_seq.c and gsp_sim.c),
# runs every case in tests/dispatch_cases.txt through both, and requires
# byte-identical traces (rc, state, dead, why, delays, core calls, save[8], register log, violations).
# Host verification only. Never invokes VFIO, device opens, or kernel module actions.
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
AIENUX=${AIENUX:-/tmp/omega-driver-reference}
[ -d "$AIENUX/native/kernel" ] || AIENUX=/home/drakestapleton/work/OwnDriver/omega-driver-reference
OMC=${OMC:-$here/build/omc}
[ -f "$OMC" ] || OMC=/home/drakestapleton/work/OwnDriver/omega-mv-vfio/seed/out/omc
SEQ_OM=${SEQ_OM:-$here/gsp/seq.om}
RPC_OM=${RPC_OM:-$here/gsp/rpc.om}
BOOT_OM=${BOOT_OM:-$here/gsp/boot.om}
DISPATCH_OM=${DISPATCH_OM:-$here/gsp/dispatch.om}
OMC_PIN=$here/tools/omc.pin
[ -f "$OMC_PIN" ] || OMC_PIN=/home/drakestapleton/work/OwnDriver/omega-mv-vfio/tools/omc.pin
OMC_SHA=$(sed -n 's/^OMC_SHA256=//p' "$OMC_PIN" 2>/dev/null || echo "bcfa582892afca8f65e551fe56867d918d86e84540c7381be8fa9ef18d0cf0f6")
run() { nice -n 19 taskset -c 10-14 "$@"; }

got=$(sha256sum "$OMC" 2>/dev/null | cut -d' ' -f1)
if [ "$got" != "$OMC_SHA" ]; then
  echo "dispatch_diff: FAIL omc sha256 $got, pinned $OMC_SHA"; exit 2
fi

# Hard device-safety check: neither dispatch nor test harness may reference device paths or IOCTLs
if grep -n 'put gspmode [0-9]* [1-9]\|gspbar\|vfio\|mapnew\|/dev/\|/sys/' "$here/tests/dispatch_trace.om" "$DISPATCH_OM"; then
  echo "dispatch_diff: FAIL dispatch or test driver names a device"; exit 2
fi

t=$(mktemp -d /tmp/dispatch_diff.XXXXXX) || exit 2
trap 'rm -rf "$t"' EXIT

k=$AIENUX/native/kernel
if ! run cc -std=c11 -O1 -Wall -Werror -I"$k/gpu" -o "$t/ref" "$here/tests/dispatch_ref.c" "$k/gpu/gsp_seq.c" "$k/gpu/gsp_sim.c"; then
  echo "dispatch_diff: FAIL C referee build"; exit 2
fi

REPLAY_OM=""
if [ -f "$here/gsp/replay.om" ]; then
  REPLAY_OM="$here/gsp/replay.om"
fi

if ! cat "$here/gsp/mmio.om" "$here/gsp/sim.om" "$SEQ_OM" "$RPC_OM" $REPLAY_OM "$here/gsp/sysinfo.om" "$here/chan/params.om" "$BOOT_OM" "$DISPATCH_OM" "$here/tests/dispatch_trace.om" | run "$OMC" > "$t/om"; then
  echo "dispatch_diff: FAIL omc build"; exit 3
fi
chmod +x "$t/om"

fail=0
cases=$here/tests/dispatch_cases.txt

run "$t/ref" < "$cases" > "$t/c.cases"; echo "exit $?" >> "$t/c.cases"
run "$t/om" < "$cases" > "$t/o.cases"; echo "exit $?" >> "$t/o.cases"

if ! cmp -s "$t/c.cases" "$t/o.cases"; then
  echo "dispatch_diff: cases output differs (C left, .om right)"; diff -u "$t/c.cases" "$t/o.cases" | head -20; fail=1
fi

want=$(grep -vc '^#' "$cases")
n=$(grep -c '^== ' "$t/o.cases")
if [ "$n" -ne "$want" ] || [ "$(tail -n 1 "$t/o.cases")" != "exit 0" ]; then
  echo "dispatch_diff: ran $n of $want cases"; tail -n 1 "$t/o.cases"; fail=1
fi

# Verification of negative controls and behavioral constraints:
# 1. Zero writes on malformed late op (proves full prevalidation prevented any partial effects)
late_unk=$(grep '^== late-unkop ' "$t/o.cases")
case "$late_unk" in
  *"rc=-3"*"state=12"*"dead=1"*"nlog=0"*) ;;
  *) echo "dispatch_diff: FAIL late-unkop side-effect control: $late_unk"; fail=1 ;;
esac

late_badstore=$(grep '^== late-badstore ' "$t/o.cases")
case "$late_badstore" in
  *"rc=-6"*"state=12"*"dead=1"*"nlog=0"*) ;;
  *) echo "dispatch_diff: FAIL late-badstore side-effect control: $late_badstore"; fail=1 ;;
esac

# 2. Stale token / generation returns -10 without entering quarantine (state remains 11, dead=0)
stale_gen=$(grep '^== stale-gen ' "$t/o.cases")
case "$stale_gen" in
  *"rc=-10"*"state=11"*"dead=0"*"nlog=0"*) ;;
  *) echo "dispatch_diff: FAIL stale-gen state control: $stale_gen"; fail=1 ;;
esac

stale_tok=$(grep '^== stale-tok ' "$t/o.cases")
case "$stale_tok" in
  *"rc=-10"*"state=11"*"dead=0"*"nlog=0"*) ;;
  *) echo "dispatch_diff: FAIL stale-tok state control: $stale_tok"; fail=1 ;;
esac

# 3. Poll timeout enters quarantine
poll_fail=$(grep '^== poll-fail ' "$t/o.cases")
case "$poll_fail" in
  *"rc=-5"*"state=12"*"dead=1"*) ;;
  *) echo "dispatch_diff: FAIL poll-fail quarantine control: $poll_fail"; fail=1 ;;
esac

# 4. Core matrix: all 4 core opcodes refuse without callback or without permission
for op in 5 6 7 8; do
  nocall=$(grep "^== core${op}-nocall " "$t/o.cases")
  case "$nocall" in
    *"rc=-7"*"state=12"*"dead=1"*"core=0"*) ;;
    *) echo "dispatch_diff: FAIL core${op}-nocall refusal: $nocall"; fail=1 ;;
  esac
  noperm=$(grep "^== core${op}-noperm " "$t/o.cases")
  case "$noperm" in
    *"rc=-7"*"state=12"*"dead=1"*"core=0"*) ;;
    *) echo "dispatch_diff: FAIL core${op}-noperm refusal: $noperm"; fail=1 ;;
  esac
done

if [ "$fail" -eq 0 ]; then
  echo "dispatch_diff: PASS exact trace parity, full prevalidation with zero side effects, and strict quarantine controls; hardware NOT_RUN"
  sha256sum "$here/gsp/dispatch.om" "$cases" "$here/tests/dispatch_ref.c" "$here/tests/dispatch_trace.om"
  exit 0
else
  exit 1
fi
