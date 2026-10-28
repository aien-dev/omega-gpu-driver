#!/bin/sh
# tests/dispatch_mutants.sh: behavioral mutation testing of gsp/dispatch.om.
# Single-line mutants targeting each security, prevalidation, and state transition contract.
# Every mutant must compile and be killed (detected) by tests/dispatch_diff.sh.
# Host verification only. Never invokes VFIO or device operations.
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
src=$here/gsp/dispatch.om
diff_sh=$here/tests/dispatch_diff.sh
t=$(mktemp -d /tmp/mutants-dispatch.XXXXXX) || exit 2
trap 'rm -rf "$t"' EXIT

cat > "$t/list" <<'EOF'
prevalidation bypassed|r = dspprev nw ci|r = 0
stale generation check disabled|if ne gen get bgen 0|if false
stale token check disabled|if ne tok get btoken 0|if false
suspended state check disabled|if ne get bstate 0 11|if false
packet truncation check disabled|if lt get bselen 0 add 120 mul nw 4|if false
buffer capacity check disabled|if gt nw SQMAX|if false
cmdIndex bound check disabled|if ge ci nw|if false
core permission check disabled in prevalidation|if not dspcperm op|if false
store save index check disabled in prevalidation|if ge k SQSAVE|if false
bseqdone ok=false on success|d = bseqdone gen tok true|d = bseqdone gen tok false
save register writeback dropped|dspp32 add 88 mul k 4 get sqsave k|note no writeback
poll budget check disabled in prevalidation|if gt get sqbud 0 SQBMAX|if false
non-sim whole-dispatch refusal disabled|if ne get gspmode 0 0|if false
EOF

killed=0
survived=0
invalid=0

while IFS='|' read -r desc old new; do
  [ -z "$desc" ] && continue
  m="$t/mutant.om"
  awk -v o="$old" -v n="$new" '
    $0 == o { c++; print n; next }
    { print }
    END { if (c != 1) exit 1 }' "$src" > "$m"
  if [ $? -ne 0 ] || cmp -s "$src" "$m"; then
    echo "mutant INVALID (pattern not matched exactly once): $desc"; invalid=$((invalid + 1)); continue
  fi
  DISPATCH_OM=$m sh "$diff_sh" > "$t/m.log" 2>&1
  rc=$?
  case $rc in
    0) echo "mutant SURVIVED: $desc"; survived=$((survived + 1)) ;;
    1) echo "mutant killed: $desc"; killed=$((killed + 1)) ;;
    *) echo "mutant INVALID (exit $rc: $(cat "$t/m.log")): $desc"; invalid=$((invalid + 1)) ;;
  esac
done < "$t/list"

echo "mutants-dispatch: $killed killed, $survived survived, $invalid invalid"
[ "$survived" -eq 0 ] && [ "$invalid" -eq 0 ] && [ "$killed" -ge 10 ]
