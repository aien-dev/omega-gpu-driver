#!/bin/sh
# tests/mutants-rmchan.sh: single-line mutants of chan/rmchan.om.
# Each mutant must compile and fail tests/rmchan_diff.sh (killed).
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
t=$(mktemp -d /tmp/mutants-rmchan.XXXXXX) || exit 2
trap 'rm -rf "$t"' EXIT
run() { nice -n 19 taskset -c 10-14 "$@"; }

if ! sh "$here/tests/rmchan_diff.sh" > "$t/base.log" 2>&1; then
  cat "$t/base.log"; echo "mutants-rmchan: FAIL baseline is not green"; exit 2
fi

cat <<'EOF' > "$t/list"
schedule enable command mutated to disable|r = pasched 1 0 0|r = pasched 0 0 0
schedule disable command mutated to enable|r = pasched 0 0 0|r = pasched 1 0 0
TSG allocation class mutated|r = brmalloc get rmhcli 0 get rmhdev 0 get rmhtsg 0 PACTSG b|r = brmalloc get rmhcli 0 get rmhdev 0 get rmhtsg 0 PACVAS b
channel allocation parent mutated|r = brmalloc get rmhcli 0 get rmhdev 0 get rmhchan 0 PACGPF b|r = brmalloc get rmhcli 0 get rmhtsg 0 get rmhchan 0 PACGPF b
free sequence inverted|r = brmfree get rmhcli 0 get rmhctx 0 b|r = brmfree get rmhcli 0 get rmhtsg 0 b
rebinding retained RM slot permitted|if or ne get rmst 0 RMSIDLE ne get rmepoch 0 0|if false
RM free before semaphore drain permitted|if ne st RMSDRND|if false
publication active state check bypassed|if ne get rmst 0 RMSACTV|if false
submission stale release sequence accepted|if ne uint mmrd32 add tail mul i 4 get cmwds i|if false
EOF

killed=0; survived=0; invalid=0; total=0
while IFS='|' read -r desc orig mut; do
  total=$((total + 1))
  mfile="$t/mut_$total.om"
  if ! grep -qF "$orig" "$here/chan/rmchan.om"; then
    echo "mutants-rmchan: INVALID pattern '$orig'"; invalid=$((invalid + 1)); continue
  fi
  sed "s/$orig/$mut/" "$here/chan/rmchan.om" > "$mfile"
  if cmp -s "$mfile" "$here/chan/rmchan.om"; then
    echo "mutants-rmchan: INVALID identical mutation '$desc'"; invalid=$((invalid + 1)); continue
  fi
  if RMCHAN_OM="$mfile" sh "$here/tests/rmchan_diff.sh" > "$t/run.log" 2>&1; then
    echo "mutants-rmchan: SURVIVED mutant '$desc'"; survived=$((survived + 1))
  else
    rc=$?
    if [ "$rc" -eq 1 ]; then
      echo "mutants-rmchan: KILLED mutant '$desc'"
      killed=$((killed + 1))
    else
      echo "mutants-rmchan: INVALID mutant '$desc' exit $rc"
      cat "$t/run.log"
      invalid=$((invalid + 1))
    fi
  fi
done < "$t/list"

echo "mutants-rmchan: $total total, $killed killed, $survived survived, $invalid invalid"
if [ "$survived" -gt 0 ] || [ "$invalid" -gt 0 ]; then
  exit 1
fi
echo "mutants-rmchan: PASS all mutants killed; hardware NOT_RUN"
