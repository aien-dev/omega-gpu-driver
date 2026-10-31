#!/bin/sh
# mutants-mmio.sh: single-token (one is a two-line order swap) mutants of gsp/mmio.om; each must make
# tests/mmio_diff.sh go red. The simulator and the test driver are never mutated. A mutant must change
# exactly the named line(s) and still compile; otherwise it is INVALID and the run fails.
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
src=$here/gsp/mmio.om
diff_sh=$here/tests/mmio_diff.sh
t=$(mktemp -d /tmp/mutants-mmio.XXXXXX) || exit 2
trap 'rm -rf "$t"' EXIT

if ! sh "$diff_sh" > "$t/base.log" 2>&1; then
  cat "$t/base.log"; echo "mutants-mmio: FAIL baseline is not green"; exit 2
fi

# desc|old line|new line[|old line 2|new line 2]  (whole-line matches, each exactly once)
cat > "$t/list" <<'EOF'
QTAIL written after QHEAD (doorbell before tail)|gspwr S2QT sub mul dw 4 4|gspwr S2QH 0|gspwr S2QH 0|gspwr S2QT sub mul dw 4 4
EMEMC AINCW bit 23 instead of 24|const AINCW ulong 16777216|const AINCW ulong 8388608
emem dword formula 32 dwords per block|const DWBLK ulong 64|const DWBLK ulong 32
poll budget off by one (gt for ge)|if ge n b|if gt n b
lockdown high-half check shifts 31|if eq m1 shr pa 32|if eq m1 shr pa 31
CPUCTL active bit 6 instead of 7|const CPUACT ulong 128|const CPUACT ulong 64
notify writes 1 to QUEUE_HEAD|gspwr GQH 0|gspwr GQH 1
FALCON_OS gets fmc_args_pa, not app_version|gspwr GOS get gin 2|gspwr GOS get gin 1
mask timeout reports the lockdown code|ret gspfail EMASK|ret gspfail ELOCK
tail not zero-padded (one byte past len)|while lt add i k ln bound 4|while le add i k ln bound 4
target-lock mask covers the low byte|const PRIVMSK ulong 4294967040|const PRIVMSK ulong 4294967295
lockdown bit 12 instead of 13|const LOCKDN ulong 8192|const LOCKDN ulong 4096
dword count rounds down|dw = div add ln 3 4|dw = div add ln 0 4
QUEUE_TAIL = padded size, not size - 4|gspwr S2QT sub mul dw 4 4|gspwr S2QT sub mul dw 4 0
SEC2 busy value off by one|const CMDBUSY ulong 3221342974|const CMDBUSY ulong 3221342975
FMC error reported as OK|ret gspfail EFMC|ret gspfail EOK
step 8 waits for MAILBOX0 zero|ret or eq and h LOCKDN 0 ne m0 0|ret or eq and h LOCKDN 0 eq m0 0
EMEM pointer check inverted|if ne and sub ememdw ea st M32 dw|if eq and sub ememdw ea st M32 dw
channel bound refuses exactly 1024 bytes|if or eq ln 0 gt ln CHBYTES|if or eq ln 0 ge ln CHBYTES
step 1 waits for HEAD != TAIL|ret eq hd gsprd S2QT|ret ne hd gsprd S2QT
SEC2 timeout reads MAILBOX0 for MAILBOX1|put gout 7 gsprd S2MB1|put gout 7 gsprd S2MB0
HWCFG2 zero counts as released|if eq h 0|if eq h 1
EOF

killed=0; survived=0; invalid=0
while IFS='|' read -r desc o1 n1 o2 n2; do
  m=$t/mmio.om
  awk -v o1="$o1" -v n1="$n1" -v o2="${o2:-}" -v n2="${n2:-}" '
    $0 == o1 && !d1 { print n1; c1++; d1 = 1; next }
    o2 != "" && $0 == o2 && !d2 { print n2; c2++; d2 = 1; next }
    $0 == o1 { c1++ } o2 != "" && $0 == o2 { c2++ }
    { print }
    END { if (c1 != 1 || (o2 != "" && c2 != 1)) exit 1 }' "$src" > "$m"
  if [ $? -ne 0 ] || cmp -s "$src" "$m"; then
    echo "mutant INVALID (pattern not matched exactly once): $desc"; invalid=$((invalid + 1)); continue
  fi
  MMIO_OM=$m sh "$diff_sh" > "$t/m.log" 2>&1
  rc=$?
  case $rc in
    0) echo "mutant SURVIVED: $desc"; survived=$((survived + 1)) ;;
    1) echo "mutant killed: $desc"; killed=$((killed + 1)) ;;
    *) echo "mutant INVALID (exit $rc: $(cat "$t/m.log")): $desc"; invalid=$((invalid + 1)) ;;
  esac
done < "$t/list"
echo "mutants-mmio: $killed killed, $survived survived, $invalid invalid"
[ "$survived" -eq 0 ] && [ "$invalid" -eq 0 ] && [ "$killed" -ge 10 ]
