#!/bin/sh
# window/d2-restore.sh --go -- R: bring the resident 35B back on 18091 under nvidia.ko and remove every window
# file. Status: NOT_RUN. Runs from the boot unit after the reboot that W7 ends with, directly from W7
# (RESTORE_PATH=rebind), or from the W1 abort path. Safe to run again: each part checks before it acts.
#   R0 hold-back file still present: remove it and reboot (the unit runs R again)
#   R1 nvidia.ko back: unbind vfio-pci, clear driver_override, modprobe, bind, nvidia-smi lists the GB10.
#      Whether nvidia.ko re-initialises GSP after the FLR/bus reset of the vfio-pci release is NOT_RUN on this
#      chip, so any failure takes the reboot fallback once (state stays "restore", the unit runs R again).
#   R2 nvidia-persistenced running; kernel.panic / panic_on_oops back to the values W1 saved
#   R3 the 35B restarted exactly as it was started (W0 checked window/live-35b.snapshot against this recipe),
#      /v1/models lists qwen, one greedy chat, exactly one aien-serve-http on the GPU
#   R4 boot unit removed, privilege state clean, markers removed, BOARD line
set -eu
R=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
. "$R/window/common.sh"
LOG=$LOGDIR/d2-$(date -u +%Y%m%dT%H%M%SZ)-restore.log
[ "${1:-}" = --go ] || { echo "usage: $0 --go"; exit 2; }
echo restore > "$STATE"
# Any refusal leaves state "restore" and the unit in place (the next boot tries R again) and says so on BOARD.
trap 'rc=$?; [ "$rc" -eq 0 ] || board "restore STOPPED rc=$rc, 18091 may be down, log $LOG (page Main; next boot retries R)"' EXIT

# R0 -------------------------------------------------------------------------
if [ -e "$HOLD" ]; then
	sudo -n rm -f "$HOLD"
	log "R0 hold-back file was still present: removed; rebooting; the boot unit runs R again"
	board "restore: hold-back file was still present, removed, rebooting"
	sync
	sudo -n systemctl reboot
	exit 0
fi

# R1 -------------------------------------------------------------------------
FALLBACK=$LOGDIR/reboot-fallback-used
fallback() {
	if [ -e "$FALLBACK" ]; then
		board "restore FAILED after the reboot fallback: $* (page Main and Drake; GPU state unknown; log $LOG)"
		die "$* after the reboot fallback already ran"
	fi
	date -u > "$FALLBACK"
	log "R1 reboot fallback: $*; the boot unit runs R again after the reboot"
	board "restore: $*; reboot fallback, then R again from the boot unit"
	sync
	sudo -n systemctl reboot
	exit 0
}
if [ "$(drv)" = vfio-pci ]; then echo "$BDF" | sudo -n tee "$PCI/drivers/vfio-pci/unbind" >/dev/null || true; fi
echo | sudo -n tee "$DEV/driver_override" >/dev/null || true
if [ "$(nv_modules)" -ne 4 ]; then
	log "R1 nvidia modules loaded: $(nv_modules) of 4; modprobe nvidia_uvm nvidia_drm"
	timeout 180 sudo -n modprobe nvidia_uvm || fallback "modprobe nvidia_uvm failed"
	timeout 180 sudo -n modprobe nvidia_drm || fallback "modprobe nvidia_drm failed"
	[ "$(nv_modules)" -eq 4 ] || fallback "nvidia modules: $(nv_modules) of 4"
fi
if [ "$(drv)" != nvidia ]; then
	echo "$BDF" | sudo -n tee "$PCI/drivers_probe" >/dev/null || true
fi
[ "$(drv)" = nvidia ] || fallback "$BDF driver is $(drv), not nvidia"
timeout 120 nvidia-smi -L | tee -a "$LOG" | grep -q GB10 || fallback "nvidia-smi does not list the GB10"
log "R1 PASS: nvidia.ko back, 4 modules, driver bound, nvidia-smi lists the GB10"

# R2 -------------------------------------------------------------------------
systemctl is-active --quiet nvidia-persistenced || sudo -n systemctl start nvidia-persistenced || log "R2 nvidia-persistenced did not start"
if [ -s "$SAVED" ]; then
	sudo -n sysctl -q -p "$SAVED" || die "could not restore sysctl from $SAVED"
fi
log "R2 persistenced $(systemctl is-active nvidia-persistenced); kernel.panic=$(sysctl -n kernel.panic) panic_on_oops=$(sysctl -n kernel.panic_on_oops)"

# R3 -------------------------------------------------------------------------
if [ -z "$(live_pid)" ]; then
	K=$(cat "$Q36_KEY")
	Q36_BATCH_BIN=$Q36_BIN AIEN_Q36_STROKE=1 AIEN_SERVE_GPU_LOCK=/tmp/aien-serve-18091.lock AIEN_COORD_KEY="$K" \
		"$Q36/start-35b-batch.sh" | tee -a "$LOG"
fi
i=0
until curl -fsS --max-time 5 http://127.0.0.1:18091/v1/models 2>/dev/null | grep -qi qwen; do
	i=$((i + 5)); [ "$i" -le 900 ] || { board "restore: 18091 did not come up in 900 s (page Main; $Q36/serve.log)"; die "18091 did not list qwen within 900 s"; }
	sleep 5
done
log "R3 18091 /v1/models lists qwen after ~${i} s"
out=$(curl -fsS --max-time 120 http://127.0.0.1:18091/v1/chat/completions -H 'Content-Type: application/json' \
	-d '{"messages":[{"role":"user","content":"Reply with the single word: ready"}],"max_tokens":8,"temperature":0}') ||
	die "greedy chat failed"
log "R3 greedy chat: $out"
p=$(live_pid)
snap35b "$p" > "$SNAP.restored"
snap_expected | cmp -s - "$SNAP.restored" || log "R3 WARNING: restarted 35B launch record differs from the recipe (see $SNAP.restored)"
apps=$(nvidia-smi --query-compute-apps=process_name,used_memory --format=csv,noheader)
log "R3 compute apps: $apps"
[ "$(printf '%s\n' "$apps" | grep -c aien-serve-http)" -eq 1 ] || die "expected exactly one aien-serve-http on the GPU"

# R4 -------------------------------------------------------------------------
sudo -n systemctl disable aien-owndriver-window.service >/dev/null 2>&1 || true
sudo -n rm -f "$UNIT"
sudo -n systemctl daemon-reload
privcheck || { board "PRIVILEGE PERSISTED after the window, see $LOG (page Main)"; die "privilege state not clean"; }
rm -f "$LIVE_MARKER" "$APPROVAL" "$FALLBACK" "$SAVED" "$RPATH" "$LOGDIR/d3-cmd" "$STATE"
board "WINDOW CLOSED (own driver), 18091 restored ($(printf '%s' "$apps" | tr '\n' ' ')). Log $LOG"
log "R PASS"
