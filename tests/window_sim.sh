#!/bin/sh
# tests/window_sim.sh -- run the real window scripts (window/*.sh, copied unchanged) against a simulated Spark
# under /tmp: fake sysfs, /etc, /dev/vfio, /proc and shims for sudo, systemctl, modprobe, sysctl, lsmod,
# nvidia-smi, pgrep, curl, tee (sysfs side effects), stat, fuser, modinfo, lsinitramfs and spark-window. The
# "35B" is a sleep process the fake start script launches. A reboot is simulated by the harness: /tmp emptied,
# 35B gone, sysctls reset, nvidia loaded unless the hold-back file says otherwise, then the boot unit if enabled.
# Test-only shell (no product code); evidence label: EXERCISED (host simulator). Nothing here touches the GPU,
# the real /sys, /etc, sudo or the live 35B: window/common.sh refuses unless every acting command is a shim.
#   sh tests/window_sim.sh            all scenarios
#   SIMDIR=/tmp/x sh tests/window_sim.sh   keep the simulated machines in /tmp/x
set -eu
R=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
BASE=${SIMDIR:-$(mktemp -d /tmp/owndriver-window-sim.XXXXXX)}
case $BASE in /tmp/*) ;; *) echo "SIMDIR must be under /tmp"; exit 2 ;; esac
BDF=000f:01:00.0
pass=0
fail=0

# --- the simulated machine ------------------------------------------------------------------------------
mkroot() {
	S=$BASE/$1
	rm -rf "$S"
	mkdir -p "$S/bin" "$S/st/modes" "$S/repo" "$S/tmp" "$S/home/handoffs/OwnDriver/window" "$S/q36/bin-19173f9e" \
		"$S/etc/sudoers.d" "$S/etc/udev/rules.d" "$S/etc/security/limits.d" "$S/etc/modprobe.d" "$S/etc/systemd/system" \
		"$S/sys/bus/pci/devices/$BDF/power" "$S/sys/bus/pci/drivers/nvidia" "$S/sys/bus/pci/drivers/vfio-pci" \
		"$S/sys/kernel/iommu_groups/20/devices" "$S/dev/vfio" "$S/proc" "$S/build"
	touch "$S/.owndriver-window-sim"
	cp -r "$R/window" "$R/tools" "$S/repo/"
	mkdir -p "$S/repo/build"
	ln -s "$R/build/omc" "$S/repo/build/omc"
	D=$S/sys/bus/pci/devices/$BDF
	echo 0x10de > "$D/vendor"; echo 0x2e12 > "$D/device"; echo "flr bus" > "$D/reset_method"
	: > "$D/driver_override"; echo auto > "$D/power/control"; echo active > "$D/power/runtime_status"
	ln -s ../../../../kernel/iommu_groups/20 "$D/iommu_group"
	touch "$S/sys/kernel/iommu_groups/20/devices/$BDF" "$S/sys/bus/pci/drivers_probe" \
		"$S/sys/bus/pci/drivers/vfio-pci/unbind" "$S/sys/bus/pci/drivers/nvidia/unbind"
	echo "drakestapleton ALL=(root) NOPASSWD: /usr/local/sbin/aien-run-exec" > "$S/etc/sudoers.d/aien-local-ci"
	echo "options nvidia NVreg_Example=1" > "$S/etc/modprobe.d/nvidia.conf"
	echo simkey > "$S/q36/KEY"
	echo 0 > "$S/st/sysctl.kernel.panic"; echo 0 > "$S/st/sysctl.kernel.panic_on_oops"
	echo 0 > "$S/st/boots"; : > "$S/st/events"
	printf 'window: sim\nreset: approved\nreboot: approved\n' > "$S/home/handoffs/OwnDriver/window/APPROVED"
	shims "$S"
	cat > "$S/q36/start-35b-batch.sh" <<'EOF'
#!/bin/sh
# fake start-35b-batch.sh: a sleep stands in for aien-serve-http; its launch record goes to $ROOT/proc/<pid>.
S=${OWNDRIVER_WINDOW_ROOT:?}
[ -e "$S/st/start_fail" ] && { echo "start failed"; exit 1; }
nohup sleep 100000 >/dev/null 2>&1 &
p=$!
mkdir -p "$S/proc/$p"
printf '%s\0' ./aien-serve-http --engine omega --model-dir /home/drakestapleton/models/qwen3.6-35b-a3b-fp8-95a723d0 --port 18091 \
	--max-context 49152 --max-tokens-cap 16384 --thinking off --batch-slots 8 > "$S/proc/$p/cmdline"
printf 'Q36_BATCH_BIN=%s\0AIEN_Q36_STROKE=%s\0AIEN_SERVE_GPU_LOCK=%s\0AIEN_COORD_KEY=%s\0HOME=x\0' \
	"${Q36_BATCH_BIN:-}" "${AIEN_Q36_STROKE:-}" "${AIEN_SERVE_GPU_LOCK:-}" "${AIEN_COORD_KEY:-}" > "$S/proc/$p/environ"
ln -s "$S/q36/${Q36_BATCH_BIN:-bin-99230310}" "$S/proc/$p/cwd"
echo aien-serve-http > "$S/proc/$p/comm"
echo "$p" > "$S/st/35b"
echo "start35b $p" >> "$S/st/events"
echo "pid $p"
EOF
	chmod +x "$S/q36/start-35b-batch.sh"
	cat > "$S/build/w0" <<'EOF'
#!/bin/sh
# fake build/w0: refuses unless the device is on vfio-pci, powered on and active, as the real one needs.
S=${OWNDRIVER_WINDOW_ROOT:?}
D=$S/sys/bus/pci/devices/000f:01:00.0
echo "w0 $*" >> "$S/st/events"
[ "$(basename "$(readlink "$D/driver")")" = vfio-pci ] || { echo "w0: not on vfio-pci"; exit 3; }
[ "$(cat "$D/power/control")" = on ] && [ "$(cat "$D/power/runtime_status")" = active ] || { echo "w0: device not powered"; exit 4; }
[ -e "$S/st/w0_leak" ] && echo 'SUBSYSTEM=="vfio", MODE="0666"' > "$S/etc/udev/rules.d/99-vfio.rules"
if [ -e "$S/st/w0_crash" ]; then
	echo crash >> "$S/st/events"; touch "$S/st/reboot"
	pkill -KILL -f "$S/repo/window/d2-run.sh"
	exit 9
fi
echo "BOOT_0 0x1b000000 BOOT_42 0x1b000000 (simulated)"
exit "$(cat "$S/st/w0_rc" 2>/dev/null || echo 0)"
EOF
	chmod +x "$S/build/w0"
	boot_power_on "$S" 0
	start35b "$S"
}

start35b() { OWNDRIVER_WINDOW_ROOT=$1 Q36_BATCH_BIN=bin-19173f9e AIEN_Q36_STROKE=1 AIEN_SERVE_GPU_LOCK=/tmp/aien-serve-18091.lock AIEN_COORD_KEY=simkey "$1/q36/start-35b-batch.sh" >/dev/null; }

bind_nvidia() {
	S=$1; D=$S/sys/bus/pci/devices/$BDF
	rm -f "$D/driver"; ln -s ../../drivers/nvidia "$D/driver"
}

# Power-on state; $2=1 runs the boot unit afterwards.
boot_power_on() {
	S=$1
	n=$(($(cat "$S/st/boots") + 1)); echo $n > "$S/st/boots"
	echo "boot $n" >> "$S/st/events"
	if [ -s "$S/st/35b" ]; then kill "$(cat "$S/st/35b")" 2>/dev/null || true; rm -f "$S/st/35b"; fi
	rm -rf "$S/tmp" && mkdir -p "$S/tmp"
	if [ -e "$S/st/lock_after_reboot" ] && [ "$2" = 1 ]; then
		rm -f "$S/st/lock_after_reboot"
		(flock -x 9; sleep 20) 9>>"$S/tmp/aien-gb10.lock" &
		echo $! > "$S/st/lockholder"; sleep 0.3
		echo "boot: another GPU job took the chip lock" >> "$S/st/events"
	fi
	D=$S/sys/bus/pci/devices/$BDF
	rm -f "$D/driver" "$S/st/modules" "$S/st/persistenced" "$S/st/nvidia_broken" "$S/dev/vfio/vfio" "$S/dev/vfio/20"
	: > "$D/driver_override"; echo auto > "$D/power/control"
	if [ -e "$S/st/pm_suspended" ]; then echo suspended > "$D/power/runtime_status"; else echo active > "$D/power/runtime_status"; fi
	echo 0 > "$S/st/sysctl.kernel.panic"; echo 0 > "$S/st/sysctl.kernel.panic_on_oops"
	bad=$(cat "$S/st/nvidia_bad_boots" 2>/dev/null || echo 0)
	if grep -q 'install nvidia /bin/false' "$S"/etc/modprobe.d/* 2>/dev/null; then
		echo "boot: nvidia held back" >> "$S/st/events"
	elif [ "$bad" -gt 0 ] && [ "$2" = 1 ]; then
		echo $((bad - 1)) > "$S/st/nvidia_bad_boots"; touch "$S/st/nvidia_broken"
		echo "boot: nvidia failed to load (this boot)" >> "$S/st/events"
	else
		printf 'nvidia_uvm\nnvidia_drm\nnvidia_modeset\nnvidia\n' > "$S/st/modules"
		bind_nvidia "$S"; touch "$S/st/persistenced"
	fi
	if [ "$2" = 1 ] && [ -e "$S/st/unit-enabled" ] && [ -e "$S/etc/systemd/system/aien-owndriver-window.service" ]; then
		echo "unit runs" >> "$S/st/events"
		(cd "$S/repo" && OWNDRIVER_WINDOW_ROOT=$S PATH="$S/bin:$PATH" sh "$S/repo/window/d2-boot.sh") > "$S/st/unit-$n.out" 2>&1 ||
			echo "unit exit $?" >> "$S/st/events"
	fi
}

# Run a window command, then follow every reboot it asks for (at most 8 boots).
run_window() {
	S=$1; shift
	(cd "$S/repo" && OWNDRIVER_WINDOW_ROOT=$S PATH="$S/bin:$PATH" "$@") > "$S/st/cmd.out" 2>&1 && echo "cmd exit 0" >> "$S/st/events" ||
		echo "cmd exit $?" >> "$S/st/events"
	while [ -e "$S/st/reboot" ]; do
		rm -f "$S/st/reboot"
		[ "$(cat "$S/st/boots")" -lt 9 ] || { echo "boot loop" >> "$S/st/events"; return; }
		boot_power_on "$S" 1
	done
}

shims() {
	S=$1; B=$S/bin
	w() { printf '#!/bin/sh\nS=%s\nD=$S/sys/bus/pci/devices/%s\n%s\n' "$S" "$BDF" "$2" > "$B/$1"; chmod +x "$B/$1"; }
	w sudo '[ "$1" = -n ] && shift
exec "$@"'
	w systemctl 'echo "systemctl $*" >> $S/st/events
case $1 in
daemon-reload) ;;
enable) [ -e $S/st/fail_enable ] && exit 1; [ -e $S/etc/systemd/system/$2 ] && touch $S/st/unit-enabled ;;
disable) rm -f $S/st/unit-enabled ;;
is-active) [ "$2" = --quiet ] && shift; [ -e $S/st/persistenced ] || { [ "$2" = --quiet ] || echo inactive; exit 3; }; echo active ;;
start) [ -s $S/st/modules ] && touch $S/st/persistenced ;;
reboot) touch $S/st/reboot ;;
*) exit 1 ;;
esac'
	w modprobe 'echo "modprobe $*" >> $S/st/events
for m in "$@"; do case $m in
vfio-pci) grep -qx vfio_pci $S/st/modules 2>/dev/null || echo vfio_pci >> $S/st/modules; : > $S/dev/vfio/vfio; echo root:root:666 > $S/st/modes/vfio ;;
nvidia*) grep -q "install nvidia /bin/false" $S/etc/modprobe.d/* 2>/dev/null && exit 1
	[ -e $S/st/nvidia_broken ] && exit 1
	for n in nvidia nvidia_modeset nvidia_drm nvidia_uvm; do grep -qx $n $S/st/modules 2>/dev/null || echo $n >> $S/st/modules; done
	[ -e $D/driver ] || [ -n "$(cat $D/driver_override)" ] || { ln -s ../../drivers/nvidia $D/driver; } ;;
*) exit 1 ;;
esac; done'
	w lsmod 'echo "Module Size Used by"
[ -s $S/st/modules ] && while read -r m; do echo "$m 16384 0"; done < $S/st/modules
exit 0'
	w sysctl 'case $1 in
-n) cat $S/st/sysctl.$2 ;;
-q) shift; if [ "$1" = -p ]; then while IFS== read -r k v; do echo "$v" > $S/st/sysctl.$k; done < "$2"; else for a; do echo "${a#*=}" > $S/st/sysctl.${a%%=*}; done; fi
	echo "sysctl $*" >> $S/st/events ;;
*) exit 1 ;;
esac'
	w nvidia-smi 'up() { [ -s $S/st/35b ] && kill -0 "$(cat $S/st/35b)" 2>/dev/null; }
case $1 in
-L) grep -qx nvidia $S/st/modules 2>/dev/null && [ "$(basename "$(readlink $D/driver)")" = nvidia ] && echo "GPU 0: NVIDIA GB10 (UUID: GPU-sim)" || { echo "No devices were found"; exit 6; } ;;
--query-compute-apps=pid) up && cat $S/st/35b; exit 0 ;;
--query-compute-apps=process_name,used_memory) up && echo "aien-serve-http, 43520 MiB"; exit 0 ;;
*) exit 1 ;;
esac'
	w pgrep '[ -s $S/st/35b ] && kill -0 "$(cat $S/st/35b)" 2>/dev/null && cat $S/st/35b && exit 0
exit 1'
	w curl 'up() { [ -s $S/st/35b ] && kill -0 "$(cat $S/st/35b)" 2>/dev/null && [ ! -e $S/st/serve_dead ]; }
up || exit 7
case "$*" in
*/v1/models*) echo "{\"data\":[{\"id\":\"qwen3.6-35b-a3b\"}]}" ;;
*/v1/chat/completions*) echo "{\"choices\":[{\"message\":{\"content\":\"ready\"}}]}" ;;
*) exit 22 ;;
esac'
	w tee '/usr/bin/tee "$@" || exit $?
for a; do t=$a; done
case $t in
$S/sys/bus/pci/drivers_probe)
	if [ ! -e $D/driver ]; then
		o=$(cat $D/driver_override)
		if [ "$o" = vfio-pci ] && grep -qx vfio_pci $S/st/modules; then ln -s ../../drivers/vfio-pci $D/driver; : > $S/dev/vfio/20; cat $S/st/vfio_mode 2>/dev/null > $S/st/modes/20 || echo root:root:600 > $S/st/modes/20; echo "bind vfio-pci" >> $S/st/events
		elif [ -z "$o" ] && grep -qx nvidia $S/st/modules 2>/dev/null; then ln -s ../../drivers/nvidia $D/driver; echo "bind nvidia" >> $S/st/events; fi
	fi ;;
$S/sys/bus/pci/drivers/vfio-pci/unbind) rm -f $D/driver $S/dev/vfio/20; echo "unbind vfio-pci (FLR)" >> $S/st/events ;;
$D/power/control) [ "$(cat $D/power/control)" = on ] && [ ! -e $S/st/pm_stuck ] && echo active > $D/power/runtime_status ;;
esac
exit 0'
	w stat 'for a; do f=$a; done
case $f in $S/dev/vfio/*) cat $S/st/modes/$(basename $f) ;; *) exec /usr/bin/stat "$@" ;; esac'
	w fuser 'echo " 1755 $(cat $S/st/35b 2>/dev/null)"'
	w modinfo 'case "$*" in
"-n vfio-pci") echo /lib/modules/sim/vfio-pci.ko ;;
nvgrace-gpu-vfio-pci) for a in 31C2 2941 2348 2345 2342; do echo "alias: pci:v000010DEd0000${a}sv*sd*bc*sc*i*"; done ;;
*) exit 1 ;;
esac'
	w lsinitramfs 'echo usr/lib/modules/sim/kernel/drivers/vfio/pci/vfio-pci.ko'
	w spark-window 'echo free'
}

# --- assertions ----------------------------------------------------------------------------------------
ok() { pass=$((pass + 1)); echo "  ok   $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL $1"; FAILED_IN="$FAILED_IN $CASE"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
L() { echo "$S/home/handoffs/OwnDriver/window"; }
alive35b() { [ -s "$S/st/35b" ] && kill -0 "$(cat "$S/st/35b")" 2>/dev/null; }
restored() {
	check "35B running again" alive35b
	check "35B restarted with the recorded env (key compared)" "tr '\\0' '\\n' < $S/proc/\$(cat $S/st/35b)/environ | grep -qx AIEN_COORD_KEY=simkey && tr '\\0' '\\n' < $S/proc/\$(cat $S/st/35b)/environ | grep -qx Q36_BATCH_BIN=bin-19173f9e"
	check "nvidia bound, 4 modules" "[ \$(basename \$(readlink $S/sys/bus/pci/devices/$BDF/driver)) = nvidia ] && [ \$(grep -c nvidia $S/st/modules) = 4 ]"
	check "hold-back file and unit gone" "[ ! -e $S/etc/modprobe.d/zz-aien-owndriver-window.conf ] && [ ! -e $S/etc/systemd/system/aien-owndriver-window.service ] && [ ! -e $S/st/unit-enabled ]"
	check "sysctl back to 0/0" "[ \$(cat $S/st/sysctl.kernel.panic) = 0 ] && [ \$(cat $S/st/sysctl.kernel.panic_on_oops) = 0 ]"
	check "state, approval, restore-path cleared" "[ ! -e $(L)/state ] && [ ! -e $(L)/APPROVED ] && [ ! -e $(L)/restore-path ]"
	check "driver_override empty" "[ -z \"\$(tr -d '\\n' < $S/sys/bus/pci/devices/$BDF/driver_override)\" ]"
	check "BOARD says WINDOW CLOSED" "grep -q 'WINDOW CLOSED' $S/home/handoffs/BOARD.md"
	check "power/control back to auto" "[ \$(cat $S/sys/bus/pci/devices/$BDF/power/control) = auto ]"
}
untouched() {
	check "35B never stopped" "alive35b && ! grep -q 'boot 2' $S/st/events"
	check "no window file written" "[ ! -e $S/etc/modprobe.d/zz-aien-owndriver-window.conf ] && [ ! -e $S/etc/systemd/system/aien-owndriver-window.service ] && [ ! -e $(L)/state ]"
}
boots() { check "boots after power-on: $1" "[ \$(cat $S/st/boots) = $(($1 + 1)) ]"; }

FAILED_IN=
CASE=w0;          echo "case $CASE: W0 read-only"; mkroot $CASE
run_window "$S" sh window/d2-pre.sh
check "W0 exit 0" "grep -qx 'cmd exit 0' $S/st/events"; untouched
check "baseline written" "[ -s $(L)/priv-baseline ]"

# mkfw S: a build/fw in fwprep's manifest format (fw_file names the real firmware sha256).
mkfw() {
	mkdir -p "$1/build/fw"
	{
		echo "fwmanifest 1"
		echo "fw_file bytes=75012080 sha256=32cb7cf3e77f97e92f6e92135939ccb3ba382748144569c0dfccf3338d43d963"
		for o in fmc.img fmc.hash fmc.pubkey fmc.sig bl.img; do
			echo "sim $o" > "$1/build/fw/$o"
			echo "out $o bytes=$(wc -c < "$1/build/fw/$o") sha256=$(sha256sum "$1/build/fw/$o" | cut -c1-64)"
		done
		echo end
	} > "$1/build/fw/fw.manifest.tmp"
	mv "$1/build/fw/fw.manifest.tmp" "$1/build/fw/fw.manifest"
}
CASE=fwgood;      echo "case $CASE: W0 with a matching build/fw"; mkroot $CASE
mkfw "$S"
run_window "$S" sh window/d2-pre.sh
check "W0 exit 0" "grep -qx 'cmd exit 0' $S/st/events"; untouched
check "build/fw checked" "grep -q 'build/fw matches fw.manifest' $(L)/*-pre.log"

CASE=fwbad;       echo "case $CASE: W0 with a build/fw file that differs from fw.manifest"; mkroot $CASE
mkfw "$S"; echo tampered > "$S/build/fw/bl.img"
run_window "$S" sh window/d2-pre.sh
check "W0 refused" "grep -qx 'cmd exit 1' $S/st/events"; untouched
check "names the mismatch" "grep -q 'build/fw files do not match' $(L)/*-pre.log"

CASE=d2;          echo "case $CASE: full D2 window, reboot restore path"; mkroot $CASE
run_window "$S" sh window/d2-pre.sh --go D2
boots 2; restored
check "W2 bound vfio-pci, then W7 unbound it (FLR)" "grep -q 'bind vfio-pci' $S/st/events && grep -q 'unbind vfio-pci' $S/st/events"
check "w0 ran on the device" "grep -q '^w0 000f:01:00.0 20' $S/st/events"
check "W4/W5 logged NOT_RUN (no build/ogd)" "grep -q \"W-boot NOT_RUN\" $(L)/*-run.log && grep -q \"W-hello NOT_RUN\" $(L)/*-run.log"
check "panic sysctls were 10/1 during W2" "grep -q 'sysctl kernel.panic=10 kernel.panic_on_oops=1' $S/st/events"

CASE=rebind;      echo "case $CASE: D2 window, RESTORE_PATH=rebind"; mkroot $CASE
run_window "$S" env RESTORE_PATH=rebind sh window/d2-pre.sh --go D2
boots 1; restored

CASE=noappr;      echo "case $CASE: no approval file"; mkroot $CASE
rm "$(L)/APPROVED"
run_window "$S" sh window/d2-pre.sh --go D2
check "refused" "grep -q 'cmd exit 1' $S/st/events"; untouched

CASE=noreset;     echo "case $CASE: approval without 'reset: approved'"; mkroot $CASE
printf 'window: sim\nreboot: approved\n' > "$(L)/APPROVED"
run_window "$S" sh window/d2-pre.sh --go D2
check "refused" "grep -q 'cmd exit 1' $S/st/events"; untouched

CASE=locked;      echo "case $CASE: chip lock held by another GPU job"; mkroot $CASE
(flock -x 9; sleep 30) 9>>"$S/tmp/aien-gb10.lock" &
lockpid=$!; sleep 0.3
run_window "$S" sh window/d2-pre.sh --go D2
kill $lockpid 2>/dev/null || true
check "refused" "grep -q 'cmd exit 1' $S/st/events"; untouched

CASE=snapdiff;    echo "case $CASE: live 35B started differently from the restore recipe"; mkroot $CASE
printf 'Q36_BATCH_BIN=bin-99230310\0AIEN_COORD_KEY=simkey\0' > "$S/proc/$(cat "$S/st/35b")/environ"
run_window "$S" sh window/d2-pre.sh --go D2
check "refused" "grep -q 'cmd exit 1' $S/st/events"; untouched

CASE=w1abort;     echo "case $CASE: W1 fails after stopping the 35B (systemctl enable fails)"; mkroot $CASE
touch "$S/st/fail_enable"
run_window "$S" sh window/d2-pre.sh --go D2
boots 0; restored
check "W1 exit nonzero" "grep -q 'cmd exit 1' $S/st/events"

CASE=pm;          echo "case $CASE: runtime PM stays suspended after power/control=on"; mkroot $CASE
touch "$S/st/pm_suspended" "$S/st/pm_stuck"
run_window "$S" sh window/d2-pre.sh --go D2
rm -f "$S/st/pm_suspended" "$S/st/pm_stuck"
check "w0 never ran (no BAR access while suspended)" "! grep -q '^w0 ' $S/st/events"
check "W3 refused on runtime_status" "grep -q 'runtime_status=suspended, not active' $(L)/*-run.log"
boots 2; restored

CASE=w0fail;      echo "case $CASE: w0 fails"; mkroot $CASE
echo 3 > "$S/st/w0_rc"
run_window "$S" sh window/d2-pre.sh --go D2
boots 2; restored
check "release logged rc=1" "grep -q 'W7 release (rc=1)' $(L)/*-run.log"

CASE=crash;       echo "case $CASE: crash during W3 (no trap runs)"; mkroot $CASE
touch "$S/st/w0_crash"
run_window "$S" sh window/d2-pre.sh --go D2
boots 2; restored

CASE=fallback;    echo "case $CASE: nvidia fails to come back once: one reboot fallback"; mkroot $CASE
echo 1 > "$S/st/nvidia_bad_boots"
run_window "$S" sh window/d2-pre.sh --go D2
boots 3; restored
check "fallback used once" "grep -q 'reboot fallback' $S/home/handoffs/BOARD.md"

CASE=fallback2;   echo "case $CASE: nvidia never comes back: stop after one fallback"; mkroot $CASE
echo 99 > "$S/st/nvidia_bad_boots"
run_window "$S" sh window/d2-pre.sh --go D2
boots 3
check "BOARD says restore FAILED" "grep -q 'restore FAILED after the reboot fallback' $S/home/handoffs/BOARD.md"
check "no reboot loop" "! grep -q 'boot loop' $S/st/events"
check "unit and state kept for the next (manual) boot" "[ -e $S/etc/systemd/system/aien-owndriver-window.service ] && [ \$(cat $(L)/state) = restore ]"

CASE=leak;        echo "case $CASE: a privilege file appears during the window"; mkroot $CASE
touch "$S/st/w0_leak"
run_window "$S" sh window/d2-pre.sh --go D2
check "BOARD says PRIVILEGE PERSISTED" "grep -q 'PRIVILEGE PERSISTED' $S/home/handoffs/BOARD.md"
check "no WINDOW CLOSED" "! grep -q 'WINDOW CLOSED' $S/home/handoffs/BOARD.md"

CASE=vfiomode;    echo "case $CASE: /dev/vfio/20 comes up world-writable"; mkroot $CASE
echo root:root:666 > "$S/st/vfio_mode"
run_window "$S" sh window/d2-pre.sh --go D2
check "w0 never ran" "! grep -q '^w0 ' $S/st/events"
check "W2 refused on the mode" "grep -q 'is root:root:666, expected root:root:600' $(L)/*-run.log"
boots 2; restored

CASE=lockboot;    echo "case $CASE: another GPU job takes the chip lock right after the W1 reboot"; mkroot $CASE
touch "$S/st/lock_after_reboot"
run_window "$S" sh window/d2-pre.sh --go D2
kill "$(cat "$S/st/lockholder")" 2>/dev/null || true
check "w0 never ran" "! grep -q '^w0 ' $S/st/events"
check "W2 refused on the lock" "grep -q 'is held: something started a GPU job' $(L)/*-run.log"
boots 2; restored

CASE=d3noogd;     echo "case $CASE: D3 without build/ogd"; mkroot $CASE
D3_CMD="make chip-gates" run_window "$S" sh window/d2-pre.sh --go D3
check "refused" "grep -q 'cmd exit 1' $S/st/events"; untouched

CASE=stale;       echo "case $CASE: boot unit left over with no state"; mkroot $CASE
cp "$R/window/aien-owndriver-window.service" "$S/etc/systemd/system/"; touch "$S/st/unit-enabled"
boot_power_on "$S" 1
check "unit removed itself" "[ ! -e $S/etc/systemd/system/aien-owndriver-window.service ] && [ ! -e $S/st/unit-enabled ]"
check "no driver change" "! grep -q 'bind vfio-pci' $S/st/events"

for s in "$BASE"/*/st/35b; do [ -s "$s" ] && kill "$(cat "$s")" 2>/dev/null || true; done
[ -n "${SIMDIR:-}" ] || rm -rf "$BASE"
if [ "$fail" -eq 0 ]; then
	echo "window_sim: PASS ($pass checks, $(grep -c '^CASE=' "$0") scenarios)"
else
	echo "window_sim: FAIL ($fail of $((pass + fail)) checks; in:$FAILED_IN)"
	exit 1
fi
