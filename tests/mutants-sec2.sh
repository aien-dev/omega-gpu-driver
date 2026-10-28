#!/bin/sh
set -eu
R=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
sh "$R/tests/sec2_host.sh"
python3 - "$R" <<'PY'
import os,pathlib,subprocess,sys,tempfile
r=pathlib.Path(sys.argv[1]); source=(r/'gsp/sec2.om').read_text()
mutants=[('secure-wait','if not s2wait 0 get s2cfg 2','if false'),('response-wait','if not s2wait 1 get s2cfg 3','if false'),('package','if ne get s2cfg 1 2','if false'),('response-vendor','if ne s2get 4 353427070','if false'),('response-error','if ne get s2out 3 0','if false'),('pointer','if ne e div n 4','if false')]
with tempfile.TemporaryDirectory(prefix='sec2-mutants.') as d:
 for name,old,new in mutants:
  assert source.count(old)==1,name
  p=pathlib.Path(d)/(name+'.om');p.write_text(source.replace(old,new))
  q=subprocess.run(['sh',str(r/'tests/sec2_host.sh')],env=dict(os.environ,SEC2_OM=str(p)),capture_output=True,text=True)
  if q.returncode!=1 or 'sec2_host: FAIL case ' not in q.stderr:
   sys.exit(f'INVALID/SURVIVED {name}: {q.returncode}\n{q.stdout}\n{q.stderr}')
  print('mutants-sec2: DETECTED '+name)
print('mutants-sec2: PASS; hardware NOT_RUN')
PY
