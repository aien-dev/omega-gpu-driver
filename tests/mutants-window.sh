#!/bin/sh
# tests/mutants-window.sh -- each mutant removes one safety step from a copy of window/*.sh; tests/window_sim.sh
# must then fail. Test-only shell; evidence label EXERCISED (host simulator).
set -eu
R=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
W=$(mktemp -d /tmp/owndriver-window-mut.XXXXXX)
killed=0
total=0
# file@sed expression@what the mutant removes
MUTANTS='common.sh@s/^need_approval() {$/need_approval() { return 0/@approval check
common.sh@s/^privcheck() {$/privcheck() { return 0/@privilege check
common.sh@/\[ "$s" = active \] || die/d@runtime PM active check
d2-pre.sh@s/^flock -n 9 || die/true || die/@W1 chip lock
d2-pre.sh@s/^trap .abort_w1. EXIT$/:/@W1 abort trap
d2-pre.sh@s/^\tif cmp -s "$SNAP.now" "$SNAP.want"; then$/\tif true; then/@W0 launch record check
d2-pre.sh@s/^\[ "$STAGE" = D2 \] || \[ -x "$BUILD\/ogd" \] ||/true ||/@D3 needs ogd
d2-pre.sh@s/^\t(cd "$BUILD\/fw" .* sha256sum -c --quiet .*) ||$/\ttrue ||/@W0 build\/fw hash check
d2-run.sh@s/^echo restore > "$STATE"$/:/@W2 state=restore before acting
d2-run.sh@s/^flock -n 9 || die/true || die/@W2 chip lock
d2-run.sh@/^\[ "$m" = root:root:600 \] || die/d@W2 /dev/vfio mode check
d2-run.sh@s/^\tpm_auto$/\t:/@W7 power\/control=auto
d2-restore.sh@s/^fallback() {$/fallback() { die "$*"/@R1 reboot fallback
d2-restore.sh@s/^\tif \[ -e "$FALLBACK" \]; then$/\tif false; then/@R1 fallback only once
d2-restore.sh@s/^\tsudo -n sysctl -q -p "$SAVED" || die/\ttrue || die/@R2 sysctl restore
d2-restore.sh@s/^sudo -n rm -f "$UNIT"$/:/@R4 unit removal
d2-restore.sh@s/^rm -f "$LIVE_MARKER" "$APPROVAL"/rm -f "$LIVE_MARKER"/@R4 approval removal
d2-boot.sh@s/^\tsudo -n rm -f "$UNIT"$/\t:/@stale unit removal'
printf '%s\n' "$MUTANTS" > "$W/list"
while IFS='@' read -r f expr what; do
	total=$((total + 1))
	M=$W/m$total
	mkdir -p "$M/build"
	cp -r "$R/window" "$R/tools" "$R/tests" "$M/"
	ln -s "$R/build/omc" "$M/build/omc"
	sed -i "$expr" "$M/window/$f"
	if cmp -s "$R/window/$f" "$M/window/$f"; then
		echo "BROKEN mutant $total ($what): sed did not change window/$f"
		rm -rf "$W"
		exit 2
	fi
	if SIMDIR=$W/sim$total sh "$M/tests/window_sim.sh" > "$W/out$total" 2>&1; then
		echo "SURVIVED $total: $what ($f)"
	else
		killed=$((killed + 1))
		echo "killed   $total: $what ($f): $(tail -1 "$W/out$total" | sed 's/.*in://')"
	fi
	for s in "$W"/sim$total/*/st/35b; do [ -s "$s" ] && kill "$(cat "$s")" 2>/dev/null || true; done
done < "$W/list"
rm -rf "$W"
echo "mutants-window: $killed/$total killed"
[ "$killed" -eq "$total" ]
