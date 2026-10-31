#!/bin/sh
# mutants-seq.sh: single-line mutants of gsp/seq.om; each must make tests/seq_diff.sh go red.
# The test driver and the C reference are never mutated. A mutant must change exactly the named line and still
# compile; otherwise it is INVALID and the run fails.
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
src=$here/gsp/seq.om
diff_sh=$here/tests/seq_diff.sh
t=$(mktemp -d /tmp/mutants-seq.XXXXXX) || exit 2
trap 'rm -rf "$t"' EXIT

if ! sh "$diff_sh" > "$t/base.log" 2>&1; then
  cat "$t/base.log"; echo "mutants-seq: FAIL baseline is not green"; exit 2
fi

# desc|old line|new line[|old line 2|new line 2]  (whole-line matches, each exactly once)
cat > "$t/list" <<'EOF'
WRITE opcode 0 -> 9|const SQWR ulong 0|const SQWR ulong 9
MODIFY opcode 1 -> 10|const SQMOD ulong 1|const SQMOD ulong 10
POLL opcode 2 -> 11|const SQPOLL ulong 2|const SQPOLL ulong 11
DELAY opcode 3 -> 12|const SQDLY ulong 3|const SQDLY ulong 12
STORE opcode 4 -> 13|const SQSTO ulong 4|const SQSTO ulong 13
core opcodes start at 6, not 5|const SQCRST ulong 5|const SQCRST ulong 6
core opcodes end at 7, not 8|const SQCRES ulong 8|const SQCRES ulong 7
WRITE/STORE payload 2 -> 3|ret 2|ret 3
MODIFY payload 3 -> 2|ret 3|ret 2
POLL payload 5 -> 4|ret 5|ret 4
DELAY payload 1 -> 2|ret 1|ret 2
poll ignores the mask|while ne and v a1 a2 bound 999999|while ne v a2 bound 999999
poll compares with <, not ==|while ne and v a1 a2 bound 999999|while lt and v a1 a2 bound 999999
poll budget 0 gives 2 extra reads, not 1|left = 1|left = 2
poll spends 2 per retry|left = sub left 1|left = sub left 2
poll budget cap 999998 -> 999997|const SQBMAX ulong 999998|const SQBMAX ulong 999997
delay microseconds not summed|put sqdly 1 add get sqdly 1 us|put sqdly 1 us
delay calls not counted|put sqdly 0 add get sqdly 0 1|put sqdly 0 1
overrun check > -> >=|if gt add i n ci|if ge add i n ci
cmdIndex check >= -> >|if ge ci nw|if gt ci nw
empty buffer not refused|if eq nw 0|if lt nw 0
save index 8 accepted|if ge k SQSAVE|if gt k SQSAVE
save index read from the address dword|k = sqw add i 1|k = sqw i
MODIFY keeps masked bits (~mask dropped)|gspwr a or and v xor sqw add i 1 M32 sqw add i 2|gspwr a or and v sqw add i 1 sqw add i 2
MODIFY ignores the value dword|gspwr a or and v xor sqw add i 1 M32 sqw add i 2|gspwr a and v xor sqw add i 1 M32
WRITE writes the address as value|gspwr sqw i sqw add i 1|gspwr sqw i sqw i
core opcode runs with no callback|if eq get sqcore 0 0|if eq get sqcore 0 2
core failure (-1) not refused|if ne c 0|if gt c 0
walk steps 2, not the payload|i = add i n|i = add i 2
nwords cap 16384 -> 16383|const SQMAX ulong 16384|const SQMAX ulong 16383
why text off by one|k = ulong sub 0 add e 1|k = ulong sub 0 e
EOF

killed=0; survived=0; invalid=0
while IFS='|' read -r desc o1 n1 o2 n2; do
  m=$t/seq.om
  awk -v o1="$o1" -v n1="$n1" -v o2="${o2:-}" -v n2="${n2:-}" '
    $0 == o1 && !d1 { print n1; c1++; d1 = 1; next }
    o2 != "" && $0 == o2 && !d2 { print n2; c2++; d2 = 1; next }
    $0 == o1 { c1++ } o2 != "" && $0 == o2 { c2++ }
    { print }
    END { if (c1 != 1 || (o2 != "" && c2 != 1)) exit 1 }' "$src" > "$m"
  if [ $? -ne 0 ] || cmp -s "$src" "$m"; then
    echo "mutant INVALID (pattern not matched exactly once): $desc"; invalid=$((invalid + 1)); continue
  fi
  SEQ_OM=$m sh "$diff_sh" > "$t/m.log" 2>&1
  rc=$?
  case $rc in
    0) echo "mutant SURVIVED: $desc"; survived=$((survived + 1)) ;;
    1) echo "mutant killed: $desc"; killed=$((killed + 1)) ;;
    *) echo "mutant INVALID (exit $rc: $(cat "$t/m.log")): $desc"; invalid=$((invalid + 1)) ;;
  esac
done < "$t/list"
echo "mutants-seq: $killed killed, $survived survived, $invalid invalid"
[ "$survived" -eq 0 ] && [ "$invalid" -eq 0 ] && [ "$killed" -ge 10 ]
