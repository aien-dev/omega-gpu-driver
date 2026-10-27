# window/common.sh -- shared settings for the OwnDriver window scripts. Sourced, never run.
# Status: NOT_RUN on the GB10; window/README.md has the procedure. tests/window_sim.sh runs these exact
# scripts against a simulated machine under /tmp (OWNDRIVER_WINDOW_ROOT, below).
BDF=000f:01:00.0
GRP=20
FW=/lib/firmware/nvidia/580.173.02/gsp_ga10x.bin
FW_SHA=32cb7cf3e77f97e92f6e92135939ccb3ba382748144569c0dfccf3338d43d963

# ROOT is empty on the Spark. tests/window_sim.sh sets it to a simulated machine: every system path below
# moves under it, and the commands that act on the machine must be that simulator's shims (checked here,
# so a half-set-up simulation can never reach the real sudo, systemctl or the live 35B).
ROOT=${OWNDRIVER_WINDOW_ROOT:-}
if [ -n "$ROOT" ]; then
	case $ROOT in /tmp/*) ;; *) echo "OWNDRIVER_WINDOW_ROOT must be under /tmp" >&2; exit 2 ;; esac
	[ -e "$ROOT/.owndriver-window-sim" ] || { echo "$ROOT is not a window simulator root" >&2; exit 2; }
	for c in sudo systemctl modprobe sysctl lsmod nvidia-smi pgrep curl tee stat fuser modinfo lsinitramfs spark-window; do
		[ "$(command -v "$c")" = "$ROOT/bin/$c" ] || { echo "simulator: $c is not $ROOT/bin/$c" >&2; exit 2; }
	done
	HOMEDIR=$ROOT/home
	Q36=$ROOT/q36
	Q36_KEY=$ROOT/q36/KEY
	BUILD=$ROOT/build
else
	HOMEDIR=/home/drakestapleton
	Q36=/home/drakestapleton/.local/state/aien-q36
	Q36_KEY=/home/drakestapleton/.local/state/aien-coordinator/KEY
	BUILD=$R/build
fi
Q36_BIN=bin-19173f9e
PCI=$ROOT/sys/bus/pci
DEV=$PCI/devices/$BDF
IOMMU=$ROOT/sys/kernel/iommu_groups
VFIODEV=$ROOT/dev/vfio
PROC=$ROOT/proc
ETC=$ROOT/etc
# Window files. Each exists only between W1 and R; privcheck fails if one persists.
HOLD=$ETC/modprobe.d/zz-aien-owndriver-window.conf
UNIT=$ETC/systemd/system/aien-owndriver-window.service
LIVE_MARKER=$ROOT/tmp/aien-q36-live-down-for-tests
GB10_LOCK=$ROOT/tmp/aien-gb10.lock
BOARD=$HOMEDIR/handoffs/BOARD.md
LOGDIR=$HOMEDIR/handoffs/OwnDriver/window
# /tmp is emptied at every boot (tmpfiles "D /tmp"), so the approval and the state live with the logs.
APPROVAL=$LOGDIR/APPROVED
# STATE holds one line between reboots: "run D2|D3" (W2.. pending), "restore" (R pending). SAVED keeps the
# sysctl values W2 changes; SNAP is the live 35B launch record W0 checks the restore recipe against;
# RPATH holds "rebind" if W1 was asked for RESTORE_PATH=rebind; PRIVBASE is the privilege baseline (W0).
STATE=$LOGDIR/state
SAVED=$LOGDIR/saved-sysctl
SNAP=$LOGDIR/live-35b.snapshot
RPATH=$LOGDIR/restore-path
PRIVBASE=$LOGDIR/priv-baseline
mkdir -p "$LOGDIR"

utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }
log() { echo "$(utc) $*" | tee -a "$LOG"; }
board() { echo "$(utc) OwnDriver: $*" >> "$BOARD"; }
die() { log "ABORT: $*"; exit 1; }
# A character device on the Spark; the simulator cannot create device nodes and uses plain files.
ischr() { if [ -n "$ROOT" ]; then [ -e "$1" ]; else [ -c "$1" ]; fi; }

# The approval file (Main writes it when Drake opens the window) must carry these lines:
#   window: <Drake's words / BOARD line ref>
#   reset: approved      -- vfio-pci FLRs the GPU on open and bus-resets (SBR) root port 000f:00:00.0 on release
#   reboot: approved     -- W1 and W7 reboot the Spark; every agent session on it ends
need_approval() {
	[ -s "$APPROVAL" ] || die "no $APPROVAL (Main writes it when Drake opens the window)"
	grep -q '^window: ..*' "$APPROVAL" || die "$APPROVAL lacks a 'window: <Drake's words>' line"
	grep -qx 'reset: approved' "$APPROVAL" || die "$APPROVAL lacks 'reset: approved' (VFIO bind/release resets the GPU)"
	grep -qx 'reboot: approved' "$APPROVAL" || die "$APPROVAL lacks 'reboot: approved' (the window reboots the Spark twice)"
	log "approval: $(grep '^window: ' "$APPROVAL" | head -1)"
}

# Every file that can grant device, root or memlock rights, with its sha256, plus the user's groups.
privstate() {
	for d in "$ETC/sudoers.d" "$ETC/udev/rules.d" "$ETC/security/limits.d" "$ETC/modprobe.d"; do
		for f in "$d"/*; do
			[ -e "$f" ] && echo "$(sudo -n sha256sum "$f" | cut -c1-64) $(stat -c '%U:%G:%a' "$f") $f"
		done
	done
	echo "groups $(id -nG "$(id -un)" | tr ' ' '\n' | sort | tr '\n' ' ')"
}

# Privilege state outside the window. No udev rule, group, sudoers line, memlock limit or /dev/vfio
# permission change is ever made: the window programs run as root through sudo -n instead. Fails closed
# if the privilege files differ from the W0 baseline, or a window file (HOLD, UNIT) or a driver_override persists.
privcheck() {
	bad=0
	for f in "$VFIODEV"/[0-9]*; do
		[ -e "$f" ] || continue
		m=$(stat -c '%U:%G:%a' "$f")
		[ "$m" = root:root:600 ] || { log "PRIV: $f is $m, expected root:root:600"; bad=1; }
	done
	# Pre-existing files (e.g. /etc/sudoers.d/aien-local-ci, 2026-10-19, not this lane's) are compared against the
	# baseline W0 records before the window opens: anything added, removed or changed since then fails.
	privstate > "$PRIVBASE.now"
	if [ -e "$PRIVBASE" ] && ! cmp -s "$PRIVBASE" "$PRIVBASE.now"; then
		diff "$PRIVBASE" "$PRIVBASE.now" | sed 's/^/PRIV: /' | tee -a "${LOG:-/dev/null}"
		bad=1
	fi
	for f in "$ETC"/udev/rules.d/*vfio* "$ETC"/security/limits.d/*memlock* "$HOLD" "$UNIT"; do
		[ -e "$f" ] && { log "PRIV: $f exists"; bad=1; }
	done
	id -nG | tr ' ' '\n' | grep -qx vfio && { log "PRIV: $(id -un) is in group vfio"; bad=1; }
	o=$(cat "$DEV/driver_override" 2>/dev/null || true)
	[ -z "$o" ] || [ "$o" = "(null)" ] || { log "PRIV: driver_override=$o"; bad=1; }
	return $bad
}

# The 35B serving process on 18091, if any (empty when down).
live_pid() { pgrep -f -- '--port 18091' | head -1 || true; }

# The restore recipe (d2-restore.sh R3) must equal how the live server was started. Prints the record:
# argv, cwd and the env names it needs; the coordinator key is compared, never written.
snap35b() {
	p=$1
	echo "argv $(tr '\0' ' ' < "$PROC/$p/cmdline")"
	echo "cwd $(readlink "$PROC/$p/cwd")"
	tr '\0' '\n' < "$PROC/$p/environ" | grep -E '^(Q36_BATCH_BIN|AIEN_Q36_STROKE|AIEN_SERVE_GPU_LOCK)=' | sort | sed 's/^/env /'
	k=$(tr '\0' '\n' < "$PROC/$p/environ" | sed -n 's/^AIEN_COORD_KEY=//p')
	if [ -n "$k" ] && [ "$k" = "$(cat "$Q36_KEY")" ]; then echo "env AIEN_COORD_KEY=<equals KEY>"; else echo "env AIEN_COORD_KEY=<MISMATCH>"; fi
}
snap_expected() {
	echo "argv ./aien-serve-http --engine omega --model-dir /home/drakestapleton/models/qwen3.6-35b-a3b-fp8-95a723d0 --port 18091 --max-context 49152 --max-tokens-cap 16384 --thinking off --batch-slots 8 "
	echo "cwd $Q36/$Q36_BIN"
	echo "env AIEN_Q36_STROKE=1"
	echo "env AIEN_SERVE_GPU_LOCK=/tmp/aien-serve-18091.lock"
	echo "env Q36_BATCH_BIN=$Q36_BIN"
	echo "env AIEN_COORD_KEY=<equals KEY>"
}

# Runtime PM on and active before any BAR0 access (arm64: a read of a D3 device is an external abort).
pm_on() {
	echo on | sudo -n tee "$DEV/power/control" >/dev/null
	s=$(cat "$DEV/power/runtime_status")
	[ "$s" = active ] || die "runtime_status=$s, not active"
	log "power/control=on runtime_status=active"
}
pm_auto() { echo auto | sudo -n tee "$DEV/power/control" >/dev/null || true; }

drv() { basename "$(readlink "$DEV/driver" 2>/dev/null || echo none)"; }
nv_modules() { lsmod | grep -cE '^nvidia(_uvm|_modeset|_drm)? ' || true; }

# Files whose sha256 W0 records and WINDOW-READY posts.
HASHED="window/common.sh window/d2-pre.sh window/d2-boot.sh window/d2-run.sh window/d2-restore.sh window/aien-owndriver-window.service tools/omc.pin build/omc build/w0 build/ogd build/fw/fw.manifest"
