# omega-gpu-driver design notes

Status: **PROPOSED.** None of this is implemented yet. Nothing here has run on the GB10.

The bring-up design (GSP boot chain, RPC surface, the `ogd` launcher and manifest, the D2 window) is in the
lane's design document and is summarised in `README.md` and `window/README.md`. This file holds the design
decisions for the driver's isolation model and its userspace interface.

Source: an accel-driver survey of 2026-10-27 (lessons 1-3). It read the two Linux accel NPU drivers at
torvalds/linux `d135ab453a740`. All `drivers/accel/...` and `include/uapi/...` cites below are file:line in
that tree. `NV:` cites are NVIDIA open-gpu-kernel-modules 580.173.02, `src/common/sdk/nvidia/inc/class/`.

## 1. Isolation: one private GPU address space per client, no pushbuffer parser

**The two Linux models.** The two drivers protect the device in different ways:

- **ethosu has no MMU**, so the kernel checks every command stream.
  - It copies the stream into a buffer object marked no-mmap (`ethosu_drv.c:130`, enforced at
    `ethosu_gem.c:26-27`), so userspace cannot change it after the check.
  - It replays the stream in an interpreter (`ethosu_gem_cmdstream_copy_and_validate`, `ethosu_gem.c:385-707`).
  - Submit refuses a region that does not fit its buffer (`ethosu_job.c:398-496`).
- **rocket has an MMU** and never parses commands.
  - `rocket_open` gives each open file its own IOMMU paging domain (`rocket_drv.c:72,89`; created at 38-56).
  - Buffers are mapped into that domain (`rocket_gem.c:96`).
  - The domain is attached to the core for each job and detached afterwards (`rocket_job.c:348`, 382, 406).

**What we adopt.** The GB10 translates GPU virtual addresses through its GMMU, so OwnDriver follows rocket:

- Every client gets its own GPU VA space (FERMI_VASPACE_A). That client's page tables come from local GMMU
  code (`chan/gmmu.om`) and are installed with SET_PAGE_DIRECTORY.
- A client's buffers are mapped only into its own VA space.
- The driver does **not** parse or check pushbuffers or GPFIFO contents. Its job is address-space setup,
  buffer bounds, fences and teardown.

**Paths the GMMU may not translate.** On these paths ethosu-style copy-then-check still applies. The paths
come from the docs and none has been checked on the chip (UNVERIFIED):

1. **Copy-engine physical mode.** Ampere's copy class has `LAUNCH_DMA_SRC_TYPE_PHYSICAL` and
   `DST_TYPE_PHYSICAL` (`NV:clc7b5.h:121-126`). The published Blackwell copy headers (`NV:clc9b5.h`,
   `NV:clcab5.h`) list too few methods to say whether the mode still exists.
2. **Structures the GPU reads by bus address.**
   - These are the instance block, RAMFC, USERD and the GPFIFO ring, whose IOVAs travel in the channel alloc
     RPC (lane design §3).
   - ogd allocates and writes them itself; a client never supplies their contents. That is the copy-then-check
     rule applied at allocation.
3. **The SMMU.** It translates every device access (`iommu.passthrough=0`; the GPU is alone in IOMMU group 20).
   But one VFIO container gives the whole device a single IOMMU domain. A physical-mode access is therefore
   bounded by the union of all clients' DMA mappings, not by one client's mappings [INFERENCE]. Until (1) is
   settled, either refuse physical-mode copy methods, or run only one client at a time.

**Scope in v1.** In v1 the workload inherits the VFIO device fd (lane design §4), so it has BAR0 read/write
access. v1 therefore has one trusted workload per `ogd` session and claims no isolation between clients. The
per-client VA space model starts to protect something only once `ogd` serves more than one client and the
workload no longer holds the VFIO fd. That is v2: a request pipe, plus a mapping of only the doorbell and
USERD pages.

## 2. Submit ABI

The rules come from ethosu's job path and rocket's uapi. Each one is required from the first version of the ABI:

- **Per-buffer read/write flags; the write fence goes only on outputs.**
  - ethosu takes an implicit dependency for every buffer, marked as a write only for output regions
    (`ethosu_job.c:91-99`).
  - It attaches the done fence with `DMA_RESV_USAGE_WRITE` only to outputs (`ethosu_job.c:102-114`).
  - It locks all buffers as one group (`drm_gem_lock_reservations`, `ethosu_job.c:122-142`).
  - Each submit buffer entry in our ABI carries `READ`, `WRITE` or both. A read-only input never waits on
    another reader.
- **A watchdog that checks progress before resetting.**
  - ethosu runs one job in flight (`credit_limit = 1`, `ethosu_job.c:327`).
  - Its timeout handler reads the queue read pointer (`NPU_REG_QREAD`, `ethosu_job.c:280`). If the pointer
    still moves, it lets the job run on (`ethosu_job.c:287-292`) and resets only after that (`ethosu_job.c:305`).
  - Our counterpart is GPGet in USERD and the semaphore sequence. The watchdog reads one of them before it
    tears a channel down. A timeout with that counter still advancing is not a hang.
- **Reserved, pad and flags fields must be zero.** Refuse the call otherwise: ethosu `ethosu_drv.c:125`;
  rocket `rocket_gem.c:143`, `rocket_gem.c:174` and `rocket_job.c:643`. An unknown flag bit is refused, never
  ignored.
- **Self-sized structs.**
  - rocket's submit carries `job_struct_size` and `task_struct_size` (`rocket_accel.h:142-145`, 177-180).
  - The kernel refuses sizes smaller than the struct it knows (`rocket_job.c:77`, 638-639) and steps through
    the arrays by the size the caller declared (`rocket_job.c:95`, 656).
  - Our records start with a byte size and a version. The ABI can then grow at the tail without breaking old
    callers.

## 3. Ordering and cache sync: fences, not cache-maintenance calls

rocket brackets CPU access with explicit calls:

- `PREP_BO` waits for the write fence with a timeout, then calls `dma_sync_sgtable_for_cpu`
  (`rocket_gem.c:152-161`).
- `FINI_BO` calls `dma_sync_sgtable_for_device` (`rocket_gem.c:186`).

rocket needs these because the RK3588 NPU's DMA is not cache-coherent. That is the reason given in review; it
was not checked against RK3588 documentation here. ethosu syncs implicitly when a buffer is waited on or mapped.

The GB10 is a self-hosted part with a coherent C2C link. NVIDIA's RM treats it as such:

- Local EGM is set up only when `gpuIsSelfHosted(pGpu)` and `PDB_PROP_KBIF_IS_C2C_LINK_UP` hold
  (`NV2:mem_mgr.c:4022-4023`, with the comment "EGM can be enabled only in C2C path").
- When `kbusIsBar1Disabled` (`NV2:mem_mgr_gm107.c:619`), BAR1 is reported as size 0, with the comment "When
  coherent C2C path is enabled, BAR1 is disabled" (`NV2:mem_mgr_gm107.c:688-694`).

`NV2:` is `src/nvidia/src/kernel/gpu/mem_mgr/` (with `arch/maxwell/` for the gm107 file) in the same
580.173.02 tree. Neither function has been run on our chip. The lines say how RM treats a self-hosted C2C
GPU, not that every GB10 access path is coherent.

What this design takes from that:

1. **The ordering model on GB10 is fences plus memory ordering.** There are no CPU/GPU cache-maintenance
   ioctls.
   - The CPU reads an output only after that job's write fence (§2) has signalled.
   - The submit path keeps its barriers: ring write, `dsb sy`, GPPut, `dsb sy`, doorbell.
   - Completion is a semaphore release that the CPU reads after the fence.
   - `prep`/`fini` remain only as an ABI slot for non-coherent targets. On GB10 they check their arguments
     (§2 rules) and do nothing else.
2. **No BAR1 VRAM mapping.** BAR1 is off on this chip: RM reports it as size 0 (above), and sysfs shows BAR0
   only (lane design §1).
   - All buffers are sysmem: pinned pages, VFIO MAP_DMA, and GMMU PTEs with the snooped sysmem aperture.
   - The CPU's view of a buffer is the CPU's own mapping of those pages.
