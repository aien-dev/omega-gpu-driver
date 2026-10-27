#!/bin/sh
# window/d2-run.sh --go D2|D3 -- W2..W7, run by the boot unit after the reboot that d2-pre.sh --go started.
# Status: NOT_RUN.
#   W2 state "restore" and remove the hold-back file FIRST (any later reboot is a normal one that ends in R),
#      check no nvidia module, kernel.panic=10 + panic_on_oops=1 (an oops reboots into R), bind vfio-pci
#   W3 runtime PM on and active, build/w0 (config identity, BOOT_0/BOOT_1/BOOT_42, read-only), build/ogd ident
#   D2: W4 build/ogd boot   (GSP boot through SEC2 to INIT_DONE, static info, unload)
#       W5 build/ogd hello  (objects, channel, one semaphore release, teardown)
#   D3: W6 build/ogd exec -- <CUDApp gate>   (needs ogd 'exec' and CUDApp's aien provider; NOT_RUN without them)
#   Each driver step runs only if build/ogd lists it under 'modes'; otherwise it is logged NOT_RUN.
#   W7 unbind vfio-pci (releasing the device SBRs root port 000f:00:00.0, which resets the GPU), clear
#      driver_override, power/control=auto,
#      then by default reboot (the boot unit runs R), or, if W1 was given RESTORE_PATH=rebind (window/restore-path),
#      run window/d2-restore.sh --go now (modprobe nvidia, bind; reboot fallback once).
# Any failure: the EXIT trap does W7. No privilege is granted: /dev/vfio/$GRP stays root 0600 and the
# driver programs run as root through sudo -n.
set -eu
R=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
. "$R/window/common.sh"
LOG=$LOGDIR/d2-$(date -u +%Y%m%dT%H%M%SZ)-run.log
[ "${1:-}" = --go ] || { echo "usage: $0 --go D2|D3 (window only)"; exit 2; }
STAGE=${2:-}
case $STAGE in D2 | D3) ;; *) echo "usage: $0 --go D2|D3"; exit 2 ;; esac

# W2 -------------------------------------------------------------------------
release() {
	rc=$?
	trap - EXIT
	log "W7 release (rc=$rc)"
	if [ "$(drv)" = vfio-pci ]; then echo "$BDF" | sudo -n tee "$PCI/drivers/vfio-pci/unbind" >/dev/null || true; fi
	echo | sudo -n tee "$DEV/driver_override" >/dev/null || true
	pm_auto
	log "W7 driver=$(drv) override='$(cat "$DEV/driver_override")' power=$(cat "$DEV/power/control")"
	if [ "$(cat "$RPATH" 2>/dev/null || true)" = rebind ]; then
		board "$STAGE run ended rc=$rc, log $LOG; restoring by rebind (reboot fallback inside d2-restore)"
		exec sh "$R/window/d2-restore.sh" --go
	fi
	board "$STAGE run ended rc=$rc, log $LOG; rebooting into the normal nvidia boot; the boot unit runs R"
	sync
	sudo -n systemctl reboot
}
# From here on every exit, including a refusal below, goes through W7 and ends in R.
echo restore > "$STATE"
trap release EXIT
sudo -n rm -f "$HOLD"
[ ! -e "$HOLD" ] && log "W2 ($STAGE) state 'restore'; hold-back removed: the next boot loads nvidia again and runs R" ||
	die "could not remove $HOLD (R0 removes it after the reboot)"
need_approval
exec 9>>"$GB10_LOCK"
flock -n 9 || die "$GB10_LOCK is held: something started a GPU job after the reboot"
if [ "$(nv_modules)" -ne 0 ]; then die "nvidia is loaded: the hold-back did not take"; fi


sudo -n sysctl -q kernel.panic=10 kernel.panic_on_oops=1
log "kernel.panic=10 panic_on_oops=1 (saved values in $SAVED, R puts them back)"
# Run one driver program, keep its output in the log, fail the window step on its exit code.
run_logged() {
	o=$("$@" 2>&1) && rc=0 || rc=$?
	printf '%s\n' "$o" | tee -a "$LOG"
	[ "$rc" -eq 0 ] || die "$* exit $rc"
}
has_mode() { [ -x "$BUILD/ogd" ] && "$BUILD/ogd" modes 2>/dev/null | grep -qx "$1"; }

sudo -n modprobe vfio-pci
ischr "$VFIODEV/vfio" || die "/dev/vfio/vfio missing"
echo vfio-pci | sudo -n tee "$DEV/driver_override" >/dev/null
echo "$BDF" | sudo -n tee "$PCI/drivers_probe" >/dev/null
[ "$(drv)" = vfio-pci ] || die "driver is $(drv), not vfio-pci"
ischr "$VFIODEV/$GRP" || die "/dev/vfio/$GRP missing"
m=$(stat -c '%U:%G:%a' "$VFIODEV/$GRP")
[ "$m" = root:root:600 ] || die "/dev/vfio/$GRP is $m, expected root:root:600"
log "W2 PASS: $BDF on vfio-pci, /dev/vfio/$GRP root:root:600 (programs run as root via sudo -n)"

# W3 -------------------------------------------------------------------------
pm_on
run_logged sudo -n "$BUILD/w0" "$BDF" "$GRP"
if has_mode ident; then
	pm_on
	run_logged sudo -n "$BUILD/ogd" ident "$BDF" "$GRP" "$FW" "$BUILD/fw"
fi
log "W3 PASS: identity read (BOOT_42 above settles the chip id)"

# W4..W6 ----------------------------------------------------------------------
if [ "$STAGE" = D2 ]; then steps="boot hello"; else steps="exec"; fi
for step in $steps; do
	if ! has_mode "$step"; then
		log "W-$step NOT_RUN: build/ogd has no '$step' mode"
		continue
	fi
	pm_on
	log "W-$step start"
	if [ "$step" = exec ]; then
		D3_CMD=$(cat "$LOGDIR/d3-cmd" 2>/dev/null || true)
		[ -n "$D3_CMD" ] || die "D3 needs $LOGDIR/d3-cmd (the CUDApp gate command line, written by d2-pre.sh --go D3)"
		# shellcheck disable=SC2086
		run_logged sudo -n "$BUILD/ogd" exec "$BDF" "$GRP" "$FW" "$BUILD/fw" -- $D3_CMD
	else
		run_logged sudo -n "$BUILD/ogd" "$step" "$BDF" "$GRP" "$FW" "$BUILD/fw"
	fi
	log "W-$step PASS"
done
log "W7 release"
# the EXIT trap does W7
