#!/bin/sh
# build.sh -- birth the pinned omc (tools/getomc.sh) and compile w0.om into build/w0 and the firmware
# input tool (gsp/sha2.om gsp/inflate.om gsp/fw.om gsp/bindata.om fwprep.om) into build/fwprep.
# A failed compile leaves no output behind.
set -eu
R=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
cd "$R"
sh tools/getomc.sh
# compile OUT SRC... : concatenate the units and compile them into build/OUT
compile() {
	out=build/$1; shift
	rm -f "$out" "$out.tmp"
	if ! cat "$@" | build/omc > "$out.tmp"; then rm -f "$out.tmp"; exit 1; fi
	chmod +x "$out.tmp"
	mv "$out.tmp" "$out"
	echo "$out"
}
compile w0 w0.om
compile fwprep gsp/sha2.om gsp/inflate.om gsp/fw.om gsp/bindata.om fwprep.om
