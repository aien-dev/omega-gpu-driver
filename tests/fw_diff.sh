#!/bin/sh
# fw_diff.sh: builds fwprep (gsp/sha2.om gsp/inflate.om gsp/fw.om gsp/bindata.om fwprep.om) with the
# pinned omc and the two C referees from aienux PR #441 (kernel/tools/ck_gsp_fw_inspect.c and
# kernel/tools/ck_gsp_bindata_extract.c with argus/sha256.c, compiled fresh into a temp dir as
# test-only referees, never linked into the product), then requires:
#   - fwprep stdout = C inspect stdout + C FMC extract stdout + C boot extract stdout + the fwprep
#     lines expected from the C --out files, byte for byte, exit 0;
#   - every output cmp-identical to the C --out file it comes from, fw.manifest identical to one
#     rebuilt here from the C outputs (od/wc/sha256sum), and the pinned digests and descriptor;
#   - negative controls refused by the C and by fwprep (exit 2, C stdout prefix identical, no
#     fw.manifest left, a stale one removed): truncated firmware, .fwsignature_gb10y renamed,
#     a flipped compressed byte (CRC-32), a flipped deflate body byte, a flipped UCODE_HASH byte;
#     plus fwprep's own refusals: wrong function, missing FWFILE (C stderr wording, exit 1),
#     OUTDIR not a directory (exit 3), usage (exit 1).
# Host only: reads the firmware and bindata files, writes a temp dir; no device.
# Env: AIENUX, OMC, FW (gsp_ga10x.bin), OGKM (open-gpu-kernel-modules-580.173.02 tree),
#      SHA2_OM INFL_OM FW_OM BD_OM FWPREP_OM (units to test; mutants use these).
# Exit 0 PASS, 1 differ, 2 setup, 3 omc failure.
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
AIENUX=${AIENUX:-/home/drakestapleton/work/OwnDriver/aienux}
OMC=${OMC:-$here/build/omc}
FW=${FW:-/lib/firmware/nvidia/580.173.02/gsp_ga10x.bin}
OGKM=${OGKM:-/home/drakestapleton/workspace/_ext/open-gpu-kernel-modules-580.173.02}
SHA2_OM=${SHA2_OM:-$here/gsp/sha2.om}
INFL_OM=${INFL_OM:-$here/gsp/inflate.om}
FW_OM=${FW_OM:-$here/gsp/fw.om}
BD_OM=${BD_OM:-$here/gsp/bindata.om}
FWPREP_OM=${FWPREP_OM:-$here/fwprep.om}
OMC_SHA=$(sed -n 's/^OMC_SHA256=//p' "$here/tools/omc.pin")
run() { nice -n 19 taskset -c 10-14 "$@"; }
fail() { echo "fw_diff: FAIL $2"; exit "$1"; }

FW_SHA=32cb7cf3e77f97e92f6e92135939ccb3ba382748144569c0dfccf3338d43d963
FMC_C=g_bindata_kgspGetBinArchiveGspRmFmcGfwProdSigned_GB10B.c
BOOT_C=g_bindata_kgspGetBinArchiveGspRmBoot_GB10B.c
FMC_F=kgspGetBinArchiveGspRmFmcGfwProdSigned_GB10B
BOOT_F=kgspGetBinArchiveGspRmBoot_GB10B
FMC_C_SHA=2861be1864befa21e4fe4a5d088dae816de8cd8f03359de9f7d35cff910c8957
BOOT_C_SHA=c9c0c0073837b8e38ef6fc94c3c531d6f03b22003fe084b0f9066631f4a0397b
FMC_IMG_SHA=b13ead4b9a6b8a0d268f3094cc4f4521d6be8a9a525edbc9a8f3f397c86f1f2e
BL_IMG_SHA=427a691d8453f02548d395f40ac900eb0d5b8ea864e8f14f958eef890ba400a2
# 0xa00 = 2560, 0xa600 = 42496, 0xb000 = 45056, 0x24d00 = 150784
DESC_PIN='version=5 bootloader_off=0 bootloader_size=0 bl_param_off=0 bl_param_size=0 elf_off=0 elf_size=0 app_version=0 manifest_off=0 manifest_size=2560 mdata_off=2560 mdata_size=42496 mcode_off=45056 mcode_size=150784 monitor_enabled=1'
G=$OGKM/src/nvidia/generated

got=$(sha256sum "$OMC" | cut -d' ' -f1)
[ "$got" = "$OMC_SHA" ] || fail 2 "omc sha256 $got, pinned $OMC_SHA"
[ "$(sha256sum < "$FW" | cut -d' ' -f1)" = "$FW_SHA" ] || fail 2 "firmware sha256 differs from the 580.173.02 pin: $FW"
[ "$(sha256sum < "$G/$FMC_C" | cut -d' ' -f1)" = "$FMC_C_SHA" ] || fail 2 "FMC bindata sha256 differs from the pin"
[ "$(sha256sum < "$G/$BOOT_C" | cut -d' ' -f1)" = "$BOOT_C_SHA" ] || fail 2 "boot bindata sha256 differs from the pin"
if grep -n 'vfio\|mapnew\|mapget\|mapset\|/dev/\|/sys/' "$SHA2_OM" "$INFL_OM" "$FW_OM" "$BD_OM" "$FWPREP_OM"; then
  fail 2 "a firmware unit names a device"
fi

t=$(mktemp -d /tmp/fw_diff.XXXXXX) || exit 2
trap 'rm -rf "$t"' EXIT
k=$AIENUX/native
for tool in ck_gsp_fw_inspect ck_gsp_bindata_extract; do
  run cc -std=c11 -O1 -Wall -Werror -I"$k/argus" -o "$t/$tool" "$k/kernel/tools/$tool.c" "$k/argus/sha256.c" \
    || fail 2 "C referee build $tool"
done
cat "$SHA2_OM" "$INFL_OM" "$FW_OM" "$BD_OM" "$FWPREP_OM" | run "$OMC" > "$t/fwprep" || fail 3 "omc build"
chmod +x "$t/fwprep"

# ---- positive run on the real inputs ----
run "$t/ck_gsp_fw_inspect" inspect "$FW" > "$t/insp.txt" || fail 2 "C inspect refused the real firmware"
run "$t/ck_gsp_bindata_extract" extract "$G/$FMC_C" > "$t/fmc.txt" || fail 2 "C extract refused FMC"
run "$t/ck_gsp_bindata_extract" extract "$G/$BOOT_C" > "$t/boot.txt" || fail 2 "C extract refused boot"
mkdir "$t/cfmc" "$t/cboot"
run "$t/ck_gsp_bindata_extract" extract "$G/$FMC_C" --out "$t/cfmc" > /dev/null || fail 2 "C extract --out FMC"
run "$t/ck_gsp_bindata_extract" extract "$G/$BOOT_C" --out "$t/cboot" > /dev/null || fail 2 "C extract --out boot"
cf=$t/cfmc/$FMC_F
cb=$t/cboot/$BOOT_F
cat "$t/insp.txt" "$t/fmc.txt" "$t/boot.txt" > "$t/want.txt"
set -- fmc.img "$cf.UCODE_IMAGE.bin" fmc.hash "$cf.UCODE_HASH.bin" fmc.pubkey "$cf.UCODE_PKEY.bin" \
  fmc.sig "$cf.UCODE_SIG.bin" bl.img "$cb.UCODE_IMAGE_PROD.bin"
outs=
while [ $# -ge 2 ]; do
  [ -f "$2" ] || fail 2 "C output missing: $2"
  printf 'fwprep wrote %s bytes=%s sha256=%s\n' "$1" "$(wc -c < "$2")" "$(sha256sum < "$2" | cut -d' ' -f1)" >> "$t/want.txt"
  printf 'out %s bytes=%s sha256=%s\n' "$1" "$(wc -c < "$2")" "$(sha256sum < "$2" | cut -d' ' -f1)" >> "$t/outs.txt"
  outs="$outs $1:$2"
  shift 2
done
printf 'fwprep wrote fw.manifest\nfwprep RESULT OK\n' >> "$t/want.txt"

sec() { sed -n "s/^section [0-9]* $1 type=[0-9]* offset=\([0-9]*\) size=\([0-9]*\)\$/offset=\1 size=\2/p" "$t/insp.txt"; }
names='version bootloader_off bootloader_size bl_param_off bl_param_size elf_off elf_size app_version manifest_off manifest_size mdata_off mdata_size mcode_off mcode_size monitor_enabled swbrom_code_off swbrom_code_size swbrom_data_off swbrom_data_size fb_reserved signed_as_code'
words=$(od -An -v -tu4 "$cb.UCODE_DESC_PROD.bin")
[ "$(echo $words | wc -w)" -eq 21 ] || fail 2 "C descriptor is not 21 words"
desc=$(set -- $words; for n in $names; do printf ' %s=%s' "$n" "$1"; shift; done)
{
  echo "fwmanifest 1"
  echo "fwversion $(sed -n 's/^fwversion //p' "$t/insp.txt")"
  echo "build_id $(sed -n 's/^build_id //p' "$t/insp.txt")"
  echo "fw_file bytes=$(wc -c < "$FW") sha256=$(sed -n 's/^sha256_file //p' "$t/insp.txt")"
  echo "fwimage $(sec '\.fwimage') sha256=$(sed -n 's/^sha256_fwimage \([0-9a-f]*\) .*/\1/p' "$t/insp.txt")"
  echo "fwsignature .fwsignature_gb10y $(sec '\.fwsignature_gb10y') sha256=$(sed -n 's/^sha256_signature //p' "$t/insp.txt")"
  echo "fmc_src $FMC_C bytes=$(wc -c < "$G/$FMC_C") sha256=$FMC_C_SHA"
  echo "boot_src $BOOT_C bytes=$(wc -c < "$G/$BOOT_C") sha256=$BOOT_C_SHA"
  echo "bl_desc UCODE_DESC_PROD$desc"
  cat "$t/outs.txt"
  echo end
} > "$t/manifest.want"

o=$t/out
mkdir "$o"
echo stale > "$o/fw.manifest"
run "$t/fwprep" "$FW" "$OGKM" "$o" > "$t/om.txt" 2> "$t/om.err"
rc=$?
[ "$rc" -eq 0 ] || { cat "$t/om.err"; tail -n 3 "$t/om.txt"; fail 1 "fwprep exit $rc on the real inputs"; }
[ -s "$t/om.err" ] && fail 1 "fwprep wrote to stderr on success"
n=$(wc -l < "$t/want.txt")
if ! cmp -s "$t/want.txt" "$t/om.txt"; then
  diff "$t/want.txt" "$t/om.txt" | head -n 6
  fail 1 "stdout differs ($(diff "$t/want.txt" "$t/om.txt" | grep -c '^[<>]') differing lines; want $n)"
fi
for p in $outs; do
  cmp -s "${p#*:}" "$o/${p%%:*}" || fail 1 "${p%%:*} differs from the C output"
done
if ! cmp -s "$t/manifest.want" "$o/fw.manifest"; then
  diff "$t/manifest.want" "$o/fw.manifest" | head -n 6
  fail 1 "fw.manifest differs from the one rebuilt from the C outputs"
fi
[ "$(ls "$o" | wc -l)" -eq 6 ] || fail 1 "OUTDIR holds other files: $(ls "$o" | tr '\n' ' ')"
[ "$(sha256sum < "$o/fmc.img" | cut -d' ' -f1)" = "$FMC_IMG_SHA" ] || fail 1 "fmc.img sha256 pin"
[ "$(wc -c < "$o/fmc.img")" -eq 195912 ] || fail 1 "fmc.img size pin"
[ "$(sha256sum < "$o/bl.img" | cut -d' ' -f1)" = "$BL_IMG_SHA" ] || fail 1 "bl.img sha256 pin"
[ "$(wc -c < "$o/bl.img")" -eq 196608 ] || fail 1 "bl.img size pin"
grep -qF "bl_desc UCODE_DESC_PROD $DESC_PIN " "$o/fw.manifest" || fail 1 "descriptor pin"
echo "fw_diff: positive PASS ($n stdout lines, 5 outputs and fw.manifest identical to the C referees)"

# ---- negative controls ----
# edit_line SRC LINE OLD NEW DST: replace line LINE (which must read OLD) with NEW; exactly once
edit_line() {
  awk -v n="$2" -v a="$3" -v b="$4" 'NR == n && $0 == a { print b; c++; next } { print } END { exit c == 1 ? 0 : 1 }' \
    "$1" > "$5" || fail 2 "control edit did not apply at $1:$2"
}
# tree NAME FMCFILE BOOTFILE: a minimal OGKMSRC holding the two bindata files
tree() {
  mkdir -p "$t/$1/src/nvidia/generated"
  cp "$2" "$t/$1/src/nvidia/generated/$FMC_C"
  cp "$3" "$t/$1/src/nvidia/generated/$BOOT_C"
}
neg=0
# refused NAME FWFILE OGKMSRC WANTPREFIXFILE LASTLINE: fwprep exits 2, prints the C prefix then LASTLINE,
# leaves no fw.manifest (a stale one is removed)
refused() {
  d=$t/o_$1
  mkdir -p "$d"
  echo stale > "$d/fw.manifest"
  run "$t/fwprep" "$2" "$3" "$d" > "$t/$1.om" 2> "$t/$1.err"
  r=$?
  [ "$r" -eq 2 ] || fail 1 "control $1: fwprep exit $r, want 2"
  { cat "$4"; echo "$5"; } > "$t/$1.want"
  cmp -s "$t/$1.want" "$t/$1.om" || { diff "$t/$1.want" "$t/$1.om" | head -n 4; fail 1 "control $1: stdout differs"; }
  [ -e "$d/fw.manifest" ] && fail 1 "control $1: fw.manifest left behind"
  neg=$((neg + 1))
  echo "fw_diff: control $1 refused (exit 2): $(grep -h 'REFUSED' "$t/$1.want" | tail -n 2 | tr '\n' ' ')"
}
# cref NAME TOOLARGS...: the C referee must refuse (exit 2); its stdout goes to $t/NAME.c
cref() {
  nm=$1; shift
  run "$@" > "$t/$nm.c"
  r=$?
  [ "$r" -eq 2 ] || fail 1 "control $nm: C referee exit $r, want 2"
}

# 1 truncated firmware (ends inside .fwsignature_gb10y)
head -c 74985600 "$FW" > "$t/trunc.bin"
cref trunc "$t/ck_gsp_fw_inspect" inspect "$t/trunc.bin"
refused trunc "$t/trunc.bin" "$OGKM" "$t/trunc.c" "fwprep REFUSED firmware"
rm -f "$t/trunc.bin"
# 2 .fwsignature_gb10y renamed to .fwsignature_gb10x in the section string table
off=$(grep -obaF .fwsignature_gb10y "$FW" | cut -d: -f1)
[ "$(echo "$off" | wc -l)" -eq 1 ] && [ -n "$off" ] || fail 2 "section name not found once"
cp "$FW" "$t/ren.bin"
printf x | dd of="$t/ren.bin" bs=1 seek=$((off + 17)) conv=notrunc 2> /dev/null
cref ren "$t/ck_gsp_fw_inspect" inspect "$t/ren.bin"
grep -q 'no signature section' "$t/ren.c" || fail 1 "control ren: C refused for another reason"
refused ren "$t/ren.bin" "$OGKM" "$t/ren.c" "fwprep REFUSED firmware"
rm -f "$t/ren.bin"
# 3 CRC-32: UCODE_DESC_PROD trailer byte 0xb7 -> 0xb6
edit_line "$G/$BOOT_C" 24717 '    0x78, 0xf4, 0x01, 0x00, 0xb7, 0x2b, 0xc9, 0xc2, 0x54, 0x00, 0x00, 0x00,' \
  '    0x78, 0xf4, 0x01, 0x00, 0xb6, 0x2b, 0xc9, 0xc2, 0x54, 0x00, 0x00, 0x00,' "$t/crc.c.in"
tree crc "$G/$FMC_C" "$t/crc.c.in"
cref crcb "$t/ck_gsp_bindata_extract" extract "$t/crc/src/nvidia/generated/$BOOT_C"
grep -q 'CRC-32 mismatch' "$t/crcb.c" || fail 1 "control crc: C refused for another reason"
cat "$t/insp.txt" "$t/fmc.txt" "$t/crcb.c" > "$t/crc.c"
refused crc "$FW" "$t/crc" "$t/crc.c" "fwprep REFUSED bindata $BOOT_C"
# 4 deflate body: UCODE_DESC_PROD compressed byte 0x20 -> 0x30
edit_line "$G/$BOOT_C" 24716 '    0x63, 0x65, 0x20, 0x02, 0x70, 0x41, 0xf1, 0x32, 0x20, 0xde, 0x00, 0xc4, 0xbe, 0x4c, 0x0c, 0x8c,' \
  '    0x63, 0x65, 0x30, 0x02, 0x70, 0x41, 0xf1, 0x32, 0x20, 0xde, 0x00, 0xc4, 0xbe, 0x4c, 0x0c, 0x8c,' "$t/body.c.in"
tree body "$G/$FMC_C" "$t/body.c.in"
cref bodyb "$t/ck_gsp_bindata_extract" extract "$t/body/src/nvidia/generated/$BOOT_C"
grep -q 'inflate' "$t/bodyb.c" || fail 1 "control body: C refused for another reason"
cat "$t/insp.txt" "$t/fmc.txt" "$t/bodyb.c" > "$t/body.c"
refused body "$FW" "$t/body" "$t/body.c" "fwprep REFUSED bindata $BOOT_C"
# 5 hash mismatch: first UCODE_HASH byte 0x2f -> 0x2e
edit_line "$G/$FMC_C" 12319 '    0x2f, 0xb0, 0x24, 0x61, 0x26, 0x9a, 0x45, 0xd3, 0xd4, 0x6c, 0x7b, 0x01, 0x88, 0x07, 0xff, 0x06,' \
  '    0x2e, 0xb0, 0x24, 0x61, 0x26, 0x9a, 0x45, 0xd3, 0xd4, 0x6c, 0x7b, 0x01, 0x88, 0x07, 0xff, 0x06,' "$t/hash.c.in"
tree hash "$t/hash.c.in" "$G/$BOOT_C"
cref hashf "$t/ck_gsp_bindata_extract" extract "$t/hash/src/nvidia/generated/$FMC_C"
grep -q 'UCODE_HASH is not SHA-384 of UCODE_IMAGE' "$t/hashf.c" || fail 1 "control hash: C refused for another reason"
cat "$t/insp.txt" "$t/hashf.c" > "$t/hash.c"
refused hash "$FW" "$t/hash" "$t/hash.c" "fwprep REFUSED bindata $FMC_C"
# 6 wrong function: the boot file in the FMC slot (the C accepts it; fwprep's own check refuses)
tree swap "$G/$BOOT_C" "$G/$BOOT_C"
cat "$t/insp.txt" "$t/boot.txt" > "$t/swap.c"
refused swap "$FW" "$t/swap" "$t/swap.c" "fwprep REFUSED unexpected function $BOOT_F in $FMC_C"
# 7 missing FWFILE: exit 1 with the C's stderr line, nothing on stdout
run "$t/ck_gsp_fw_inspect" inspect "$t/nofile" > /dev/null 2> "$t/nofile.cerr"
run "$t/fwprep" "$t/nofile" "$OGKM" "$t/o_nofile" > "$t/nofile.om" 2> "$t/nofile.err"
r=$?
[ "$r" -eq 1 ] || fail 1 "control nofile: fwprep exit $r, want 1"
[ -s "$t/nofile.om" ] && fail 1 "control nofile: stdout not empty"
cmp -s "$t/nofile.cerr" "$t/nofile.err" || fail 1 "control nofile: stderr differs from the C"
neg=$((neg + 1))
# 8 OUTDIR is a regular file: every check passes, the first output write fails, exit 3, no manifest
echo x > "$t/notdir"
run "$t/fwprep" "$FW" "$OGKM" "$t/notdir" > "$t/notdir.om" 2> /dev/null
r=$?
[ "$r" -eq 3 ] || fail 1 "control notdir: fwprep exit $r, want 3"
tail -n 1 "$t/notdir.om" | grep -q "^fwprep FAILED makedir $t/notdir: File exists\$\|^fwprep FAILED write $t/notdir/fmc.img: Not a directory\$" \
  || fail 1 "control notdir: $(tail -n 1 "$t/notdir.om")"
neg=$((neg + 1))
# 9 usage
run "$t/fwprep" "$FW" "$OGKM" > /dev/null 2> "$t/usage.err"
r=$?
[ "$r" -eq 1 ] || fail 1 "control usage: fwprep exit $r, want 1"
grep -qx 'usage: fwprep FWFILE OGKMSRC OUTDIR' "$t/usage.err" || fail 1 "control usage: stderr"
neg=$((neg + 1))
echo "fw_diff: PASS ($n stdout lines and 6 files identical to the C referees; $neg/9 negative controls refused)"
