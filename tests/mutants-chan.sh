#!/bin/sh
# mutants-chan.sh: single-line mutants of the channel port (chan/gmmu.om, chan/mem.om, chan/chan.om;
# each must turn tests/chan_diff.sh red) and of chan/params.om (each must turn tests/params_diff.sh
# red). The simulator chan/sim.om and the test drivers are never mutated. A mutant must change exactly
# the named line(s) and still compile; otherwise it is INVALID and the run fails. Also runs the two
# negative controls of the comparison itself: a C trace with one corrupted byte must fail chan_diff.
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
t=$(mktemp -d /tmp/mutants-chan.XXXXXX) || exit 2
trap 'rm -rf "$t"' EXIT
k=${AIENUX:-/home/drakestapleton/work/OwnDriver/aienux}/native/kernel
run() { nice -n 19 taskset -c 10-14 "$@"; }

if ! sh "$here/tests/chan_diff.sh" > "$t/base.log" 2>&1; then
  cat "$t/base.log"; echo "mutants-chan: FAIL chan baseline is not green"; exit 2
fi
if ! sh "$here/tests/params_diff.sh" > "$t/pbase.log" 2>&1; then
  cat "$t/pbase.log"; echo "mutants-chan: FAIL params baseline is not green"; exit 2
fi
# the C channel trace, built once and handed to every mutant run (CHAN_REF)
if ! run cc -std=c11 -O1 -Wall -Werror -I"$k/gpu" -o "$t/ctrace" \
    "$k/tests/gpu_chan_trace.c" "$k/gpu/gmmu.c" "$k/gpu/gpu_mem.c" "$k/gpu/gpu_chan.c" "$k/gpu/gpu_sim.c"; then
  echo "mutants-chan: FAIL C reference build"; exit 2
fi
run "$t/ctrace" > "$t/cref.txt" || { echo "mutants-chan: FAIL C reference run"; exit 2; }
# negative control: one corrupted byte in the reference must make chan_diff exit 1
sed '1s/rc=0/rc=1/' "$t/cref.txt" > "$t/cbad.txt"
CHAN_REF=$t/cbad.txt sh "$here/tests/chan_diff.sh" > "$t/neg.log" 2>&1
rc=$?
if [ "$rc" -ne 1 ]; then
  cat "$t/neg.log"; echo "mutants-chan: FAIL negative control (corrupted C trace) exit $rc, want 1"; exit 2
fi
echo "negative control refused: corrupted C trace -> chan_diff exit 1"

# unit|desc|old line|new line[|old line 2|new line 2]  (whole-line matches, each exactly once)
cat > "$t/list" <<'EOF'
gmmu|PTE aperture at bit 2 instead of 1|v = or 1 shl and ap 3 1|v = or 1 shl and ap 3 2
gmmu|PTE PCF at bit 4 instead of 3|v = or v shl and pcf 31 3|v = or v shl and pcf 31 4
gmmu|PDE PCF 0 instead of 2|const MMPDEPCF ulong 2|const MMPDEPCF ulong 0
gmmu|invalidate drops ALL_VA|mmregwr MMRINV or MMALLVA MMTRIG|mmregwr MMRINV MMTRIG
gmmu|PDB register address shifted 8 not 4|mmregwr MMRPDB or shl and pdb 268435455 4 MMPDBAP|mmregwr MMRPDB or shl and pdb 268435455 8 MMPDBAP
chan|work-submit token runlist at bit 17|ret or shl and rl CHRLINV 16 and chid CHIDMAX|ret or shl and rl CHRLINV 17 and chid CHIDMAX
chan|GP_PUT at USERD 0x88 instead of 0x8c|const CHGPPUT ulong 140|const CHGPPUT ulong 136
chan|doorbell register one word up|const CHDBELL ulong 12255376|const CHDBELL ulong 12255380
chan|GP entry length at bit 43|ret or or and va CHVAM shl and ulong n 2097151 42 CHGPB41|ret or or and va CHVAM shl and ulong n 2097151 43 CHGPB41
chan|ring full one slot late|if ge sub p get chret c sub e 1|if gt sub p get chret c sub e 1
chan|retire refuses upto == put|if le sub upto r sub get chput c r|if lt sub upto r sub get chput c r
chan|chid max 4096|const CHIDMAX uint 4095|const CHIDMAX uint 4096
chan|RAMIN big-page 64K bit dropped|const CHBIG64 uint 2048|const CHBIG64 uint 0
chan|RAMIN PDB high word shift 31|mmwr32 add ip add CHPDBW 4 shr pdb 32|mmwr32 add ip add CHPDBW 4 shr pdb 31
chan|hung teardown skips the extra buffers|if gmlive b|if not gmlive b
mem|uncached GPU-RO PCF 5 becomes 4|ret 5|ret 4
params|channel record 360 bytes|const PASZCHAN ulong 368|const PASZCHAN ulong 360
params|subDeviceId written at cid (132)|paput32 136 get pain 9|paput32 132 get pain 9
params|USERD index bits not cleared|const PAFLMSK ulong 4290773247|const PAFLMSK ulong 4294967295
params|USERD_INDEX_PAGE_FIXED not set|const PAPGFIX ulong 2097152|const PAPGFIX ulong 0
params|internalFlags error/ECC notifier fields swapped|paput32 244 or or get pain 14 shl get pain 12 2 shl get pain 13 4|paput32 244 or or get pain 14 shl get pain 12 4 shl get pain 13 2
params|SM_VERSION read from the index word|const PASMOFF ulong 100|const PASMOFF ulong 96
params|chid 4096 accepted|if gt chid PACHMAX|if gt chid 4096
params|VA space record 48 bytes|const PASZVAS ulong 56|const PASZVAS ulong 48
params|vaBase written as 32 bits|paput64 40 vabase|paput32 40 vabase
params|PRESERVE_PDES at bit 3|paput32 28 or get pain 5 shl get pain 6 2|paput32 28 or get pain 5 shl get pain 6 3
params|BLACKWELL_CHANNEL_GPFIFO_A off by one|const PACGPF ulong 51567|const PACGPF ulong 51566
params|short GR reply accepted|if ne n PAGRSZ|if gt n PAGRSZ
params|eccErrorNotifierMem size treated as NvU32|ret or eq k 38 eq k 39|ret eq k 38
EOF

killed=0; survived=0; invalid=0; nchan=0; npar=0
while IFS='|' read -r unit desc o1 n1 o2 n2; do
  case $unit in
    gmmu) src=$here/chan/gmmu.om; var=GMMU_OM; diff_sh=$here/tests/chan_diff.sh ;;
    mem) src=$here/chan/mem.om; var=MEM_OM; diff_sh=$here/tests/chan_diff.sh ;;
    chan) src=$here/chan/chan.om; var=CHAN_OM; diff_sh=$here/tests/chan_diff.sh ;;
    params) src=$here/chan/params.om; var=PARAMS_OM; diff_sh=$here/tests/params_diff.sh ;;
    *) echo "mutant INVALID (unknown unit $unit): $desc"; invalid=$((invalid + 1)); continue ;;
  esac
  m=$t/$unit.om
  awk -v o1="$o1" -v n1="$n1" -v o2="${o2:-}" -v n2="${n2:-}" '
    $0 == o1 && !d1 { print n1; c1++; d1 = 1; next }
    o2 != "" && $0 == o2 && !d2 { print n2; c2++; d2 = 1; next }
    $0 == o1 { c1++ } o2 != "" && $0 == o2 { c2++ }
    { print }
    END { if (c1 != 1 || (o2 != "" && c2 != 1)) exit 1 }' "$src" > "$m"
  if [ $? -ne 0 ] || cmp -s "$src" "$m"; then
    echo "mutant INVALID (pattern not matched exactly once): $unit: $desc"; invalid=$((invalid + 1)); continue
  fi
  env "$var=$m" CHAN_REF="$t/cref.txt" sh "$diff_sh" > "$t/m.log" 2>&1
  rc=$?
  case $rc in
    0) echo "mutant SURVIVED: $unit: $desc"; survived=$((survived + 1)) ;;
    1) echo "mutant killed: $unit: $desc"; killed=$((killed + 1))
       if [ "$unit" = params ]; then npar=$((npar + 1)); else nchan=$((nchan + 1)); fi ;;
    *) echo "mutant INVALID (exit $rc: $(cat "$t/m.log")): $unit: $desc"; invalid=$((invalid + 1)) ;;
  esac
done < "$t/list"
echo "mutants-chan: $killed killed ($nchan channel, $npar params), $survived survived, $invalid invalid"
[ "$survived" -eq 0 ] && [ "$invalid" -eq 0 ] && [ "$nchan" -ge 12 ] && [ "$npar" -ge 8 ]
