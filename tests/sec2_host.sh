#!/bin/sh
# Unprivileged host-only vendor protocol replay. Never opens a device.
set -eu
R=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
OMC=${OMC:-$R/build/omc}
SEC2_OM=${SEC2_OM:-$R/gsp/sec2.om}
actual=$(sha256sum "$OMC"); actual=${actual%% *}
[ "$actual" = bcfa582892afca8f65e551fe56867d918d86e84540c7381be8fa9ef18d0cf0f6 ] || exit 2
t=$(mktemp -d /tmp/sec2-host.XXXXXX)
trap 'rm -rf "$t"' EXIT HUP INT TERM
python3 - "$R" "$t" "$SEC2_OM" <<'PY'
import pathlib,sys
r,t,s=map(pathlib.Path,sys.argv[1:])
units=['gsp/rpc.om','gsp/replay.om','gsp/sysinfo.om','chan/params.om','gsp/boot.om','gsp/arena.om','gsp/connect.om','gsp/profile.om','gsp/mmio.om','gsp/sim.om']
text=''.join((r/p).read_text()+'\n' for p in units)
fixture=(r/'tests/arena_trace.om').read_text()
assert fixture.count('fn main to int')==1
text+=fixture.split('fn main to int')[0]
text+=s.read_text()+'\n'+(r/'gsp/sec2sim.om').read_text()+'\n'+(r/'tests/sec2_trace.om').read_text()
(t/'trace.om').write_text(text)
PY
"$OMC" < "$t/trace.om" > "$t/replay"
chmod +x "$t/replay"
python3 - "$t/replay" <<'PY'
import subprocess,sys
for m in range(15):
 p=subprocess.run([sys.argv[1]],input=bytes([m]),capture_output=True,timeout=60)
 if p.returncode: sys.exit(f'sec2_host: FAIL case {m} exit {p.returncode} {p.stderr!r}')
 print(f'sec2_host: PASS case {m}')
print('sec2_host: HOST_EXERCISED; physical boot/RPC/compute NOT_RUN')
PY
sha256sum "$t/trace.om" "$t/replay"
