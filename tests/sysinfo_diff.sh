#!/bin/sh
# sysinfo_diff.sh: builds the .om GspSystemInfo encoder (gsp/sysinfo.om + tests/sysinfo_cli.om) and the C reference
# (aienux PR #441 native/kernel/tools/ck_gsp_sysinfo_encode.c, compiled fresh into a temp dir as a test-only referee)
# and requires, for every case text, byte-identical stdout, the same exit code and the same 936 output bytes.
# Also: `fields` output identical; every field set by index (byidx) encodes like the C tool encodes the same values
# as text; the .om-only API refusals match fixed expected lines. Host only: no device is opened.
# Env: AIENUX (aienux checkout), OMC (pinned omc), SYSINFO_OM (library file to test; mutants use this).
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
AIENUX=${AIENUX:-/home/drakestapleton/work/OwnDriver/aienux}
OMC=${OMC:-$here/build/omc}
SYSINFO_OM=${SYSINFO_OM:-$here/gsp/sysinfo.om}
OMC_SHA=$(sed -n 's/^OMC_SHA256=//p' "$here/tools/omc.pin")
run() { nice -n 19 taskset -c 10-14 "$@"; }

got=$(sha256sum "$OMC" | cut -d' ' -f1)
if [ "$got" != "$OMC_SHA" ]; then
  echo "sysinfo_diff: FAIL omc sha256 $got, pinned $OMC_SHA"; exit 2
fi
if grep -n 'gspmode [0-9]* [1-9]\|gspbar\|vfio\|mapnew\|/dev/\|/sys/' "$here/tests/sysinfo_cli.om" "$SYSINFO_OM"; then
  echo "sysinfo_diff: FAIL encoder or test driver names a device"; exit 2
fi

t=$(mktemp -d /tmp/sysinfo_diff.XXXXXX) || exit 2
trap 'rm -rf "$t"' EXIT
k=$AIENUX/native/kernel
if ! run cc -std=c11 -O1 -Wall -Werror -o "$t/ck" "$k/tools/ck_gsp_sysinfo_encode.c"; then
  echo "sysinfo_diff: FAIL C reference build"; exit 2
fi
if ! cat "$SYSINFO_OM" "$here/tests/sysinfo_cli.om" | run "$OMC" > "$t/om"; then
  echo "sysinfo_diff: FAIL omc build"; exit 3
fi
chmod +x "$t/om"

# ---- case texts (the C tool's selftest texts first, then the parser's edge cases) ----
c=$t/cases
mkdir "$c"
rep() { printf "%$2s" '' | tr ' ' "$1"; }
printf 'gpuPhysAddr 0x24000000\nPCIDeviceID 0x2e1210de # GB10\n\nFHBBusInfo.deviceID 0x22d1\nhostPageSize 4096\nbWindowChannelAlwaysMapped 1\n' > "$c/01valid"
printf 'gpuPhysAdr 1\n' > "$c/02unknown"
printf 'Chipset 1\nChipset 2\n' > "$c/03repeat"
printf 'oorArch 256\n' > "$c/04fit1"
printf 'FHBBusInfo.deviceID 0x10000\n' > "$c/05fit2"
printf 'PCIRevisionID 0x100000000\n' > "$c/06fit4"
printf 'maxUserVa 0x10000000000000000\n' > "$c/07ovf16"
printf 'bIsPrimary -1\n' > "$c/08minus"
printf 'bIsPrimary 1x\n' > "$c/09trail"
printf 'bIsPrimary\n' > "$c/10want1"
printf 'bIsPrimary 1 2\n' > "$c/11want3"
printf 'acpiMethodData.dodMethodData 1\n' > "$c/12unkpart"
printf 'acpiMethodData.dodMethodData.status 0xffff\nacpiMethodData.jtMethodData.status 0x56\nacpiMethodData.capsMethodData.status 0x56\n' > "$c/13acpi"
printf 'Chipset 0777\nbIsPrimary 00\noorArch 0377\nconsoleMemSize 01777777777777777777777\n' > "$c/14octal"
printf 'maxUserVa 02000000000000000000000\n' > "$c/15octovf"
printf 'Chipset 08\n' > "$c/16octbad"
printf 'Chipset +0x10\nhypervisorType +7\nbIsPassthru +0\n' > "$c/17plus"
printf 'Chipset +-1\n' > "$c/18plusminus"
printf 'Chipset +\n' > "$c/19plusonly"
printf 'Chipset -0\n' > "$c/20minuszero"
printf '\tChipset\t0x10\r\n  oorArch   3  \r\n\013\014\n \t \n' > "$c/21ws"
{ printf 'Chipset 1'; rep ' ' 502; printf '\n'; } > "$c/22len511"
{ printf 'Chipset 1'; rep ' ' 503; printf '\n'; } > "$c/23len512"
{ printf 'oorArch 1\n#'; rep x 600; printf '\n'; } > "$c/24longcomment"
{ rep a 200; printf ' 1\n'; } > "$c/25longname3"
{ rep a 130; printf '\n'; } > "$c/26longname2"
{ printf 'Chipset '; rep 1 130; printf '\n'; } > "$c/27longval"
{ printf 'Chipset 0x'; rep 0 124; printf '1\n'; } > "$c/28zeros127"
{ printf 'Chipset 0x'; rep 0 125; printf '1\n'; } > "$c/29zeros128"
printf '# full comment\nChipset 5 # trailing\n#\noorArch 2#x\n   # indented\n' > "$c/30comments"
printf 'Chipset 5\noorArch 3' > "$c/31noeol"
printf 'Chipset 5\n\000oorArch 999\n' > "$c/32nul"
: > "$c/33empty"
printf 'maxUserVa 0xffffffffffffffff\nconsoleMemSize 18446744073709551615\n' > "$c/34max64"
printf 'maxUserVa 18446744073709551616\n' > "$c/35dec2p64"
{ printf 'oorArch 0x'; rep 0 50; printf '100\n'; } > "$c/36trunc40"
printf 'Chipset 0x\n' > "$c/37zerox"
printf 'Chipset 0xg\n' > "$c/38zeroxg"
printf 'Chipset 0X1F\nPCIDeviceID 0xABCDEF\nPCISubDeviceID 0xAbCd\n' > "$c/39hexcase"
printf 'FHBBusInfo.deviceID 0xffff\nPCIRevisionID 0xffffffff\noorArch 255\nvirtualConfigBits 65535\n' > "$c/40fitedge"
printf 'virtualConfigBits 65536\n' > "$c/41fit2dec"
printf 'Chipset   \n' > "$c/42nameonly"
printf 'Chipset 1\noorArch 1\n\n# c\nChipset 2\n' > "$c/43replate"
printf 'gpuPhysAddrX 1\n' > "$c/44longer"
printf 'gpuPhysAdd 1\n' > "$c/45prefix"
printf 'gpuphysaddr 1\n' > "$c/46case"
{ i=0; while [ $i -lt 3000 ]; do printf '\n'; i=$((i + 1)); done; printf 'bogus 1\n'; } > "$c/47line3001"
printf 'Chipset 0x1 0x2\n' > "$c/48want3b"
printf 'gpuPhysAddr 0x24000000\ngpuPhysInstAddr 0x24700000\nnvDomainBusDeviceFunc 0x0000000f00000100\nPCIDeviceID 0x2e1210de\nPCISubDeviceID 0x000010de\nPCIRevisionID 0xa1\nmaxUserVa 0x1000000000000\nhostPageSize 4096\npcieConfigReg.linkCap 0x00457901\noorArch 3\nChipset 0x106d\nFHBBusInfo.deviceID 0x22d1\nFHBBusInfo.vendorID 0x10de\nchipsetIDInfo.deviceID 0x22d1\nchipsetIDInfo.vendorID 0x10de\nclPdbProperties 0x1088020c1\nbFlrSupported 1\nb64bBar0Supported 1\npciConfigMirrorBase 0x92000\npciConfigMirrorSize 0x1000\npcieAtomicsOpMask 0x7\nhypervisorType 4\nacpiMethodData.bValid 1\nacpiMethodData.dodMethodData.status 0xffff\nacpiMethodData.dodMethodData.acpiIdListLen 64\nacpiMethodData.jtMethodData.status 0x56\nacpiMethodData.capsMethodData.status 0x56\nupstreamAddressValid 1\nbWindowChannelAlwaysMapped 1\nbIsUnixHdmiFrlComplianceEnabled 1\n' > "$c/49window1"
printf 'gspVFInfo.b64bitBar2 1\ngspVFInfo.FirstVFBar2Address 0x0102030405060708\nsysTimerOffsetNs 0x8000000000000000\nbS0ixSupport 0x0\n' > "$c/50tail"

# one run: stdout, then the exit code, then the output bytes (or "no output file")
one() {  # tool infile outfile -> stdout of the record
  rm -f "$t/out.bin"
  run "$1" encode "$2" "$3" > "$t/r.txt" 2> /dev/null
  echo "rc=$?" >> "$t/r.txt"
  cat "$t/r.txt"
  if [ -f "$t/out.bin" ]; then od -An -tx1 -v "$t/out.bin"; else echo "no output file"; fi
}
fail=0; n=0
for f in "$c"/*; do
  n=$((n + 1))
  one "$t/ck" "$f" "$t/out.bin" > "$t/c.rec"
  one "$t/om" "$f" "$t/out.bin" > "$t/o.rec"
  if ! cmp -s "$t/c.rec" "$t/o.rec"; then
    echo "sysinfo_diff: case $(basename "$f") differs:"; diff "$t/c.rec" "$t/o.rec" | head -8; fail=1
  fi
done
# missing input, unwritable output (negative controls on the file paths)
for args in "$t/no-such-file $t/out.bin" "$c/01valid $t/no-dir/out.bin"; do
  n=$((n + 1))
  # shellcheck disable=SC2086
  { run "$t/ck" encode $args; echo "rc=$?"; } > "$t/c.rec" 2>&1
  # shellcheck disable=SC2086
  { run "$t/om" encode $args; echo "rc=$?"; } > "$t/o.rec" 2>&1
  if ! cmp -s "$t/c.rec" "$t/o.rec"; then
    echo "sysinfo_diff: path case '$args' differs:"; diff "$t/c.rec" "$t/o.rec"; fail=1
  fi
done
# usage: stdout empty, exit 1 on both
for args in "" "fields x" "encode a" "selftestx" "encode a b c"; do
  n=$((n + 1))
  # shellcheck disable=SC2086
  { run "$t/ck" $args; echo "rc=$?"; } > "$t/c.rec" 2> /dev/null
  # shellcheck disable=SC2086
  { run "$t/om" $args; echo "rc=$?"; } > "$t/o.rec" 2> /dev/null
  if ! cmp -s "$t/c.rec" "$t/o.rec"; then
    echo "sysinfo_diff: usage case '$args' differs:"; diff "$t/c.rec" "$t/o.rec"; fail=1
  fi
done
# the field table
run "$t/ck" fields > "$t/c.f"; run "$t/om" fields > "$t/o.f"
if ! cmp -s "$t/c.f" "$t/o.f" || [ "$(wc -l < "$t/c.f")" -ne 72 ]; then
  echo "sysinfo_diff: fields differ"; diff "$t/c.f" "$t/o.f" | head -8; fail=1
fi
# every field by index: the .om bytes must equal the C tool's bytes for the same values as text
if ! run "$t/om" byidx "$t/idx.bin" > "$t/idx.txt" || [ "$(wc -l < "$t/idx.txt")" -ne 72 ]; then
  echo "sysinfo_diff: byidx run failed"; cat "$t/idx.txt"; fail=1
elif ! run "$t/ck" encode "$t/idx.txt" "$t/idxc.bin" > "$t/idxc.log" || ! cmp -s "$t/idx.bin" "$t/idxc.bin"; then
  echo "sysinfo_diff: byidx bytes differ from the C encoding of the same values"; cat "$t/idxc.log"; fail=1
fi
# negative control: a corrupted copy of the window-1 text is refused with nothing written
sed 's/^oorArch 3$/oorArch 0x103/' "$c/49window1" > "$t/bad.txt"
rm -f "$t/out.bin"
run "$t/om" encode "$t/bad.txt" "$t/out.bin" > "$t/bad.log"
brc=$?
if [ "$brc" -ne 2 ] || [ -f "$t/out.bin" ] || ! grep -qx 'REFUSED: line 10: 0x103 does not fit oorArch (1 bytes)' "$t/bad.log"; then
  echo "sysinfo_diff: negative control not refused (rc $brc)"; cat "$t/bad.log"; fail=1
fi
# .om-only API refusals
run "$t/om" api > "$t/api.txt"
cat > "$t/api.want" <<'EOF'
api nit rc=-9 why=sireset not called
api idx rc=-1 why=field index out of range
api fit rc=-3 why=0x100 does not fit oorArch (1 bytes)
api ok rc=0 why=
api rep rc=-2 why=field oorArch repeated
api name rc=0 why=
api unk rc=-4 why=unknown field chipset
api big rc=-8 why=text over 65536 bytes
api ok rc=0 why=
api bytes 2 0xff 0x6d 0x10 0 0
EOF
if ! cmp -s "$t/api.want" "$t/api.txt"; then
  echo "sysinfo_diff: api refusals differ"; diff "$t/api.want" "$t/api.txt"; fail=1
fi
if [ "$fail" -ne 0 ]; then
  echo "sysinfo_diff: FAIL"; exit 1
fi
echo "sysinfo_diff: PASS ($n encode/usage cases identical stdout+exit+bytes, 72 fields, 72 by-index sets, negative control refused, 10 API lines; .om vs C reference)"
