#!/bin/sh
# seq_diff.sh: builds the .om GSP CPU sequencer (gsp/seq.om, run by tests/seq_trace.om on gsp/sim.om in mode 0) and
# the C reference (aienux PR #441 native/kernel/gpu/gsp_seq.c + gsp_sim.c, driven by tests/seq_ref.c, compiled fresh
# into a temp dir as a test-only referee), runs every case of tests/seq_cases.txt through both and requires
# byte-identical traces (rc, why, delays, core calls, save[8], register log, violations) and the same exit code.
# Also: malformed case input stops both the same way; a corrupted buffer is refused; the .om-only refusals
# (nwords cap, poll budget cap) match fixed expected lines. Host only: no device is opened.
# Env: AIENUX (aienux checkout), OMC (pinned omc), SEQ_OM (library file to test; mutants use this).
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
AIENUX=${AIENUX:-/home/drakestapleton/work/OwnDriver/aienux}
OMC=${OMC:-$here/build/omc}
SEQ_OM=${SEQ_OM:-$here/gsp/seq.om}
OMC_SHA=$(sed -n 's/^OMC_SHA256=//p' "$here/tools/omc.pin")
run() { nice -n 19 taskset -c 10-14 "$@"; }

got=$(sha256sum "$OMC" | cut -d' ' -f1)
if [ "$got" != "$OMC_SHA" ]; then
  echo "seq_diff: FAIL omc sha256 $got, pinned $OMC_SHA"; exit 2
fi
if grep -n 'put gspmode [0-9]* [1-9]\|gspbar\|vfio\|mapnew\|/dev/\|/sys/' "$here/tests/seq_trace.om" "$SEQ_OM"; then
  echo "seq_diff: FAIL sequencer or test driver names a device"; exit 2
fi

t=$(mktemp -d /tmp/seq_diff.XXXXXX) || exit 2
trap 'rm -rf "$t"' EXIT
k=$AIENUX/native/kernel
if ! run cc -std=c11 -O1 -Wall -Werror -I"$k/gpu" -o "$t/ref" "$here/tests/seq_ref.c" "$k/gpu/gsp_seq.c" "$k/gpu/gsp_sim.c"; then
  echo "seq_diff: FAIL C reference build"; exit 2
fi
if ! cat "$here/gsp/mmio.om" "$here/gsp/sim.om" "$SEQ_OM" "$here/tests/seq_trace.om" | run "$OMC" > "$t/om"; then
  echo "seq_diff: FAIL omc build"; exit 3
fi
chmod +x "$t/om"

fail=0
# both tools on one input: stdout then the exit code
both() {  # infile tag
  run "$t/ref" < "$1" > "$t/c.$2"; echo "exit $?" >> "$t/c.$2"
  run "$t/om" < "$1" > "$t/o.$2"; echo "exit $?" >> "$t/o.$2"
  if ! cmp -s "$t/c.$2" "$t/o.$2"; then
    echo "seq_diff: $2 differs (C left, .om right)"; diff "$t/c.$2" "$t/o.$2" | head -12; fail=1
  fi
}
cases=$here/tests/seq_cases.txt
both "$cases" cases
want=$(grep -vc '^#' "$cases")
n=$(grep -c '^== ' "$t/o.cases")
if [ "$n" -ne "$want" ] || [ "$(tail -n 1 "$t/o.cases")" != "exit 0" ]; then
  echo "seq_diff: ran $n of $want cases"; tail -n 1 "$t/o.cases"; fail=1
fi
# every refusal the C has must be among the cases
for w in 'empty buffer' 'cmdIndex not inside the buffer' 'unknown opcode' 'opcode overruns cmdIndex' 'poll timed out' \
         'save index out of range' 'core opcode with no core callback' 'core opcode failed'; do
  if ! grep -q " rc=-1 why=$w " "$t/o.cases"; then echo "seq_diff: no case refuses with '$w'"; fail=1; fi
done
# malformed case input: both stop with exit 2 after the same output
printf 'write 0 4 0 0 4 3 3 0 8653504 2748\nbad 0 4 x\n' > "$t/bad1"
printf 'write 0 4 0 0 4 3 3 0 8653504 2748\nshort 0 4 0 0 4 3 3 0 8653504\n' > "$t/bad2"
printf 'big 0 4 0 0 4 3 3 0 8653504 4294967296\n' > "$t/bad3"
for b in bad1 bad2 bad3; do
  both "$t/$b" "$b"
  if [ "$(tail -n 1 "$t/o.$b")" != "exit 2" ]; then echo "seq_diff: $b not refused"; fail=1; fi
done
# negative control: the modify case with its opcode corrupted (1 -> 9) is refused by both, nothing written after it
grep '^modify ' "$cases" | sed 's/ 255 1 8653504 / 255 9 8653504 /' > "$t/corrupt"
both "$t/corrupt" corrupt
if ! grep -qx '== modify rc=-1 why=unknown opcode delays=0/0 core=0 ops= save=0,0,0,0,0,0,0,0, nlog=1 violations=0' "$t/o.corrupt"; then
  echo "seq_diff: negative control not refused"; cat "$t/o.corrupt"; fail=1
fi
# the comparison itself can go red: a changed modify mask (10 -> 255) on the C side must not match the .om trace
grep '^modify ' "$cases" > "$t/m.ok"
sed 's/ 8653504 10 5$/ 8653504 255 5/' "$t/m.ok" > "$t/m.bad"
run "$t/ref" < "$t/m.bad" > "$t/c.mbad"
run "$t/om" < "$t/m.ok" > "$t/o.mok"
if ! grep -q '^modify .* 255 5$' "$t/m.bad" || cmp -s "$t/c.mbad" "$t/o.mok"; then echo "seq_diff: changed mask not detected"; fail=1; fi
# .om-only refusals (the C has no such limits); cmdIndex is still checked first, as in the C
cat > "$t/only" <<'EOF'
cap 0 4 0 0 16385 0 0
capidx 0 4 0 0 16385 16385 0
bigbud 0 999999 0 0 2 1 1 3
EOF
run "$t/om" < "$t/only" > "$t/only.got"
cat > "$t/only.want" <<'EOF'
== cap rc=-1 why=nwords over 16384 delays=0/0 core=0 ops= save=0,0,0,0,0,0,0,0, nlog=0 violations=0
== capidx rc=-1 why=cmdIndex not inside the buffer delays=0/0 core=0 ops= save=0,0,0,0,0,0,0,0, nlog=0 violations=0
== bigbud rc=-1 why=poll budget over 999998 delays=0/0 core=0 ops= save=0,0,0,0,0,0,0,0, nlog=0 violations=0
EOF
if ! cmp -s "$t/only.want" "$t/only.got"; then
  echo "seq_diff: .om-only refusals differ"; diff "$t/only.want" "$t/only.got"; fail=1
fi
if [ "$fail" -ne 0 ]; then
  echo "seq_diff: FAIL"; exit 1
fi
echo "seq_diff: PASS ($n cases identical trace+exit, 8 C refusals covered, 3 malformed inputs stop alike, negative control refused, changed mask detected, 3 .om-only refusals; .om vs C reference)"
