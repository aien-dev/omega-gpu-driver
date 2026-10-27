# OwnDriver window procedure (D2, D3)

Status: **NOT_RUN** on the GB10. W0 has run read-only beside the live 35B (EXERCISED, host). Nothing in W1..W7
or R has touched the GB10. The unchanged scripts have run end to end against a simulated machine under /tmp
(`tests/window_sim.sh`, EXERCISED host simulator; `tests/mutants-window.sh` removes one safety step at a time and
the simulator must catch it). Every step below stops the resident 35B on 127.0.0.1:18091, resets the GPU and
reboots the Spark twice. It runs only in an exclusive window that Drake opens for this job.

## What the window does to the machine

- **Two reboots.** nvidia.ko is held back for one boot so the GPU comes up without a driver. A live unload of
  nvidia can hang in `nvEvoWaitForCoreNotifier`, and a fresh boot hands the driver an untouched GPU. Each reboot
  ends **every agent session on the Spark, Main's included.** The window therefore runs unattended through a
  one-shot systemd unit (`aien-owndriver-window.service`) that W1 installs and R removes.
- **GPU reset.** `reset_method` is `flr bus`. vfio-pci FLRs the GPU when W2/W3 open it, and on release calls
  `pci_reset_bus`: a Secondary Bus Reset of root port 000f:00:00.0 (10de:22d1, not quirked NO_BUS_RESET),
  whose only device is the GPU 000f:01:00.0. Emptying `reset_method` would not stop that SBR (README.md,
  `qemu/sbr/sbr-on-release.log`, EXERCISED in QEMU only).
- **No privilege grant.** No udev rule, group, sudoers line, memlock limit or `/dev/vfio` mode change. The driver
  programs run as root through `sudo -n`. `/dev/vfio/20` must stay `root:root 0600`. W0 records the privilege
  baseline (`priv-baseline`: every file in `/etc/sudoers.d`, `/etc/udev/rules.d`, `/etc/security/limits.d` and
  `/etc/modprobe.d` with its sha256, plus the user's groups). R4 fails closed and posts to BOARD if anything differs.
- **Window files**, present only between W1 and R:
  - `/etc/modprobe.d/zz-aien-owndriver-window.conf`: nvidia hold-back;
  - `/etc/systemd/system/aien-owndriver-window.service`;
  - `~/handoffs/OwnDriver/window/{state,saved-sysctl,d3-cmd,reboot-fallback-used}`.

## Approval

Main writes `/home/drakestapleton/handoffs/OwnDriver/window/APPROVED` when Drake opens the window. The file lives
there and not in `/tmp`, because `/tmp` is emptied at every boot (`D /tmp` in tmpfiles.d). It must contain:

```
window: <Drake's words, or the BOARD line that quotes them>
reset: approved
reboot: approved
```

W1 and W2 refuse without all three lines. R deletes the file at the end (one approval, one window).

## Steps

| Step | Script | What it does | Ends with |
|---|---|---|---|
| W0 | `sh window/d2-pre.sh` | Read-only. Checks the firmware sha256, logs the sha256 of every script and binary, checks that `build/omc` matches `tools/omc.pin` and that `build/fw` matches `fw.manifest`. Checks the device identity (10de:2e12), that group 20 holds only 000f:01:00.0, that nvgrace-gpu-vfio-pci does not alias 2e12, and that the initramfs has no nvidia modules. Records the privilege baseline and runs privcheck. Checks that the live 35B launch record (argv, cwd, env names, coordinator key) equals the restore recipe. Lists GPU users and the chip lock. | exit 0 |
| W1 | `sh window/d2-pre.sh --go [D2\|D3]` | Repeats W0, then needs APPROVED and takes `/tmp/aien-gb10.lock` (`flock -n`; refuses if any GPU job holds it). Posts to BOARD, sends TERM to the 35B and waits until `nvidia-smi` shows no compute app. Saves the kernel.panic values, writes the hold-back file, installs and enables the unit, and sets state `run D2`. A failure before the reboot removes the window files and runs R. | reboot |
| W2 | unit → `d2-run.sh --go D2` | Sets state `restore` and deletes the hold-back file first, so any later boot is a normal one that ends in R. Needs APPROVED and the chip lock, and checks that no nvidia module is loaded. Sets `kernel.panic=10` and `panic_on_oops=1` (an oops reboots into R). Runs `modprobe vfio-pci`, sets `driver_override`, binds through `drivers_probe`, and checks `/dev/vfio/20` is `root:root:600`. | |
| W3 | | Runtime PM: `power/control=on` and `runtime_status=active` before any BAR access. `build/w0` reads config identity, BOOT_0/BOOT_1/BOOT_42 and the GSP falcon state (read-only), then `build/ogd ident`. | |
| W4 | | `build/ogd boot`: GSP boot to INIT_DONE, static info, unload. | |
| W5 | | `build/ogd hello`: objects, channel, one semaphore release, teardown. | |
| W6 (D3 only) | | `build/ogd exec ... -- $D3_CMD`, where D3_CMD is the CUDApp chip-gate command line. W1 stores it in `d3-cmd`. | |
| W7 | EXIT trap | Unbinds vfio-pci (GPU reset), clears `driver_override` and sets `power/control=auto`. Then by default reboots, and the unit runs R. With `RESTORE_PATH=rebind` it runs R in place. | reboot |
| R | unit → `d2-restore.sh --go` | R0: if the hold-back file is still there, removes it and reboots. R1: loads the nvidia modules, binds the device and checks that `nvidia-smi -L` lists the GB10. Any failure takes ONE reboot fallback (`reboot-fallback-used`), then R runs again. R2: starts nvidia-persistenced and restores the saved sysctls. R3: restarts the 35B with `start-35b-batch.sh` and the recorded env, waits for `/v1/models` (up to 900 s), runs one greedy chat, and requires exactly one `aien-serve-http` on the GPU. R4: removes the unit, runs privcheck against the baseline, removes markers, state and APPROVED, and posts BOARD `WINDOW CLOSED`. | |

Each driver step (W3 ident, W4, W5, W6) runs only if `build/ogd modes` lists it. Otherwise it is logged
`NOT_RUN: build/ogd has no '<mode>' mode` and the window goes straight to W7 and R. All logs go to
`~/handoffs/OwnDriver/window/d2-<UTC>-{pre,run,restore,boot}.log`.

**Current state (2026-10-27): `build/ogd` does not exist, so W4 and W5 are NOT_RUN and policy-blocked.** On
2026-10-27 the .om port of aienux `gb10_gsp_boot.c` (boot arena, COT packet, message queue, RM RPC) was stopped by
a model-policy refusal. Per the lane rule it was not retried. It needs a human-written port; that is Drake's
item. A D2 window today therefore exercises W2, W3 (`build/w0`), W7 and R. That still settles DESIGN §7
UNKNOWN 1 (BOOT_42 naming) and proves the vfio-pci bind/release and the nvidia.ko restore after the FLR and SBR.
`d2-pre.sh --go D3` refuses without `build/ogd`.

## Recovery when R fails twice

R posts `restore FAILED after the reboot fallback` to BOARD and stops. The GPU state is then unknown.
Recovery is a physical power cycle by Drake. After that boot the hold-back file is already gone (W2 or R0
deleted it), so nvidia.ko loads normally. The unit is still installed with state `restore`, so it runs R again.

## Simulator

`sh tests/window_sim.sh` runs these scripts, unchanged, against a fake machine in /tmp: sysfs, `/etc`, `/dev/vfio`
and `/proc` live under `OWNDRIVER_WINDOW_ROOT`, and sudo, systemctl, modprobe, sysctl, lsmod, nvidia-smi, pgrep,
curl, tee, stat, fuser, modinfo, lsinitramfs and spark-window are shims there. `common.sh` exits 2 unless the root
is under /tmp, carries `.owndriver-window-sim`, and every one of those commands resolves to the shim, so a
simulation can never reach the real machine. The harness simulates each reboot (fresh /tmp, 35B gone, nvidia loaded
unless held back, boot unit run if enabled). Scenarios: W0, full D2, rebind restore, missing approval, missing
reset line, chip lock held, mismatched 35B launch record, W1 failure after the 35B stop, runtime PM stuck, w0
failure, crash mid-W3, one restore fallback, restore failing twice, privilege leak, world-writable `/dev/vfio/20`,
chip lock taken right after the W1 reboot, D3 without ogd, stale unit. What it cannot show: real FLR and SBR
behaviour, nvidia.ko reload after them, real boot timing.

## Before posting WINDOW-READY

Run `sh build.sh` and `sh window/d2-pre.sh`. The sha256 values on the W0 log lines are the ones quoted in the
BOARD `WINDOW-READY` line. Any later edit to a hashed file changes those values, and W0 must be re-run.
