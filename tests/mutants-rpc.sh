#!/bin/sh
# Mutation controls are test-only copies; no production source or historical receipt is rewritten.
set -eu
R=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
t=$(mktemp -d /tmp/rpc-mutants.XXXXXX)
trap 'rm -rf "$t"' EXIT HUP INT TERM
sh "$R/tests/rpc_diff.sh"
mutate() {
 name=$1; source=$2; pattern=$3; replacement=$4
 sed "s|$pattern|$replacement|" "$source" > "$t/$name.om"
 if cmp -s "$source" "$t/$name.om"; then echo "mutant $name INVALID no change"; exit 2; fi
 if [ "$source" = "$R/gsp/rpc.om" ]; then
  if RPC_OM="$t/$name.om" sh "$R/tests/rpc_diff.sh" > "$t/$name.log" 2>&1; then cat "$t/$name.log"; echo "mutant $name SURVIVED"; exit 1; fi
 else
  if BOOT_OM="$t/$name.om" sh "$R/tests/rpc_diff.sh" > "$t/$name.log" 2>&1; then cat "$t/$name.log"; echo "mutant $name SURVIVED"; exit 1; fi
 fi
 # Compiler/setup refusal is not a detected behavioral mutant.
 if ! grep -q 'rpc_diff: FAIL replay exit 101\|rpc_diff: FAIL exact frames' "$t/$name.log"; then
  cat "$t/$name.log"; echo "mutant $name INVALID build/setup or unexpected trap"; exit 2
 fi
 echo "mutant $name DETECTED"
}
mutate swaprx "$R/gsp/rpc.om" 'rd = rqget32 1 32' 'rd = rqget32 0 32'
mutate checksum "$R/gsp/rpc.om" 'rqput32 2 32 rqsum 2 mul div add add 80 n 7 8 8' 'rqput32 2 32 0'
mutate rxseq "$R/gsp/rpc.om" 'if ne rqget32 2 36 ulong get rqrx 0' 'if false'
mutate padding "$R/gsp/rpc.om" 'if ne rqsum 2 aligned 0' 'if false'
mutate version "$R/gsp/rpc.om" 'if or ne rqget32 2 48 RQVER ne rqget32 2 52 RQSIG' 'if false'
mutate timeout "$R/gsp/boot.om" 'ret bfail -11' 'ret 0'
mutate correlation "$R/gsp/boot.om" 'if not bcorrel' 'if false'
mutate guest "$R/gsp/boot.om" 'if ne get rqpriv 0 0' 'if false'
mutate seqtoken "$R/gsp/boot.om" 'if ne token get btoken 0' 'if false'
mutate seqgen "$R/gsp/boot.om" 'if ne gen get bgen 0' 'if false'
mutate handlerstatus "$R/gsp/boot.om" 'if ne get bresult 0 0' 'if false'
mutate pending "$R/gsp/boot.om" 'if eq get rqres 0 RQU32' 'if false'
mutate allocflags "$R/gsp/boot.om" 'if or ne rqget32 3 104 0 ne rqget32 3 108 0' 'if false'
mutate ctrlflags "$R/gsp/boot.om" 'if or ne rqget32 3 100 0 or ne rqget32 3 112 0 ne rqget32 3 116 0' 'if false'
mutate freeparent "$R/gsp/boot.om" 'if ne rqget32 3 84 0' 'if false'
mutate linkwait "$R/gsp/rpc.om" 'if eq get rqlink 0 0' 'if false'
mutate headerstatus "$R/gsp/boot.om" 'put bresult 0 get rqres 0' 'put bresult 0 0'
mutate routing "$R/gsp/rpc.om" 'if or ne rqget32 2 44 0 ne rqget32 2 76 0' 'if false'
mutate noncc "$R/gsp/rpc.om" 'if ne get rqtmp i 0' 'if false'
echo 'mutants-rpc: PASS all behavior controls detected; hardware NOT_RUN'
