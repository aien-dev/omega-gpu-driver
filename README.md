# omega-gpu-driver

The GB10 GPU driver written in seeded Omega. Status: **W0 IMPLEMENTED and EXERCISED in QEMU. Existing
driver units are host-exercised against C referees and simulators. The new bounded boot image and RPC
replay units below are IMPLEMENTED and HOST_EXERCISED with exact binary parity and behavior mutants.
Nothing has run on GB10 hardware; nothing here is QUALIFIED. No NVIDIA kernel driver replacement is deployed.**

Parent: [aien-dev/omega-mv](https://github.com/aien-dev/omega-mv), the seeded Omega compiler. This repo
pins one omega-mv commit and the sha256 of the `omc` it births (`tools/omc.pin`). The pin is currently
the draft branch `feat/vfio-dma-bar` (omega-mv#890, commit `397e6704`, on #878 `feat/vfio-device-calls`).
It adds the `vfioctl` and `vfiomap` words plus IOMMU_MAP_DMA/UNMAP_DMA and the writable `vfiomapw` this
driver needs. The pin moves to omega-mv main after those PRs are reviewed and merged.

`DESIGN.md` records the proposed isolation/submit/cache model and the implemented, host-exercised owned
DMA-window lifecycle. Hardware execution and the Linux-kernel replacement remain NOT_RUN.

The 2026-10-28 candidate corrects the common-mode GB10B MCTP-header oracle defect
and adds a separate source-selected GB20B COTv2 arena and SEC2 response path.
See [GB20B.md](GB20B.md) for exact vendor/reference pins, mismatch refusals,
host-only scope, composed-launcher/native-effect gaps and the **unexecuted**
minimal W0 authorization procedure. `fwprep` remains GB10B-only; `gpchip` does
not admit GB20B to the existing GB10B transport. No physical boot/RPC/compute ran.

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
| `gsp/rpc.om`, `gsp/boot.om` (SWAP_RX transport frames, boot handshake, correlated RM transactions and quarantine; replay only) | `dev/gb10_gsp_boot.c` and pinned vendor protocol | `tests/rpc_diff.sh` | `tests/mutants-rpc.sh` |
| `gsp/arena.om`, `gsp/connect.om` (bounded WPR/libos/log/radix/FMC/COT composition and preboot queue attachment) | `dev/gb10_gsp_boot.c` | `tests/arena_diff.sh` | `tests/mutants-arena.sh` |
| `gsp/sec2.om`, `gsp/sec2sim.om`, profile-2 `gsp/arena.om` (GB20B secure-boot/COTv2/MSGQ cold-production candidate) | NVIDIA 580.173.02 SEC2 GB20B HAL | `tests/sec2_host.sh` | `tests/mutants-sec2.sh` |
| `gsp/profile.om`, `gsp/transport.om`, `gsp/notify.om`, `gsp/service.om` (checked mapped queue mechanism and caller pump; not production admission) | pinned vendor SWAP_RX/notification plus explicit host peer | `tests/transport_host.sh` | compiling transport/notification/service mutants plus generated-fence checker negative control |
| `gsp/dispatch.om` (whole-stream prevalidation and explicit host sequencer execution; hardware refusal) | pinned vendor sequencer plus aienux sequencer | `tests/dispatch_diff.sh` | `tests/dispatch_mutants.sh` |
| `chan/complete.om`, `chan/rmchan.om` (semaphore progress and async RM lifecycle; no global idle proof) | pinned NVIDIA headers and independent C referee | `tests/complete_diff.sh`, `tests/rmchan_diff.sh` | `tests/mutants-complete.sh`, `tests/mutants-rmchan.sh` |

`fwprep FWFILE OGKMSRC OUTDIR` reads the signed `gsp_ga10x.bin` (unchanged) and the NVIDIA open-source
bindata tables, and writes `fmc.img`, `fmc.hash`, `fmc.pubkey`, `fmc.sig`, `bl.img` and, last,
`fw.manifest`. Channel ops other than the simulator (mode 0) trap; on the GB10 they go through GSP RPC.

The hardware backing assumption is now explicit: `mmwinit` keeps the simulator array; `mmwalloc` owns
shared anonymous `mapnew` memory and CPU accesses use the live handle plus offset. The IOVA, CPU base
and GPU VA are distinct. `mmwdmap` maps before `mmwpublish`; a DMA-mapped, never-published window
unmaps its whole recorded extent before dropping backing. Never-mapped backing drops directly.
Epoch checks refuse stale users. Publication is sticky:
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

## Boot image and RPC replay boundary

The new implementation is seeded `.om`, not a C driver hidden behind a wrapper. It reuses the existing
`siout` system-info encoder and `pabuf`/`palen` allocation/channel codecs. `brmalloc`, `brmctrl` and
`brmfree` freeze one pending request and feed those bytes into the queue codec; accepted successful
replies populate `pareply`. Header success and the RM body status are separate checks. Failed replies
leave the consumer reply buffer unchanged. Hardware `chan/chan.om` bind/disable/idle still trap.

`arbuild` composes the full WPR/libos/log page tables/cached args/shared queue/radix3/bootloader/
signature/FMC/FMC-args/COT image into `arbuf`, bounded by `arcap <= 16777216`; input staging `arin`
has the same fixed bound. `arsrc/arslen[0..7)` select ELF, RM signature, bootloader, FMC, FMC hash,
FMC key and FMC signature. `arcfg[0..10)` carries explicit profile, DMA width, heap IOVA/size, GPU
instance, regkeys, bootloader code/data/manifest offsets and serialized registry length. `aroff/arsize`
describe all regions; `arcmd/arstat` are queue offsets, `araddr 15` the FMC-args IOVA, `arcot/arclen`
the COT packet and `artail` its EMEM tail. Outputs are invalid after any nonzero status. The registry
input is canonical bounded PACKED_REGISTRY_TABLE bytes, not a foreign runtime. `arboot` connects this
image's preboot queue counters directly to the boot handshake without reconstructing the queue.

`gsp/owned.om` connects construction to the owned backing: `arstage(epoch)` copies exact arena bytes
through the checked map handle only for the matching IOVA window, boot generation and unpublished
OWN/DMA lifecycle. It never publishes or notifies hardware. `arlose(epoch)` connects a quarantined
boot replay to retention of the matching already-published backing; it cannot unmap or reclaim it.
The final composed host gate `sh tests/boot_dma.sh` uses an explicit link-time DMA oracle, real
anonymous mappings and exact whole-arena comparison. Staging and quarantine mutants are both
detected. Its receipt is `tests/boot-dma-host-receipt.txt`; this is not a device endpoint or fence.

The host receipt is `tests/gsp-host-receipt.txt`: exact sender frames and boot state/refusal controls;
five complete arena fixtures (including multi-level radix and DWORD/binary/string registry); 31
invalid arena fixtures; 19 RPC and 12 arena mutants. Build/setup failures and unexpected runtime
traps do not count as detected mutants. These tests use synthetic signed-byte inputs, not valid
firmware authentication or firmware execution.

The queue layout is the non-confidential-computing NVIDIA 580.173.02 protocol: SWAP_RX, separate element
and RPC sequences, actual aligned-padding checksum validation, bounded wrapped slots, and full-slot
capture. RM_ALLOC deliberately excludes appended params from its logical length and checksum, as
`rpc.c:11194-11228` does. Those tail bytes are not authenticated or checksummed. The supported alloc
params bound is 3984 bytes; oversized/continuation requests refuse, not truncate. This is not a
cryptographic trust boundary.

Boot replay requires preboot system info and optional nonempty registry, explicit peer queue creation,
INIT_DONE, SET_GUEST_SYSTEM_INFO version handshake, then STATIC_INFO of the supplied expected size.
Private handshake result is an NV_STATUS: zero succeeds (`rpc.c:8764`); it is not a version value.
Version renegotiation refuses instead of guessing. CPU_SEQUENCER suspends the exact received event
until a matching generation/event token is dispatched through `gsp/dispatch.om`. The complete stream
is prevalidated before execution; completion is not fabricated and no acknowledgement RPC is invented.

`REPLAY_READY` is host state only, never a production resolver capability. Wait budgets count caller
polls, not elapsed time; unrelated events do not replenish them. Publication timeout or corrupt/
uncorrelated replies quarantine the replay with pending identity retained. Late replies cannot turn
that into success. `breset` only disposes replay images and refuses while a mapped transport is bound;
it cannot reset hardware, prove idle, unmap DMA, or authorize reclaim. Unpublished queue-full refusal
does not consume a sequence number.

The arena's GB10B/SEC2 profile remains unverified for the Spark target. `gsp/profile.om` classifies the
published BOOT_42 architecture/implementation fields, not a measured device: vendor `nv_ref.h:149-182`
and `nv_arch.h:51,111` identify GB1XX/GB10B; generated FSP/SEC2 HAL selection chooses SEC2/FMC COTv1,
and `nv-firmware-chip-family-select.h:58-62` selects `gb10y`. No device is opened to select a profile.

Run the host-only commands with the exact C reference checkout and pinned compiler:

```sh
AIENUX=<aienux-c5bb3a4b> OMC=<compiler-397e6704>/seed/out/omc sh tests/rpc_diff.sh
AIENUX=<aienux-c5bb3a4b> OMC=<compiler-397e6704>/seed/out/omc sh tests/mutants-rpc.sh
AIENUX=<aienux-c5bb3a4b> OMC=<compiler-397e6704>/seed/out/omc sh tests/arena_diff.sh
AIENUX=<aienux-c5bb3a4b> OMC=<compiler-397e6704>/seed/out/omc sh tests/mutants-arena.sh
```

Reference pins: aienux `c5bb3a4b9898257658aba0b7178a3c73a0371c27`; NVIDIA
`20e4e6e19cc26ba47b5cbe23130a396be100c427` (tag `580.173.02`); compiler
`397e67040fb74853c6814097fe02ae4e1ebd6f66`, sha256 in `tools/omc.pin`. Compiler PRs #878 and #890
are pending dependencies, not merged compiler capabilities. The new independent C referee is
test-only, compiled with Ubuntu GCC `13.3.0-6ubuntu2~24.04.1`; it is never linked into `.om` artifacts.
Python `3.12.3` coordinates only exact oracle comparisons and temporary mutation copies. It generates
no production bytes and has no driver runtime role; seeded `.om` already performs the encoding.
Existing shell, coreutils, git and cc remain disclosed verification tooling, not driver runtime dependencies.

### Still required for independent execution

Hardware is **NOT_RUN**. The Linux-process mapped mechanism is now implemented separately from the
host replay binding: link exactly one of `gsp/replay.om` or `gsp/transport.om` (with `gsp/profile.om`
and `gsp/notify.om`). There is no implicit transport fallback. `qtattach` requires the exact staged,
published owned-map epoch and boot generation. `rqprep`/`rqcommit` separate construction from
publication; stale tokens cannot publish a second time.

`qtsend` writes only owned slots, publishes command writePtr with an aligned `mapset`, then writes
zero to PGSP_QUEUE_HEAD(0). `qtsnap` acquires peer writePtr, captures only its bounded immutable
prefix, and `qtaccept` validates that capture before publishing host readPtr. SWAP_RX cursor ownership
is preserved. Semantic RPC rejection can occur after transport consumption and quarantines without
rolling back an already published cursor. Notification failure after publication is uncertain, not
an unsent request eligible for retry. Bound mappings remain retained on timeout/error.

`gsp/service.om` supplies `drvstep useRM`, a serialized pump that dispatches suspended sequencer
events before allowing either boot or RM policy to continue. `drvprep appVersion b0 b1 b2 b3`
copies the exact composed COT/FMC-argument inputs into the existing MMIO boot sequencer's input
buffers. It neither calls that sequencer nor authorizes device effects; firmware appVersion is
validated caller input. No host fixture invokes hardware mode, and no production resolver is added.

The pinned process compiler brackets each aligned `mapget`/`mapset` with DSB SY. This orders accesses
but does not establish cache coherency, memory attributes, cache maintenance, interrupt delivery or
device completion. Bulk mapread/mapwrite are ordinary copies, never cursor accesses. Host peers and
instruction inspection cannot qualify those device properties. A fatal mapping fault is not a
recoverable status and process-local quarantine is not crash-safe containment.

The host receipt for the mapped transport, sequencer dispatch, RM channel and completion slices is
`tests/transport-host-receipt.txt` (all 27 `tests/*.sh` scripts, exact hashes and tool versions).
`tests/window_sim.sh` needs `build/omc` to be the compiler named in `tools/omc.pin`.

`chan/rmchan.om` connects the existing allocation codecs to async RM hierarchy/schedule/disable/free;
`chan/complete.om` uses Blackwell completion-semaphore releases, never nonexistent USERD GPGet.
`chprep` allocates and encodes channel backing only (state 2, prepared): `rmbind` accepts only a
prepared channel, the schedule ACK alone makes it submit-ready (state 1), and the disable ACK
returns it to prepared. `chcreate` keeps the legacy simulator bind, which refuses an owned map.
Drained host tracking is not proof that GSP stopped accessing the boot arena and never authorizes its
reclamation. Hardware sequencer dispatch refuses regardless of host permission flags: a typed
MMIO lease/span and engine-specific core effects are absent from this pin. Completion semaphore
progress alone is not cache/engine completion: the vendor WFI/membar sequence is a separate required
effect boundary, not supplied by a CPU fence or inferred from an observed semaphore value.

The current compiler profile is Linux-process ELF/VFIO, not Linux kernel code. A Linux-hosted `.om`
user-space driver could replace NVIDIA modules while retaining Linux VFIO/IOMMU services; that is not
an Omega kernel module or a replacement for Linux. This pin does not provide kernel calling/trap ABI,
relocation/link profile, kernel-owned allocation/resource spans, ordered DMA/MMIO or IRQ/workqueue
lifecycle. The proposed typed kernel effects are a separate pending compiler extension, not an
implemented trust path. Actual device identity, coherent DMA ownership, firmware authentication,
hardware boot/RPC, engine reset/halt, interrupt handling and documented global idle/recovery still
require implementation/qualification at those boundaries. No C/Rust runtime substitute is adopted.

## On the GB10 (authorized exclusive window only)

`window/README.md` is the procedure: W0 read-only checks, W1 reboot with nvidia.ko held back, W2 bind to
`vfio-pci`, W3 `build/w0 000f:01:00.0 20`, W7 release, then R restores nvidia.ko and the resident 35B.
`tests/window_sim.sh` runs those scripts unchanged against a simulated machine, and
`tests/mutants-window.sh` checks that it catches each removed safety step. None of it has run on the GB10.

Expected from W3: config vendor/device 0x2e1210de (lspci reports [10de:2e12]) and matching map and pread
values. The BOOT_0 architecture field (bits 28:24) is defined at nv_ref.h:129-136 (GB100 0x1A, GB200
0x1B); which value the GB10 reports is what this run measures, not something this repo asserts.
