#!/bin/sh
# Host verification only. Never invokes build/w0, firmware loading, map or VFIO calls.
set -eu
R=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
OMC=${OMC:-$R/build/omc}
AIENUX=${AIENUX:?set AIENUX to aienux c5bb3a4b9898257658aba0b7178a3c73a0371c27}
RPC_OM=${RPC_OM:-$R/gsp/rpc.om}
BOOT_OM=${BOOT_OM:-$R/gsp/boot.om}
expected=bcfa582892afca8f65e551fe56867d918d86e84540c7381be8fa9ef18d0cf0f6
actual=$(sha256sum "$OMC"); actual=${actual%% *}
[ "$actual" = "$expected" ] || { echo 'rpc_diff: compiler pin mismatch' >&2; exit 2; }
[ "$(git -C "$AIENUX" rev-parse HEAD)" = c5bb3a4b9898257658aba0b7178a3c73a0371c27 ] || exit 2
git -C "$AIENUX" diff --quiet HEAD -- native/kernel/dev/gb10_gsp_boot.c native/kernel/dev/gb10_gsp_boot.h || { echo 'rpc_diff: INVALID modified oracle'; exit 2; }
t=$(mktemp -d /tmp/rpc-replay.XXXXXX)
trap 'rm -rf "$t"' EXIT HUP INT TERM
cc -std=c11 -O1 -Wall -Wextra -I"$AIENUX/native/kernel/dev" "$R/tests/rpc_ref.c" "$AIENUX/native/kernel/dev/gb10_gsp_boot.c" -o "$t/ref"
"$t/ref" > "$t/ref.frames"
cat "$RPC_OM" "$R/gsp/replay.om" "$R/gsp/sysinfo.om" "$R/chan/params.om" "$BOOT_OM" "$R/tests/rpc_trace.om" > "$t/trace.om"
if ! "$OMC" < "$t/trace.om" > "$t/replay"; then echo 'rpc_diff: INVALID compile'; exit 3; fi
chmod +x "$t/replay"
if "$t/replay" > "$t/om.frames"; then :; else
 rc=$?; echo "rpc_diff: FAIL replay exit $rc"; exit 1
fi
if ! cmp "$t/ref.frames" "$t/om.frames"; then echo 'rpc_diff: FAIL exact frames'; exit 1; fi
echo 'rpc_diff: PASS exact command frames and boot/RPC transition controls; hardware NOT_RUN'
sha256sum "$t/trace.om" "$t/replay" "$t/ref" "$t/om.frames"
