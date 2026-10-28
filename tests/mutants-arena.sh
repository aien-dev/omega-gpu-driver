#!/bin/sh
# Mutants exist only in temporary copies. A compile refusal or runtime trap is INVALID, not detection.
set -eu
R=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
sh "$R/tests/arena_diff.sh"
python3 - "$R" <<'PY'
import os, pathlib, subprocess, sys, tempfile
r=pathlib.Path(sys.argv[1]); original=(r/'gsp/arena.om').read_text()
mutants=[
 ('radix','add araddr 11 add get arlvl add i 1 mul j 4096','add araddr 11 add get arlvl add i 1 mul j 4097'),
 ('logpte','v = add a mul j 4096','v = add a mul j 4097'),
 ('sharedpte','add araddr 10 mul i 4096 8','add araddr 10 mul i 4097 8'),
 ('wprheap','shl ulong 133 20','shl ulong 132 20'),
 ('signature','and add get arslen 1 255 not ulong 255','and add get arslen 1 127 not ulong 127'),
 ('cotfmc','arcput 28 get arslen 3 4','arcput 28 get arslen 2 4'),
 ('cotargs','arcput 860 araddr 15 8','arcput 860 araddr 9 8'),
 ('preboot','rqsend 72 936 936 false','rqsend 73 936 936 false'),
 ('profile','ne get arcfg 0 1','false'),
 ('registry','if ne arreg32 0 n','if false'),
 ('dma','if not ardma get arbase 0 get arused 0','if false'),
 ('heapdma','if not ardma get arcfg 2 get arcfg 3','if false'),
]
with tempfile.TemporaryDirectory(prefix='arena-mutants.') as tmp:
 for name,old,new in mutants:
    if original.count(old)!=1: sys.exit('mutants-arena: INVALID match '+name)
    f=pathlib.Path(tmp)/(name+'.om'); f.write_text(original.replace(old,new))
    env=dict(os.environ,ARENA_OM=str(f))
    q=subprocess.run(['sh',str(r/'tests/arena_diff.sh')],env=env,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True)
    detected=('arena_diff: FAIL exact arena/COT' in q.stdout or 'arena_diff: FAIL negative accepted' in q.stdout)
    if q.returncode==0 or not detected:
       print(q.stdout);sys.exit('mutants-arena: '+('SURVIVED ' if q.returncode==0 else 'INVALID ')+name)
    print('mutants-arena: DETECTED '+name)
print('mutants-arena: PASS behavior-only controls; hardware NOT_RUN')
PY
