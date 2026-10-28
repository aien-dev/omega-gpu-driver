#!/bin/sh
# Unprivileged synthetic host gate only. Does not load firmware or touch a device.
set -eu
R=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
OMC=${OMC:-$R/build/omc}
AIENUX=${AIENUX:?set AIENUX to pinned reference checkout}
ARENA_OM=${ARENA_OM:-$R/gsp/arena.om}
actual=$(sha256sum "$OMC"); actual=${actual%% *}
[ "$actual" = bcfa582892afca8f65e551fe56867d918d86e84540c7381be8fa9ef18d0cf0f6 ] || { echo 'arena_diff: INVALID compiler pin'; exit 2; }
[ "$(git -C "$AIENUX" rev-parse HEAD)" = c5bb3a4b9898257658aba0b7178a3c73a0371c27 ] || { echo 'arena_diff: INVALID oracle pin'; exit 2; }
git -C "$AIENUX" diff --quiet HEAD -- native/kernel/dev/gb10_gsp_boot.c native/kernel/dev/gb10_gsp_boot.h || { echo 'arena_diff: INVALID modified oracle'; exit 2; }
t=$(mktemp -d /tmp/arena-parity.XXXXXX)
trap 'rm -rf "$t"' EXIT HUP INT TERM
cc -std=c11 -O1 -Wall -Wextra -I"$AIENUX/native/kernel/dev" "$R/tests/arena_ref.c" "$AIENUX/native/kernel/dev/gb10_gsp_boot.c" -o "$t/ref"
cat "$R/gsp/rpc.om" "$R/gsp/replay.om" "$R/gsp/sysinfo.om" "$R/chan/params.om" "$R/gsp/boot.om" "$ARENA_OM" "$R/gsp/connect.om" "$R/tests/arena_trace.om" > "$t/trace.om"
if ! "$OMC" < "$t/trace.om" > "$t/replay"; then echo 'arena_diff: INVALID compile'; exit 2; fi
chmod +x "$t/replay"
python3 - "$t" <<'PY'
import pathlib, subprocess, sys
p=pathlib.Path(sys.argv[1])
def run(name, mode):
    return subprocess.run([str(p/name)], input=bytes([mode]), stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=60)
for mode in range(5):
    ref=run('ref',mode)
    if ref.returncode: sys.exit('arena_diff: INVALID oracle positive '+str(mode))
    om=run('replay',mode)
    if om.returncode: sys.exit('arena_diff: FAIL replay exit '+str(om.returncode)+' case '+str(mode))
    if om.stdout!=ref.stdout: sys.exit('arena_diff: FAIL exact arena/COT case '+str(mode))
for mode in range(10,41):
    ref=run('ref',mode)
    if ref.returncode!=3 or ref.stdout: sys.exit('arena_diff: INVALID oracle negative '+str(mode))
    om=run('replay',mode)
    if om.returncode==0: sys.exit('arena_diff: FAIL negative accepted case '+str(mode))
    if om.returncode!=3 or om.stdout: sys.exit('arena_diff: INVALID negative trap/status '+str(om.returncode)+' case '+str(mode))
print('arena_diff: PASS exact arena bytes, plan, COT, preboot attach/INIT_DONE seam and negative refusals; hardware NOT_RUN')
PY
sha256sum "$t/trace.om" "$t/replay" "$t/ref"
