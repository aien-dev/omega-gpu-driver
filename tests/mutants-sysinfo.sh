#!/bin/sh
# mutants-sysinfo.sh: single-line mutants of gsp/sysinfo.om; each must make tests/sysinfo_diff.sh go red.
# The test driver and the C reference are never mutated. A mutant must change exactly the named line and still
# compile; otherwise it is INVALID and the run fails.
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
src=$here/gsp/sysinfo.om
diff_sh=$here/tests/sysinfo_diff.sh
t=$(mktemp -d /tmp/mutants-sysinfo.XXXXXX) || exit 2
trap 'rm -rf "$t"' EXIT

if ! sh "$diff_sh" > "$t/base.log" 2>&1; then
  cat "$t/base.log"; echo "mutants-sysinfo: FAIL baseline is not green"; exit 2
fi

# desc|old line|new line[|old line 2|new line 2]  (whole-line matches, each exactly once)
cat > "$t/list" <<'EOF'
oorArch offset 104 -> 105|put sioff 16 104|put sioff 16 105
capsMethodData.status offset 828 -> 832|put sioff 44 828|put sioff 44 832
FHBBusInfo.revisionID size 1 -> 2|put sisz 34 1|put sisz 34 2
fit check shifts 7 bits per byte|ret eq shr v mul sz 8 0|ret eq shr v mul sz 7 0
fit check skips 4-byte fields|if lt sz 8|if lt sz 4
three tokens accepted (k != 2 check dropped)|if ne get sipos 0 b|if gt get sipos 0 b
0X prefix not taken as hex|if or eq x 120 eq x 88|if eq x 120
leading 0 read as decimal, not octal|base = 8|base = 10
bytes not little endian (7-bit shift)|put siout add o b uchar and shr v mul b 8 255|put siout add o b uchar and shr v mul b 7 255
line limit 512 -> 513|const SILINE ulong 512|const SILINE ulong 513
comment cut on $ not #|if eq get sitxt h 35|if eq get sitxt h 36
overflow test ignores the digit|if gt v div sub SIMAX64 d base|if gt v div SIMAX64 base
text not cut at NUL|if eq get sitxt i 0|if eq get sitxt i 1
name lookup matches prefixes|if eq sub i s n|if ge sub i s n
token width 127 -> 128|while and lt p b lt n 127 bound 600|while and lt p b lt n 128 bound 600
does-not-fit value shown to 41 chars|siwval 40|siwval 41
lower-case hex digit value off by one|ret sub ulong c 87|ret sub ulong c 86
leading + not skipped|if eq get sivb 0 43|if eq get sivb 0 44
CR (13) not whitespace|ret or eq c 32 and ge c 9 le c 13|ret or eq c 32 and ge c 9 le c 12
text limit refuses exactly 65536 bytes|if gt n SITXMAX|if ge n SITXMAX
EOF

killed=0; survived=0; invalid=0
while IFS='|' read -r desc o1 n1 o2 n2; do
  m=$t/sysinfo.om
  awk -v o1="$o1" -v n1="$n1" -v o2="${o2:-}" -v n2="${n2:-}" '
    $0 == o1 && !d1 { print n1; c1++; d1 = 1; next }
    o2 != "" && $0 == o2 && !d2 { print n2; c2++; d2 = 1; next }
    $0 == o1 { c1++ } o2 != "" && $0 == o2 { c2++ }
    { print }
    END { if (c1 != 1 || (o2 != "" && c2 != 1)) exit 1 }' "$src" > "$m"
  if [ $? -ne 0 ] || cmp -s "$src" "$m"; then
    echo "mutant INVALID (pattern not matched exactly once): $desc"; invalid=$((invalid + 1)); continue
  fi
  SYSINFO_OM=$m sh "$diff_sh" > "$t/m.log" 2>&1
  rc=$?
  case $rc in
    0) echo "mutant SURVIVED: $desc"; survived=$((survived + 1)) ;;
    1) echo "mutant killed: $desc"; killed=$((killed + 1)) ;;
    *) echo "mutant INVALID (exit $rc: $(cat "$t/m.log")): $desc"; invalid=$((invalid + 1)) ;;
  esac
done < "$t/list"
echo "mutants-sysinfo: $killed killed, $survived survived, $invalid invalid"
[ "$survived" -eq 0 ] && [ "$invalid" -eq 0 ] && [ "$killed" -ge 10 ]
