#!/bin/sh
# pm_gate.sh: runtime-PM planted fault (tests/pm_gate.om) on the real gsp/mmio.om, then two mutants that
# must go red: the gate removed, and the gate accepting any runtime_status text. Host only: the device
# file is a temp file, never /sys. Exit 0 PASS, 1 FAIL, 2 setup.
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
OMC=${OMC:-$here/build/omc}
OMC_SHA=$(sed -n 's/^OMC_SHA256=//p' "$here/tools/omc.pin")
run() { nice -n 19 taskset -c 10-14 "$@"; }
[ "$(sha256sum "$OMC" | cut -d' ' -f1)" = "$OMC_SHA" ] || { echo "pm_gate: FAIL omc pin"; exit 2; }
t=$(mktemp -d /tmp/pm_gate.XXXXXX) || exit 2
trap 'rm -rf "$t"' EXIT
printf 'suspended\n' > "$t/sus"
printf 'active\n' > "$t/act"
printf 'activa\n' > "$t/near"
# build SRC -> run -> exit code
try() {
  cat "$1" "$here/gsp/sim.om" "$here/tests/pm_gate.om" | run "$OMC" > "$t/p" 2>"$t/err" || return 200
  chmod +x "$t/p"
  run "$t/p" "$t/sus" "$t/act" "$t/near" >/dev/null 2>&1
}
try "$here/gsp/mmio.om"; rc=$?
[ "$rc" -eq 0 ] || { echo "pm_gate: FAIL baseline exit $rc"; exit 1; }
# mutant 1: the gate call removed (3 lines: if not gsppm / ret gspfail EPM / end)
awk '$0=="if not gsppm"{s=3} s>0{s--; next} {print}' "$here/gsp/mmio.om" > "$t/m1.om"
cmp -s "$here/gsp/mmio.om" "$t/m1.om" && { echo "pm_gate: FAIL mutant 1 did not apply"; exit 2; }
try "$t/m1.om"; m1=$?
# mutant 2: the reader stops comparing bytes
awk '$0=="if ne get gpmb i get pmact i"{print "if false"; next} {print}' "$here/gsp/mmio.om" > "$t/m2.om"
cmp -s "$here/gsp/mmio.om" "$t/m2.om" && { echo "pm_gate: FAIL mutant 2 did not apply"; exit 2; }
try "$t/m2.om"; m2=$?
[ "$m1" -ne 0 ] && [ "$m1" -ne 200 ] || { echo "pm_gate: FAIL mutant 1 (gate removed) exit $m1"; exit 1; }
[ "$m2" -ne 0 ] && [ "$m2" -ne 200 ] || { echo "pm_gate: FAIL mutant 2 (any text accepted) exit $m2"; exit 1; }
echo "pm_gate: PASS (5 cases; mutants red: gate removed exit $m1, any text accepted exit $m2)"
