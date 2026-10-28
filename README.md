# omega-gpu-driver

The GB10 GPU driver written in seeded Omega. Status: **W0 IMPLEMENTED and EXERCISED in QEMU. The driver
units below are IMPLEMENTED and EXERCISED on the host against C referees and simulators only. Nothing has
run on GB10 hardware; nothing here is QUALIFIED. GSP boot (`gb10_gsp_boot.c`) is not ported.**

Parent: [aien-dev/omega-mv](https://github.com/aien-dev/omega-mv), the seeded Omega compiler. This repo
pins one omega-mv commit and the sha256 of the `omc` it births (`tools/omc.pin`). The pin is currently
the draft branch `feat/vfio-dma-bar` (omega-mv#890, commit `397e6704`, on #878 `feat/vfio-device-calls`).
It adds the `vfioctl` and `vfiomap` words plus IOMMU_MAP_DMA/UNMAP_DMA and the writable `vfiomapw` this
driver needs. The pin moves to omega-mv main after those PRs are reviewed and merged.

`DESIGN.md` records the proposed isolation/submit/cache model and the implemented, host-exercised owned
DMA-window lifecycle. Hardware execution and the Linux-kernel replacement remain NOT_RUN.

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

    sh build.sh          # births the pinned omc from seed-0, checks its sha256, writes build/w0, build/fwprep
    OGKM=<open-gpu-kernel-modules 580.173.02 checkout> sh build.sh
                         # also runs build/fwprep on the installed gsp_ga10x.bin into build/fw (fw.manifest)
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

## Driver units (host-exercised ports of aienux PR #441 C)

Each unit is a `.om` port of one aienux reference file; each gate compares the `.om` output with the C
reference byte for byte, and each mutant script changes one line at a time and requires the gate to fail.

| Unit | Ported from | Gate | Mutants |
|---|---|---|---|
| `gsp/mmio.om`, `gsp/sim.om` (register-level GSP start-up via SEC2, runtime-PM gate, SEC2+GSP falcon simulator) | `gpu/gsp_mmio.c`, `gpu/gsp_sim.c` | `tests/mmio_diff.sh`, `tests/pm_gate.sh` | `tests/mutants-mmio.sh` |
| `gsp/sysinfo.om` (GSP_SET_SYSTEM_INFO payload) | `tools/ck_gsp_sysinfo_encode.c` | `tests/sysinfo_diff.sh` | `tests/mutants-sysinfo.sh` |
| `gsp/seq.om` (GSP_RUN_CPU_SEQUENCER, CPU side) | `gpu/gsp_seq.c` | `tests/seq_diff.sh` | `tests/mutants-seq.sh` |
| `gsp/sha2.om`, `gsp/inflate.om`, `gsp/fw.om`, `gsp/bindata.om`, `fwprep.om` (firmware inputs) | `ck_gsp_fw_inspect.c`, `ck_gsp_bindata_extract.c`, `argus/sha256.c` | `tests/fw_diff.sh` | `tests/mutants-fw.sh` |
| `chan/gmmu.om`, `chan/mem.om`, `chan/chan.om`, `chan/sim.om` (page tables, buffers, channels; simulator mode only) | `gpu/gmmu.c`, `gpu_mem.c`, `gpu_chan.c`, `gpu_sim.c` | `tests/chan_diff.sh` | `tests/mutants-chan.sh` |
| `chan/dma.om`, owned backend of `chan/gmmu.om` (Linux userspace VFIO; not a kernel module) | Linux VFIO ABI and pinned Omega handle contract | `tests/dma_host.sh` | 11 compiling ownership/order/range/error mutants in the same gate |
| `chan/params.om` (RM alloc/control records for GSP-RM, NVIDIA 580.173.02 layouts) | NVIDIA headers | `tests/params_diff.sh` | `tests/mutants-chan.sh` |

`fwprep FWFILE OGKMSRC OUTDIR` reads the signed `gsp_ga10x.bin` (unchanged) and the NVIDIA open-source
bindata tables, and writes `fmc.img`, `fmc.hash`, `fmc.pubkey`, `fmc.sig`, `bl.img` and, last,
`fw.manifest`. Channel ops other than the simulator (mode 0) trap; on the GB10 they go through GSP RPC.

The hardware backing assumption is now explicit: `mmwinit` keeps the simulator array; `mmwalloc` owns
shared anonymous `mapnew` memory and CPU accesses use the live handle plus offset. The IOVA, CPU base
and GPU VA are distinct. `mmwdmap` maps before `mmwpublish`; a never-published window unmaps its whole
recorded extent before dropping backing. Epoch checks refuse stale users. Publication is sticky:
timeouts, uncertain mapping/completion and partial/unexpected unmap results quarantine backing.
No documented idle-proof API exists, so published/quarantined backing cannot be reclaimed or reset.
The caller exclusively owns container/process lifetime; this is not crash-safe containment.
See `DESIGN.md` section 4 for the exact state contract and required future GSP publication callsites.

`OMC=/path/to/pinned/omc sh tests/dma_host.sh` passes 23 host replay/boundary cases, real invalid-fd
MAP_DMA retry/drop refusal, and 11 compiling negative-control mutants. Only anonymous host memory and
invalid fd -1 are exercised by the real backend; the DMA success/error transport is explicit test-only
link-time replay. No device open/release, DMA, hardware MMIO or reset is performed. The separate
simulator diff remains byte-identical across 391 lines. Hardware: **NOT_RUN**.

Test-only referees and harnesses (disclosed; never linked into the driver): `tests/seq_ref.c` and
`tests/params_ref.c` (C), the aienux C tools built fresh by the diff scripts, and the shell scripts in
`tests/`. Host tools in the build and test path: `sh`, `git`, `sha256sum`, `cc`, QEMU 8.2.2, busybox,
zstd, cpio, gzip.

## On the GB10 (authorized exclusive window only)

`window/README.md` is the procedure: W0 read-only checks, W1 reboot with nvidia.ko held back, W2 bind to
`vfio-pci`, W3 `build/w0 000f:01:00.0 20`, W7 release, then R restores nvidia.ko and the resident 35B.
`tests/window_sim.sh` runs those scripts unchanged against a simulated machine, and
`tests/mutants-window.sh` checks that it catches each removed safety step. None of it has run on the GB10.

Expected from W3: config vendor/device 0x2e1210de (lspci reports [10de:2e12]) and matching map and pread
values. The BOOT_0 architecture field (bits 28:24) is defined at nv_ref.h:129-136 (GB100 0x1A, GB200
0x1B); which value the GB10 reports is what this run measures, not something this repo asserts.
