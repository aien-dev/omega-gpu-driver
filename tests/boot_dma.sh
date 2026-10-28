#!/bin/sh
# Host only. Explicit DMA oracle replaces chan/dma.om at link time; no actual VFIO calls.
set -eu
R=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
OMC=${OMC:-$R/build/omc}
a=$(sha256sum "$OMC"); a=${a%% *}
[ "$a" = bcfa582892afca8f65e551fe56867d918d86e84540c7381be8fa9ef18d0cf0f6 ] || exit 2
t=$(mktemp -d /tmp/boot-dma.XXXXXX)
trap 'rm -rf "$t"' EXIT HUP INT TERM
sed 's/fn main to int/fn dmatests to int/' "$R/tests/dma_check.om" > "$t/dma.om"
sed 's/fn main to int/fn artests to int/' "$R/tests/arena_trace.om" > "$t/arena.om"
build() {
 cat "$R/tests/dma_replay.om" "$R/chan/gmmu.om" "$R/chan/mem.om" "$R/chan/chan.om" "$R/chan/sim.om" "$t/dma.om" "$R/gsp/rpc.om" "$R/gsp/sysinfo.om" "$R/chan/params.om" "$R/gsp/boot.om" "$R/gsp/arena.om" "$R/gsp/connect.om" "$t/arena.om" "$1" "$R/tests/boot_dma.om" > "$t/all.om"
 if ! "$OMC" < "$t/all.om" > "$t/replay"; then echo 'boot_dma: INVALID compile'; exit 2; fi
 chmod +x "$t/replay"
}
build "$R/gsp/owned.om"
"$t/replay"
echo 'boot_dma: PASS exact owned staging, generations, publication refusal and timeout quarantine; hardware NOT_RUN'
sha256sum "$t/all.om" "$t/replay"
sed 's/r = mapwrite get mmwh 0 0 arbuf 0 get arused 0/r = long get arused 0/' "$R/gsp/owned.om" > "$t/nocopy.om"
build "$t/nocopy.om"
if "$t/replay"; then echo 'boot_dma: SURVIVED staging'; exit 1; else rc=$?; fi
[ "$rc" = 1 ] || { echo 'boot_dma: INVALID staging mutant'; exit 2; }
sed 's/ret mmwquar gen/ret MMOK/' "$R/gsp/owned.om" > "$t/noquar.om"
build "$t/noquar.om"
if "$t/replay"; then echo 'boot_dma: SURVIVED quarantine'; exit 1; else rc=$?; fi
[ "$rc" = 1 ] || { echo 'boot_dma: INVALID quarantine mutant'; exit 2; }
echo 'boot_dma: PASS both behavior mutants detected; hardware NOT_RUN'
