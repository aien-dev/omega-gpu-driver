#!/bin/sh
# build.sh -- birth the pinned omc (tools/getomc.sh) and compile w0.om into build/w0.
# A failed compile leaves no build/w0 behind.
set -eu
R=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
cd "$R"
sh tools/getomc.sh
rm -f build/w0 build/w0.tmp
if ! build/omc < w0.om > build/w0.tmp; then rm -f build/w0.tmp; exit 1; fi
chmod +x build/w0.tmp
mv build/w0.tmp build/w0
echo build/w0
