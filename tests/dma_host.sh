#!/bin/sh
# Host verification only. No device open, VFIO release/reset, DMA or hardware MMIO.
# Production .om is tested with anonymous memory + invalid fd; DMA success/error is explicit replay.
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
OMC=${OMC:-$here/build/omc}
want=bcfa582892afca8f65e551fe56867d918d86e84540c7381be8fa9ef18d0cf0f6
got=$(sha256sum "$OMC" | cut -d' ' -f1)
[ "$got" = "$want" ] || { echo "dma_host: wrong compiler $got"; exit 2; }
t=$(mktemp -d /tmp/dma_host.XXXXXX) || exit 2
trap 'rm -rf "$t"' EXIT
run() { nice -n 19 taskset -c 10-14 "$@"; }
build() {
  transport=$1; gmmu=$2; mem=$3; main=$4; out=$5
  cat "$transport" "$gmmu" "$mem" "$here/chan/chan.om" "$here/chan/sim.om" "$main" | run "$OMC" > "$out" || return 2
  chmod +x "$out"
}
check() {
  prog=$1; mode=$2; expected=$3
  run "$prog" "$mode" > "$t/run.log" 2>&1; rc=$?
  if [ "$rc" -ne "$expected" ]; then
    echo "dma_host: mode $mode returned $rc, expected $expected"
    cat "$t/run.log"
    return 1
  fi
}
build "$here/tests/dma_replay.om" "$here/chan/gmmu.om" "$here/chan/mem.om" "$here/tests/dma_check.om" "$t/replay" || exit 2
for mode in a b c d e f g h i j k l s t u w x; do
  check "$t/replay" "$mode" 0 || exit 1
done
for mode in m n o q r; do check "$t/replay" "$mode" 103 || exit 1; done
for mode in v; do check "$t/replay" "$mode" 109 || exit 1; done
build "$here/chan/dma.om" "$here/chan/gmmu.om" "$here/chan/mem.om" "$here/tests/dma_badfd.om" "$t/badfd" || exit 2
run "$t/badfd" || { echo 'dma_host: real invalid-fd refusal failed'; exit 1; }
sha256sum "$here/chan/dma.om" "$here/chan/gmmu.om" "$here/chan/mem.om" "$here/chan/chan.om" "$here/tests/dma_check.om" "$t/replay" "$t/badfd"
echo 'dma_host: 23 replay/boundary cases and real invalid-fd retry/drop PASS'
# Scoped whole-line mutants must still compile and must break the same behavior check.
cat > "$t/mutants" <<'EOF'
gmmu|mmrd64|ret mapget get mmwh 0 o 8|ret 0|a|0
gmmu|mmwdmap|r = mmdmaop 1 fd get mmwh 0 get mmwb 0 get mmws 0|r = mmdmaop 1 fd get mmwh 0 add get mmwb 0 4096 get mmws 0|b|0
gmmu|mmwclose|if eq get mmwst 0 MMWDMA|if eq get mmwst 0 MMWPUB|b|0
gmmu|mmwclose|if or ne r 0 ne get mmduout 0 get mmws 0|if ne r 0|f|0
gmmu|mmwpublish|if ne get mmwst 0 MMWDMA|if eq get mmwst 0 MMWNONE|b|0
gmmu|mmwclose|if not mmwmutable|if eq get mmwst 0 MMWNONE|j|0
gmmu|mmwoff|if gt n sub s o|if eq n 0|m|103
mem|gmretire|if not mmwmutable|if eq get mmwst 0 MMWNONE|j|0
gmmu|mminval|r = mmwquar get mmwgen 0|r = MMOK|k|0
gmmu|mmwdmap|if not mmwepoch gen|if eq gen 0|b|0
gmmu|mmwclose|if ne r 0|if eq r 1|i|0
EOF
killed=0
while IFS='|' read -r unit fn old new mode expected; do
  src=$here/chan/$unit.om
  awk -v fn="$fn" -v old="$old" -v new="$new" '
    /^fn / { active = ($2 == fn) }
    active && $0 == old { print new; count++; next }
    { print }
    END { if (count != 1) exit 1 }
  ' "$src" > "$t/mutant.om" || { echo "dma_host: INVALID mutant $fn:$old"; exit 2; }
  gmmu=$here/chan/gmmu.om; mem=$here/chan/mem.om
  case $unit in gmmu) gmmu=$t/mutant.om ;; mem) mem=$t/mutant.om ;; esac
  build "$here/tests/dma_replay.om" "$gmmu" "$mem" "$here/tests/dma_check.om" "$t/mutant" || { echo "dma_host: INVALID noncompiling mutant $fn"; exit 2; }
  if check "$t/mutant" "$mode" "$expected" > "$t/mutant.log" 2>&1; then
    echo "dma_host: SURVIVED mutant $fn:$old"; exit 1
  fi
  killed=$((killed + 1))
done < "$t/mutants"
echo "dma_host: $killed compiled ownership/order/range/error mutants killed; hardware NOT_RUN"
