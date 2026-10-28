#!/bin/sh
# tests/mutants-complete.sh: single-line mutants of chan/complete.om.
# Each mutant must compile and fail tests/complete_diff.sh (killed).
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
t=$(mktemp -d /tmp/mutants-complete.XXXXXX) || exit 2
trap 'rm -rf "$t"' EXIT
run() { nice -n 19 taskset -c 10-14 "$@"; }

if ! sh "$here/tests/complete_diff.sh" > "$t/base.log" 2>&1; then
  cat "$t/base.log"; echo "mutants-complete: FAIL baseline is not green"; exit 2
fi

cat <<'EOF' > "$t/list"
header method offset mutated|const CMSEMM uint 23|const CMSEMM uint 24
release execute operation mutated to acquire|put cmwds 5 1|put cmwds 5 0
address alignment check bypassed|if ne and va 3 0|if false
progress check operator flipped|if gt prog inflight|if ge prog inflight
stale observation accepted as pending|ret CMESTALE|ret 0
capability check for DMA window bypassed|if or lt get mmwst 0 MMWDMA ge get mmwst 0 MMWQUAR|if false
quarantine on timeout skipped|r = gmquar b|r = GMOK
cmsub overcapacity check bypassed|if gt count sub sub ent 1 inflight|if false
EOF

killed=0; survived=0; invalid=0; total=0
while IFS='|' read -r desc orig mut; do
  total=$((total + 1))
  mfile="$t/mut_$total.om"
  if ! grep -qF "$orig" "$here/chan/complete.om"; then
    echo "mutants-complete: INVALID pattern '$orig'"; invalid=$((invalid + 1)); continue
  fi
  sed "s/$orig/$mut/" "$here/chan/complete.om" > "$mfile"
  if cmp -s "$mfile" "$here/chan/complete.om"; then
    echo "mutants-complete: INVALID identical mutation '$desc'"; invalid=$((invalid + 1)); continue
  fi
  if COMPLETE_OM="$mfile" sh "$here/tests/complete_diff.sh" > "$t/run.log" 2>&1; then
    echo "mutants-complete: SURVIVED mutant '$desc'"; survived=$((survived + 1))
  else
    rc=$?
    if [ "$rc" -eq 1 ]; then
      echo "mutants-complete: KILLED mutant '$desc'"
      killed=$((killed + 1))
    else
      echo "mutants-complete: INVALID mutant '$desc' exit $rc"
      cat "$t/run.log"
      invalid=$((invalid + 1))
    fi
  fi
done < "$t/list"

echo "mutants-complete: $total total, $killed killed, $survived survived, $invalid invalid"
if [ "$survived" -gt 0 ] || [ "$invalid" -gt 0 ]; then
  exit 1
fi
echo "mutants-complete: PASS all mutants killed; hardware NOT_RUN"
