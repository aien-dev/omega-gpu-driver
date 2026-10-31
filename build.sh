#!/bin/sh
# build.sh -- birth the pinned omc (tools/getomc.sh) and compile w0.om into build/w0 and the firmware
# input tool (gsp/sha2.om gsp/inflate.om gsp/fw.om gsp/bindata.om fwprep.om) into build/fwprep.
# With OGKM=<open-gpu-kernel-modules-580.173.02 checkout>, it then runs build/fwprep on the installed
# GSP firmware into build/fw (checked by window/d2-pre.sh against build/fw/fw.manifest).
# A failed step leaves no output behind.
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
FW=${FW:-/lib/firmware/nvidia/580.173.02/gsp_ga10x.bin}
if [ -n "${OGKM:-}" ]; then
	rm -rf build/fw build/fw.tmp
	mkdir build/fw.tmp
	if ! build/fwprep "$FW" "$OGKM" build/fw.tmp > build/fwprep.log; then
		rm -rf build/fw.tmp; cat build/fwprep.log >&2; exit 1
	fi
	mv build/fw.tmp build/fw
	echo build/fw
else
	echo "build/fw not built: set OGKM to an open-gpu-kernel-modules 580.173.02 checkout" >&2
fi
