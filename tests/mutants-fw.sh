#!/bin/sh
# mutants-fw.sh: single-line mutants of the firmware units (gsp/fw.om, gsp/inflate.om, gsp/sha2.om,
# gsp/bindata.om, fwprep.om); each must make tests/fw_diff.sh go red (exit 1). A mutant must change
# exactly the named line and still compile; otherwise it is INVALID and the run fails.
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
diff_sh=$here/tests/fw_diff.sh
t=$(mktemp -d /tmp/mutants-fw.XXXXXX) || exit 2
trap 'rm -rf "$t"' EXIT

if ! sh "$diff_sh" > "$t/base.log" 2>&1; then
  cat "$t/base.log"; echo "mutants-fw: FAIL baseline is not green"; exit 2
fi

# unit|desc|old line|new line  (whole-line match, exactly once in the unit)
cat > "$t/list" <<'EOF'
fw|ELF magic byte 1 'E' (69) taken as 68|if ne get fwhd 1 69|if ne get fwhd 1 68
fw|e_machine RISC-V (243) replaced by x86-64 (62)|if ne fwh16 18 243|if ne fwh16 18 62
fw|EI_VERSION check inverted|if ne get fwhd 6 1|if eq get fwhd 6 1
fw|e_shentsize 64 replaced by 40|if ne fwh16 58 64|if ne fwh16 58 40
fw|signature section matched by the build-id note name|if eq fwnmeq o 50 1|if eq fwnmeq o 49 1
inflate|CRC-32 polynomial low bit set|c = xor shr c 1 and 3988292384 m|c = xor shr c 1 and 3988292385 m
inflate|CRC-32 check compares the trailer with itself|if ne infle32 sub inlen 8 infcrc outlen|if ne infle32 sub inlen 8 infle32 sub inlen 8
inflate|ISIZE read from the CRC word|if ne infle32 sub inlen 4 outlen|if ne infle32 sub inlen 8 outlen
inflate|length base for symbol 257 is 4|put inflb 0 3|put inflb 0 4
sha2|SHA-256 K[63] off by one|put shk 63 3329325298|put shk 63 3329325299
sha2|SHA-384 IV word 0 off by one|put sh5h 0 14680500436340154072|put sh5h 0 14680500436340154073
bindata|lowercase hex digit base 87 ('a'-10) taken as 86|ret sub ulong c 87|ret sub ulong c 86
bindata|descriptor version 5 taken as 6|if ne bdw32 i 0 5|if ne bdw32 i 0 6
bindata|UCODE_HASH length 48 taken as 47|if ne get bdpn i 48|if ne get bdpn i 47
bindata|descriptor region alignment check inverted|if ne rem off 256 0|if eq rem off 256 0
fwprep|fmc.pubkey takes UCODE_SIG|e = fwpslot 10 4 2|e = fwpslot 11 4 2
fwprep|descriptor word stride 3 bytes|p = add get fwpdo 0 mul w 4|p = add get fwpdo 0 mul w 3
fwprep|stale fw.manifest not unlinked|u = unlink fwpp 0 get fwppn 0|u = long 0
fwprep|function-name check disabled|if eq m 0|if eq m 2
fwprep|manifest signature offset taken from .fwimage|fwodec get fwsof get fwsx 0|fwodec get fwsof get fwimx 0
EOF

killed=0; survived=0; invalid=0
while IFS='|' read -r unit desc o1 n1; do
  case $unit in
    fw) var=FW_OM; src=$here/gsp/fw.om ;;
    inflate) var=INFL_OM; src=$here/gsp/inflate.om ;;
    sha2) var=SHA2_OM; src=$here/gsp/sha2.om ;;
    bindata) var=BD_OM; src=$here/gsp/bindata.om ;;
    fwprep) var=FWPREP_OM; src=$here/fwprep.om ;;
    *) echo "mutant INVALID (unknown unit $unit): $desc"; invalid=$((invalid + 1)); continue ;;
  esac
  m=$t/$unit.om
  awk -v o1="$o1" -v n1="$n1" '
    $0 == o1 && !d1 { print n1; c1++; d1 = 1; next }
    $0 == o1 { c1++ }
    { print }
    END { if (c1 != 1) exit 1 }' "$src" > "$m"
  if [ $? -ne 0 ] || cmp -s "$src" "$m"; then
    echo "mutant INVALID (pattern not matched exactly once): $unit: $desc"; invalid=$((invalid + 1)); continue
  fi
  env "$var=$m" sh "$diff_sh" > "$t/m.log" 2>&1
  rc=$?
  case $rc in
    0) echo "mutant SURVIVED: $unit: $desc"; survived=$((survived + 1)) ;;
    1) echo "mutant killed: $unit: $desc ($(grep 'FAIL' "$t/m.log" | head -n 1))"; killed=$((killed + 1)) ;;
    *) echo "mutant INVALID (exit $rc: $(tail -n 1 "$t/m.log")): $unit: $desc"; invalid=$((invalid + 1)) ;;
  esac
done < "$t/list"
echo "mutants-fw: $killed killed, $survived survived, $invalid invalid"
[ "$survived" -eq 0 ] && [ "$invalid" -eq 0 ] && [ "$killed" -ge 12 ]
