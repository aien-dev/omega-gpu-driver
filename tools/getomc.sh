#!/bin/sh
# getomc.sh -- make build/omc: birth the pinned Omega compiler from seed-0 in a clean checkout
# of omega-mv at OMEGA_COMMIT, then refuse it unless its sha256 is OMC_SHA256.
# Reuses $AIEN_OMC when it already has the pinned hash.
set -eu
R=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
. "$R/tools/omc.pin"
mkdir -p "$R/build"
ok() { [ -x "$1" ] && [ "$(sha256sum "$1" | cut -d' ' -f1)" = "$OMC_SHA256" ]; }
if ok "$R/build/omc"; then exit 0; fi
if [ -n "${AIEN_OMC:-}" ] && ok "$AIEN_OMC"; then cp "$AIEN_OMC" "$R/build/omc"; exit 0; fi
S="$R/build/omega-src"
if [ ! -d "$S/.git" ]; then git clone -q "$OMEGA_REPO" "$S"; fi
git -C "$S" fetch -q origin "$OMEGA_COMMIT" 2>/dev/null || git -C "$S" fetch -q origin
git -C "$S" checkout -q --detach "$OMEGA_COMMIT"
(cd "$S" && sh seed/omega-from-seed.sh >/dev/null)
ok "$S/seed/out/omc" || { echo "getomc: omc hash is not the pin" >&2; exit 1; }
cp "$S/seed/out/omc" "$R/build/omc"
