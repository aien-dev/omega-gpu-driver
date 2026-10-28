#!/bin/sh
# HOST ONLY. No GPU/VFIO fd. Python coordinates explicit anonymous-map peers and mutants.
set -eu
R=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
OMC=${OMC:-$R/build/omc}
a=$(sha256sum "$OMC"); a=${a%% *}
[ "$a" = bcfa582892afca8f65e551fe56867d918d86e84540c7381be8fa9ef18d0cf0f6 ] || exit 2
export R OMC
python3 - <<'PY'
import os,pathlib,subprocess,tempfile,hashlib,re
r=pathlib.Path(os.environ['R']); omc=os.environ['OMC']
parts=['tests/dma_replay.om','chan/gmmu.om','chan/mem.om','chan/chan.om','chan/sim.om','tests/dma_check.om','gsp/rpc.om','gsp/sysinfo.om','chan/params.om','gsp/boot.om','gsp/arena.om','gsp/connect.om','gsp/owned.om','gsp/profile.om','tests/arena_trace.om','tests/rpc_trace.om']
base=[]
for i,p in enumerate(parts):
 s=(r/p).read_text()
 if p.startswith('tests/'):
  s=s.replace('fn main to int',f'fn zzmain{i} to int')
 base.append(s)
transport=(r/'gsp/transport.om').read_text(); trace=(r/'tests/transport_trace.om').read_text()
notify=(r/'gsp/notify.om').read_text(); failnotify='note Explicit HOST TEST ONLY failed notification model.\nfn qtbell h long to long\nret -5\nend\n'
with tempfile.TemporaryDirectory(prefix='gsp-transport-') as td:
 t=pathlib.Path(td)
 def build(body,nt=notify,name='trace'):
  src='\n'.join(base+[body,nt,trace]); p=t/name
  c=subprocess.run([omc],input=src.encode(),stdout=subprocess.PIPE,stderr=subprocess.PIPE)
  if c.returncode:
   raise RuntimeError('INVALID compile '+name+': '+c.stderr.decode(errors='replace')+' '+c.stdout.decode(errors='replace'))
  p.write_bytes(c.stdout);p.chmod(0o700)
  return p,src
 def check(p,mode,expected=0):
  z=subprocess.run([str(p)],input=bytes([mode]),capture_output=True)
  if z.returncode!=expected:
   raise RuntimeError(f'{p.name} mode{mode}: observed{z.returncode}, expected{expected}: '+z.stderr.decode(errors='replace'))
 p,src=build(transport)
 for mode in [105,97,119,102,103,98,120,118,101,114,99,109,104,116,115]:check(p,mode)
 print('transport_host: PASS 15 mapped boot+schedule/queue/profile/generation/wrap/snapshot/token/error/timeout/retention cases; hardware NOT_RUN')
 print('transport source sha256',hashlib.sha256(src.encode()).hexdigest())
 print('transport binary sha256',hashlib.sha256(p.read_bytes()).hexdigest())
 p,_=build(transport,failnotify,'notify-failure');check(p,112)
 print('transport_host: PASS postpublication notification failure retains identity and quarantines; hardware NOT_RUN')
 mutants=[
 ('slotcopy','r = mapwrite h o rqtmp mul i RQSLOT RQSLOT','r = long RQSLOT',97,notify),
 ('publish','r = mapset h add get qtcmd 0 16 4 rem add wr e RQCOUNT','r = mapset h add get qtcmd 0 16 4 wr',97,notify),
 ('ack','x = mapset get mmwh 0 add get qtcmd 0 32 4 rqget32 0 32','x = mapset get mmwh 0 add get qtcmd 0 32 4 0',116,notify),
 ('token','if or ne get qtpend 0 1 ne token get qttok 0','if false',116,notify),
 ('snapshot','r = rqrecv','rqput32 1 16 mapget get mmwh 0 add get qtstat 0 16 4\nr = rqrecv',115,notify),
 ('notifyloss','r = qtbell get qtbar 0\nif ne r 0\nqtlose','r = qtbell get qtbar 0\nif ne r 0',112,failnotify),
 ('reset','ret eq get qtstate 0 0','ret true',98,notify),
 ('generation','ret eq get qtboot 0 get bgen 0','ret true',103,notify),
 ]
 for name,old,new,mode,nt in mutants:
  if transport.count(old)!=1:raise RuntimeError('INVALID mutant anchor '+name)
  p,_=build(transport.replace(old,new),nt,name)
  check(p,mode,1)
  print('DETECTED',name)
 # Ordering is a code-generation check, NOT a claim serialized peers prove fence necessity.
 probe='fn main to int\nh = mapnew -1 0 4096 3\nr = mapset h 0 4 9\nv = mapget h 0 4\nif ne v 9\nret 1\nend\nr = mapdrop h\nret int r\nend\n'
 z=subprocess.run([omc],input=probe.encode(),capture_output=True)
 if z.returncode:raise RuntimeError('INVALID ordering probe compile')
 p=t/'ordering';p.write_bytes(z.stdout);p.chmod(0o700)
 if subprocess.run([str(p)]).returncode:raise RuntimeError('ordering probe behavior')
 text=subprocess.check_output(['objdump','-d',str(p)],text=True)
 ins=[]
 for line in text.splitlines():
  m=re.match(r'\s*[0-9a-f]+:\s+[0-9a-f]{8}\s+(.+)',line)
  if m:ins.append(m.group(1).strip())
 def ordered(xs):
  hits=[]
  for i,x in enumerate(xs):
   if x.startswith('dsb') and x.split()[-1]=='sy' and i+2<len(xs):
    if xs[i+2].startswith('dsb') and xs[i+2].split()[-1]=='sy':
     hits.append(xs[i+1].split()[0])
  return hits==['str','ldr']
 if not ordered(ins):raise RuntimeError('INVALID generated DSB/store/load ordering: '+repr(ins))
 bad=ins.copy();bad[next(i for i,x in enumerate(bad) if x.startswith('dsb'))]='nop'
 if ordered(bad):raise RuntimeError('SURVIVED missing-fence disassembly mutant')
 print('transport_host: PASS generated DSB SY/store/DSB SY and DSB SY/load/DSB SY; missing-fence checker mutant detected. Device coherency NOT_RUN')
 print('ordering probe binary sha256',hashlib.sha256(z.stdout).hexdigest())
 print('transport_host: PASS 8 behavior mutants; hardware/kernel execution NOT_RUN')
PY
