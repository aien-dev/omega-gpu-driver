#!/bin/sh
# window/d2-pre.sh -- W0 and W1 of the OwnDriver window. Status: W0 EXERCISED read-only on the host; W1 NOT_RUN.
#   no argument:     W0, read-only checks, safe while the 35B runs. Changes nothing except its own log.
#   --go [D2|D3]:    W1, needs $APPROVAL. Stops the 35B on 18091, writes the one-boot nvidia hold-back file and the
#                    boot unit, sets state "run D2" (default) or "run D3", reboots. The unit then runs W2.. by itself
#                    (window/d2-run.sh), and after the second reboot R (window/d2-restore.sh).
# Abort before the reboot: the window files are removed and window/d2-restore.sh restarts the 35B.
set -eu
R=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
. "$R/window/common.sh"
LOG=$LOGDIR/d2-$(date -u +%Y%m%dT%H%M%SZ)-pre.log
GO=${1:-}
STAGE=${2:-D2}

log "W0 checks (repo $(git -C "$R" rev-parse HEAD 2>/dev/null || echo no-git), dirty files: $(git -C "$R" status --porcelain 2>/dev/null | wc -l))"
echo "$FW_SHA  $FW" | sha256sum -c --quiet || die "firmware sha256 mismatch"
log "firmware $FW sha256 ok"
for f in $HASHED; do
	if [ -e "$R/$f" ]; then log "sha256 $(sha256sum "$R/$f" | cut -c1-64) $f"; else log "missing $f"; fi
done
omc_pin=$(sed -n 's/^OMC_SHA256=//p' "$R/tools/omc.pin")
[ "$(sha256sum "$R/build/omc" | cut -c1-64)" = "$omc_pin" ] || die "build/omc does not match tools/omc.pin"
[ -x "$BUILD/w0" ] || die "build/w0 missing: run sh build.sh"
if [ -x "$BUILD/ogd" ]; then
	log "ogd modes: $("$BUILD/ogd" modes | tr '\n' ' ')"
	if [ -e "$R/build/fw/fw.manifest" ]; then
		(cd "$R/build/fw" && sed -n 's/^sha256 \([0-9a-f]\{64\}\) \([a-z.]*\)$/\1  \2/p' fw.manifest | sha256sum -c --quiet) ||
			die "build/fw files do not match build/fw/fw.manifest: rerun sh build.sh"
		log "build/fw matches fw.manifest"
	fi
fi
[ "$(cat "$DEV/vendor"):$(cat "$DEV/device")" = 0x10de:0x2e12 ] || die "$BDF is not 10de:2e12"
[ "$(basename "$(readlink "$DEV/iommu_group")")" = "$GRP" ] || die "iommu group is not $GRP"
[ "$(ls "$IOMMU/$GRP/devices")" = "$BDF" ] || die "group $GRP is not $BDF alone"
log "device $(cat "$DEV/vendor"):$(cat "$DEV/device") driver=$(drv) reset_method=$(cat "$DEV/reset_method") power=$(cat "$DEV/power/control")/$(cat "$DEV/power/runtime_status")"
log "modules: $(lsmod | awk '/^nvidia/{printf "%s(%s) ", $1, $3}')"
log "cmdline: $(cat /proc/cmdline)"
log "sysctl: kernel.panic=$(sysctl -n kernel.panic) kernel.panic_on_oops=$(sysctl -n kernel.panic_on_oops)"
for f in "$HOLD" "$UNIT" "$STATE"; do
	[ ! -e "$f" ] || die "$f already exists (an earlier window did not finish): run window/d2-restore.sh --go"
done
# No window is open (checked above), so the current privilege state is the baseline R4 must return to.
if [ -e "$PRIVBASE" ]; then
	privstate | diff "$PRIVBASE" - | sed 's/^/baseline change since last W0: /' | tee -a "$LOG" || true
fi
privstate > "$PRIVBASE"
log "privilege baseline: $(wc -l < "$PRIVBASE") entries in $PRIVBASE (sha256 $(sha256sum "$PRIVBASE" | cut -c1-64))"
privcheck || die "privilege state not clean before the window (see PRIV lines)"
log "privilege state clean: /dev/vfio groups root 0600, no vfio udev/memlock file, user not in group vfio, no driver_override, no window files"
# nvgrace-gpu-vfio-pci (the upstream variant for Grace C2C GPUs) must not claim this device: plain vfio-pci.
if modinfo nvgrace-gpu-vfio-pci 2>/dev/null | grep -qi 'd00002E12'; then
	die "nvgrace-gpu-vfio-pci now lists 2E12: re-decide variant vs plain vfio-pci before binding"
fi
log "nvgrace-gpu-vfio-pci aliases ($(modinfo nvgrace-gpu-vfio-pci 2>/dev/null | grep -c '^alias')) do not list 10de:2e12: plain vfio-pci"
if lsinitramfs "/boot/initrd.img-$(uname -r)" | grep -Eq '/nvidia(_uvm|_modeset|_drm)?\.ko'; then
	die "initramfs carries nvidia.ko: a modprobe.d hold-back would not be enough"
fi
log "initramfs has no nvidia/nvidia_uvm/nvidia_modeset/nvidia_drm"
modinfo -n vfio-pci >/dev/null 2>&1 || die "vfio-pci module not available"
p=$(live_pid)
if [ -n "$p" ]; then
	snap35b "$p" > "$SNAP.now"
	snap_expected > "$SNAP.want"
	if cmp -s "$SNAP.now" "$SNAP.want"; then
		mv "$SNAP.now" "$SNAP"; rm -f "$SNAP.want"
		log "35B pid $p: launch record equals the restore recipe ($SNAP)"
	else
		diff "$SNAP.want" "$SNAP.now" | tee -a "$LOG" || true
		die "the live 35B was not started the way d2-restore.sh restarts it: update snap_expected and R3 first"
	fi
else
	log "35B not running (restore will start it from the recipe)"
fi
log "GPU device users: $(sudo -n fuser "$ROOT"/dev/nvidia* 2>/dev/null | tr -s ' ' | tr ' ' '\n' | sort -u | while read -r q; do [ -n "$q" ] && printf '%s(%s) ' "$q" "$(cat "$PROC/$q/comm" 2>/dev/null)"; done)"
log "chip lock (read from the kernel lock table, not taken): $(spark-window locks gb10 2>&1 | head -2 | tr '\n' ' ')"

if [ "$GO" != --go ]; then
	log "W0 PASS (checks only; nothing changed)"
	exit 0
fi

# W1 --------------------------------------------------------------------------
case $STAGE in D2 | D3) ;; *) die "stage must be D2 or D3" ;; esac
need_approval
# build/ogd is optional: without it the window runs W2, W3 (build/w0), W7 and R, and logs the driver steps NOT_RUN.
[ "$STAGE" = D2 ] || [ -x "$BUILD/ogd" ] || die "D3 needs build/ogd with an 'exec' mode"
case ${RESTORE_PATH:-reboot} in
reboot) rm -f "$RPATH" ;;
rebind) echo rebind > "$RPATH" ;;
*) die "RESTORE_PATH must be reboot or rebind" ;;
esac
log "restore path after W7: ${RESTORE_PATH:-reboot}"
if [ "$STAGE" = D3 ]; then
	[ -n "${D3_CMD:-}" ] || die "D3 needs D3_CMD: the CUDApp gate command line (window/README.md, D3)"
	printf '%s\n' "$D3_CMD" > "$LOGDIR/d3-cmd"
	log "D3 command: $D3_CMD"
fi
# The chip lock: no other GPU job may be running; it is held until the reboot ends this process.
exec 9>>"$GB10_LOCK"
flock -n 9 || die "$GB10_LOCK is held by another GPU job: wait for it"
abort_w1() {
	rc=$?
	trap - EXIT
	[ "$rc" -eq 0 ] && return
	sudo -n systemctl disable aien-owndriver-window.service >/dev/null 2>&1 || true
	sudo -n rm -f "$HOLD" "$UNIT"
	sudo -n systemctl daemon-reload || true
	echo restore > "$STATE"
	log "W1 aborted before reboot (rc=$rc); window files removed; restoring the 35B"
	sh "$R/window/d2-restore.sh" --go || true
}
trap 'abort_w1' EXIT

touch "$LIVE_MARKER"
board "WINDOW OPEN $STAGE (own driver): stopping 18091, reboot with nvidia held back; every agent session on the Spark ends at the reboot. Log $LOG"
p=$(live_pid)
if [ -n "$p" ]; then
	log "TERM 35B pid $p"
	kill -TERM "$p"
fi
i=0
while [ -n "$(live_pid)" ] || [ -n "$(nvidia-smi --query-compute-apps=pid --format=csv,noheader)" ]; do
	i=$((i + 1)); [ "$i" -le 60 ] || die "the 35B or another compute app is still on the GPU after 60 s"
	sleep 1
done
log "no compute apps on the GPU"
printf 'kernel.panic=%s\nkernel.panic_on_oops=%s\n' "$(sysctl -n kernel.panic)" "$(sysctl -n kernel.panic_on_oops)" > "$SAVED"
sudo -n tee "$HOLD" >/dev/null <<'EOF'
# aien OwnDriver window: hold the nvidia modules back for ONE boot.
# window/d2-run.sh deletes this file first thing after the reboot; if it is still here, delete it and reboot.
blacklist nvidia
blacklist nvidia_uvm
blacklist nvidia_modeset
blacklist nvidia_drm
install nvidia /bin/false
install nvidia_uvm /bin/false
install nvidia_modeset /bin/false
install nvidia_drm /bin/false
EOF
sudo -n cp "$R/window/aien-owndriver-window.service" "$UNIT"
sudo -n chmod 0644 "$UNIT"
sudo -n systemctl daemon-reload
sudo -n systemctl enable aien-owndriver-window.service
echo "run $STAGE" > "$STATE"
log "wrote $HOLD, installed and enabled $UNIT, state 'run $STAGE'"
trap - EXIT
board "$STAGE W1: rebooting with nvidia held back; the boot unit runs window/d2-run.sh, then R after the next reboot"
sync
log "reboot"
sudo -n systemctl reboot
