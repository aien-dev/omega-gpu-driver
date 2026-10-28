# omega-gpu-driver design notes

Status: sections 1-3 are **PROPOSED**. Section 4 is **IMPLEMENTED and EXERCISED on the host only**.
Nothing here has run on GB10 hardware; hardware qualification is **NOT_RUN**.

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

1. **The proposed ordering model is fences plus memory ordering, not a coherency proof.**
   - The CPU reads an output only after that job's write fence (§2) has signalled.
   - The submit path keeps its barriers: ring write, `dsb sy`, GPPut, `dsb sy`, doorbell.
   - Completion is a semaphore release that the CPU reads after the fence.
   - `prep`/`fini` cannot yet be declared GB10 no-ops. NVIDIA 580.173.02
     `src/common/sdk/nvidia/inc/nvos.h:1117-1125` explicitly warns that GPU-cached system memory is
     not coherent with direct CPU mappings. A coherent C2C link alone does not settle GPU-cache policy.
2. **No BAR1 VRAM mapping.** BAR1 is off on this chip: RM reports it as size 0 (above), and sysfs shows BAR0
   only (lane design §1).
   - All buffers are sysmem: pinned pages, VFIO MAP_DMA, and GMMU PTEs with the snooped sysmem aperture.
   - The CPU's view of a buffer is the CPU's own mapping of those pages.

## 4. Owned userspace DMA window

`chan/gmmu.om` no longer presents the simulator's global `mmwin` array as hardware DMA backing.
`mmwinit` selects that array explicitly. `mmwalloc(iova, size)` instead owns one shared anonymous
read/write `mapnew` handle. CPU access uses that live handle plus a checked offset through
`mmrd32/64`, `mmwr8/32/64` and `mmzero`. The compiler's ordered word operations are used for aligned
32/64-bit accesses; zeroing handles byte tails separately. `mmwb` is an IOVA, `mmwcpu` is an
informational CPU virtual base, and a buffer's `gmbva` is its independent GPU VA. They are not aliases.

This is a Linux **userspace VFIO** backend, not an Omega Linux kernel module or replacement for
Linux's DMA/IOMMU implementation. It neither opens nor closes a VFIO fd, adopts a container, resets
a device, or changes authorization. The caller must already have sole lifecycle ownership of the
authorized container. No fork, fd close/reuse, concurrent caller, or process restart may invalidate
the recorded tuple while it is retained. The process-local quarantine latch is not crash-safe
containment and is not permission to run hardware.

The immutable live tuple is `(mmwgen, mmwh, mmws, mmwb, mmwfd)`: epoch, owned handle, whole length,
IOVA and container fd. `mmwgen` never wraps. Address-space, buffer and channel operations validate
their recorded window epoch; an old slot cannot become live merely because a new window exists.

| State | Allowed transition |
|---|---|
| NONE | `mmwalloc` -> OWN only after backing allocation succeeds |
| OWN | `mmwdmap(epoch, fd)` -> DMA only after whole-window MAP_DMA succeeds |
| DMA | `mmwpublish(epoch)` -> PUB **before** exposing any IOVA through boot args, mailbox, RPC, channel bind or page-directory register |
| OWN or DMA, never published | `mmwclose(epoch)` -> NONE; DMA requires successful full exact UNMAP_DMA before `mapdrop` |
| PUB | No reclaim/reset/reuse API; uncertain completion -> QUAR |
| QUAR | No reclaim/reset/reuse API, including after a modelled idle or successful TLB invalidation |

`chan/dma.om` reconstructs the request for every attempt: compiler `397e6704` replaces the vaddr
handle with the CPU base even when the ioctl fails. Only EBADF is classified as proven no-target
and remains OWN; other mapping errors retain uncertain ownership in QUAR without speculative
UNMAP_DMA. Failed unmap, zero/partial/oversized returned extent, or failed drop retain the handle.
The entire recorded range must be returned by UNMAP_DMA before drop. An unmap failure is never
converted into reclamation.

Publication is sticky even if the following operation fails. Page-table root publication latches
PUB before register writes; timeout latches QUAR. Owned page-table/allocator reset, mutation and
published-buffer reuse are refused. Simulator channel ops explicitly refuse owned backing rather
than walking the unrelated `mmwin` array. The boot/RPC caller must invoke `mmwpublish` before
serializing any DMA reference and `mmwquar` on uncertain post-publication completion. This backend
does not supply those GSP callsites or invent an idle proof. No documented, exercised GB10 idle
protocol exists here; published or quarantined memory therefore remains retained.

Sources: Linux `include/uapi/linux/vfio.h:1544-1615` (whole mapping and actual returned unmap size),
NVIDIA 580.173.02 `nvos.h:1117-1125` (cache policy warning), and
omega-mv `397e67040fb74853c6814097fe02ae4e1ebd6f66`, `seed/host/MAPPING.md:27-45,84-98`.
Pinned omc sha256: `bcfa582892afca8f65e551fe56867d918d86e84540c7381be8fa9ef18d0cf0f6`
(pending omega-mv#890 stacked on #878, not main).

Host evidence: `OMC=/path/to/pinned/omc sh tests/dma_host.sh` exercises anonymous memory, a real
invalid-fd refusal/retry, 23 explicit replay/boundary cases and 11 compiling negative-control mutants.
The replay transport is test-only link-time substitution, not a runtime fallback or DMA evidence.
`tests/chan_diff.sh` preserves the simulator's 391-line byte-identical C-reference trace.
Observed exit 0 for both gates. Replay binary sha256:
`06f290ccc82f33cfa2ae14b8a0604ba722988b93e6ff7299259b8779cc7a9575`;
production invalid-fd check binary sha256:
`e2dfe13d77b4ae92b91b2ae6751eb1f107420754547b4da5fddf56058697ec60`.
The gate emits source-file and binary checksums on each run; those are compiler/host evidence only.
No VFIO device was opened and no MMIO, DMA, reset, driver or service action was performed.
Hardware and Linux-kernel execution: **NOT_RUN**.
