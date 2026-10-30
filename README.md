# omega-gpu-driver

The GB10 GPU driver written in seeded Omega. Status: **W0 IMPLEMENTED and EXERCISED in QEMU only.
Not run on GB10 hardware; nothing here is QUALIFIED.**

Parent: [aien-dev/omega-mv](https://github.com/aien-dev/omega-mv), the seeded Omega compiler. This repo
pins one omega-mv commit and the sha256 of the `omc` it births (`tools/omc.pin`). The pin is currently
the draft branch `feat/vfio-device-calls` (commit `7ae2aef9b`), which adds the `vfioctl` and `vfiomap`
words this driver needs; it moves to omega-mv main after that PR is reviewed and merged.

## W0: bind, read identity, release

`w0 BDF GROUP [HEXOFF]` opens one PCI function that the operator has already bound to `vfio-pci`, reads
its identity and releases it. It never writes to the device and never calls `DEVICE_RESET`.

1. Refuses unless `/sys/bus/pci/devices/BDF/iommu_group` is GROUP (exit 3), the driver link is
   `vfio-pci` (exit 4) and `/sys/kernel/iommu_groups/GROUP/devices` lists exactly BDF (exit 5).
2. Container `/dev/vfio/vfio`: API version 0 and the TYPE1v2 extension (exit 6). Group: viable
   (exit 7), attached, TYPE1v2 set (exit 8). Device fd by name (exit 9).
3. `DEVICE_GET_INFO` (must be PCI with at least 8 regions), region info for BAR0 (index 0) and CONFIG
   (index 7) (exit 10).
4. Config identity through `pread` of the CONFIG region: vendor/device 0x00, revision/class 0x08,
   subsystem 0x2C.
5. PMC_BOOT_0 (0x000), PMC_BOOT_1 (0x004) and PMC_BOOT_42 (0xA00) through `pread` of BAR0, then through
   a read-only `vfiomap` of BAR0 (`mapget`, one DSB-bracketed 32-bit load each). Optional HEXOFF reads
   one more aligned word through the map; an offset outside BAR0 or misaligned traps (exit 103).
6. Unmaps and closes device, group and container. Exit 11 if BOOT_0 reads 0xffffffff, 13 if the map
   and pread values differ, 12 if the map fails.

**w0 does not avoid a reset.** It never asks for one, but Linux `vfio-pci` (v7.0) resets the device
itself: opening the device fd FLRs the function when a reset method is enabled, and closing it sets
`needs_reset` and calls `pci_reset_bus`, a Secondary Bus Reset of the parent bridge. Writing `''` to
`reset_method` disables only the function-level paths; `pci_reset_bus` ignores `reset_method` and
checks only `PCI_DEV_FLAGS_NO_BUS_RESET`. On the Spark the GPU 000f:01:00.0 sits behind root port
10de:22d1, which the running kernel does not quirk NO_BUS_RESET (only 22ce and 22d0 are), so the
release would assert SBR on that port. EXERCISED in QEMU with the host kernel and a kprobe trace:
`qemu/sbr/sbr-on-release.log` (CASE B: `pci_reset_bus` then `pci_bridge_secondary_bus_reset` on
release with `reset_method` empty; CASE C: refused w0, zero reset calls). Not run on hardware.

Register offsets (NVIDIA open-gpu-kernel-modules 580.173.02,
`src/common/inc/swref/published/nv_ref.h`): NV_PMC_BOOT_0 0x0 at :108, NV_PMC_BOOT_1 0x4 at :138,
NV_PMC_BOOT_42 0xA00 at :149; NV_CONFIG_PCI_NV_0 at :52, NV_CONFIG_PCI_NV_2 at :66,
NV_CONFIG_PCI_NV_11 at :81. VFIO ABI: Linux `include/uapi/linux/vfio.h`.

The compiler enforces the device boundary: `vfioctl` accepts only literal allowlisted VFIO requests at
their exact sizes, and `vfiomap` only maps a region read-only, so a write through the BAR0 handle
traps. See omega-mv `seed/host/MAPPING.md`.

## Build and test

    sh build.sh          # births the pinned omc from seed-0, checks its sha256, writes build/w0
    KERNEL=img/boot/vmlinuz-7.0.0-1019-nvidia sh qemu/test.sh
                         # QEMU virt + SMMUv3, edu device on vfio-pci, 9 commands, all results checked
    KERNEL=... DEVICES='-device pcie-root-port,id=rp1,chassis=1,slot=1 -device edu,bus=rp1' \
      sh qemu/bench/run.sh build/w0 qemu/sbr/sbr.cmds qemu/sbr/sbr-on-release.log
                         # kprobe trace of the resets vfio-pci performs around w0 (see above)

The QEMU bench (`qemu/bench/`) boots the host's Ubuntu 7.0.0-1019-nvidia kernel with busybox and the
host's own `iommufd`, `vfio`, `vfio-pci-core` and `vfio-pci` modules. `qemu/w0-edu.log` is the committed
transcript: edu reads `0x010000ed` at BAR0 0x0 through both the map and pread; wrong group, an unbound
edu, a virtio device, an access at the BAR0 size and a misaligned access are all refused.
`qemu/mutant-*.log` show two compiler mutants (MAP_PRIVATE, wrong device-fd request) failing there.

Host tools in the build and test path (disclosed; not part of the driver): `sh`, `git`, `sha256sum`,
QEMU 8.2.2, busybox, zstd, cpio, gzip. The driver itself is `w0.om` only.

## On the GB10 (operator-run, authorized window only)

Main binds the GPU to `vfio-pci` (000f:01:00.0, IOMMU group 20, alone in its group) and runs:

    build/w0 000f:01:00.0 20

Expected: config vendor/device 0x2e1210de (lspci reports [10de:2e12]) and matching map and pread
values. The BOOT_0 architecture field (bits 28:24) is defined at nv_ref.h:129-136 (GB100 0x1A, GB200
0x1B); which value the GB10 reports is what this run measures, not something this repo asserts.

## Human-Directed Agentic Engineering

Development follows Human-Directed Agentic Engineering (HDAE): humans define goals, architecture, constraints, acceptance criteria, and stopping points; agents implement, execute checks, diagnose failures, and revise within those boundaries. Human review retains responsibility for claims, acceptance, and release decisions.

For the documented method and a systems-software case study, see Gregory M. Kurtzer, [*Ginux: Building an Independent Kernel That Runs Linux Userspace through Human-Directed Agentic Engineering* (2026)](https://doi.org/10.5281/zenodo.23682548). This does not change the QEMU-only status or authorize any device action.

## Licence

Apache-2.0; see `LICENSE`. `NOTICE` credits NVIDIA open-gpu-kernel-modules 580.173.02 (MIT), from which
register offsets, structure layouts and constants are cited. Any part that becomes in-kernel Linux
code would be `MIT OR GPL-2.0-only` instead.
