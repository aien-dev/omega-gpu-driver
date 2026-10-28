# GB20B source-selected SEC2 candidate

Status: IMPLEMENTED, host simulator EXERCISED only. Physical W0, firmware boot, RPC,
resources, queues and compute on the Spark remain NOT_RUN in this qualification.
No merge, deployment, service stop, VFIO bind/open, reset or BAR access is authorized here.

## Authorities and deliberate oracle correction

NVIDIA open-gpu-kernel-modules tag 580.173.02, exact revision
`20e4e6e19cc26ba47b5cbe23130a396be100c427`, is the vendor authority. The physics
third_party copy is pruned; qualification used an unmodified full checkout of that revision.
`src/nvidia/generated/g_kernel_sec2_nvoc.c:674-804` selects different preparation,
MCTP-header and send/receive HALs for GB10B and GB20B. It shares the low-level command
queue send implementation. The generated GSP HAL selects GB20B boot and production
FMC archives at `g_kernel_gsp_nvoc.c:792-795,928-930`; WPR metadata remains GB10B's
implementation at lines 986-989. Do not substitute the GB10B archives.

The C reference moved deliberately from aienux `c5bb3a4b9898257658aba0b7178a3c73a0371c27`
to #463 `a108b1144a064aa7b824374a622d627c6ba91fd1`. Both the former C reference and
Omega encoded GB10B MCTP SOM|EOM as 0xc0000000. The vendor GB10B HAL
`ksec2CreateMctpHeader_539ab4` actually returns 1. The corrected C arena and simulator
are the independent oracle; arena and RPC gates pin the same complete reference revision.
`mutants-arena.sh` reinstates the old value and requires an exact-byte parity failure.
This is an oracle correction, not evidence the previous common-mode comparison was correct.

## Distinct profile, not a relaxed GB10 gate

| Property | GB10B | GB20B |
|---|---|---|
| BOOT_42 architecture / implementation | 0x1a / 0xb | 0x1b / 0xb |
| signed ELF family | gb10y | gb20y |
| boot / FMC generated archive suffix | GB10B | GB20B |
| MCTP first word for single COT | 1 | 0xc0000000 (SOM, EOM, SEID=SEQ=0) |
| COT version / packed payload bytes | 1 / 860 | 2 / 860 |
| FRTS sysmem size | FMC image bytes (GB10B HAL quirk) | zero |
| prerequisite | existing GB10B flow | FWSEC scratch 0x5e0 == 0xff |
| send completion | SEC2 busy mailbox consumed | MSGQ response, SEC2_RESPONSE 0x15, command COT 0x14, FSP_OK |

`gsp/profile.om:gpclass` classifies the second profile separately. `gpchip` and the
existing mapped transport admission remain GB10B-only: GB20B classification does not
admit GB10B system-info records or a GB10B package. No actual BOOT_42 has been measured.

`gsp/arena.om` now composes either profile. For profile 2, `arpkg[0..3)` must each be
2 (gb20y signed-image family, GB20B boot archive, GB20B FMC archive respectively).
Boot code/data/manifest offsets must be inside the supplied boot image; GB10B fixed
sizes are not applied to GB20B. Common WPR/FMC-args layout follows the generated shared
WPR HAL. The selected FMC and its 48-byte hash, 384-byte key and 384-byte signature
are copied to the bounded aligned arena. COT v2 leaves every FRTS field zero.
These profile assertions describe the caller's checked extraction, NOT cryptographic
verification. Existing `fwprep` still extracts GB10B only; it is NOT a GB20B package
loader. A composed caller must extract and validate the distinct GB20B archives and
select gb20y before setting these fields. Passing GB10B bytes and lying about their
provenance is not supported or authenticated by this library.

`gsp/sec2.om:s2boot` takes actual BOOT_42 plus explicit profile/package and refuses a
mismatch before register access. It requires silicon, SEC2 present and FMC enabled;
waits for FWSEC secure boot; sends the complete 868-byte single packet on command
queue 0; waits on MSGQ rather than GB10B's mailbox; reads bounded response EMEM with
AINCR; verifies pointer progress, acknowledges tail before head, checks vendor/type,
COT command and error; then runs the shared GSP mask/lockdown/FMC/CPU-active completion.
Source: `kernel_sec2_gb20b.c:280-536,547-549,962-1085`, `kernel_sec2.c:250-593`,
`sec2_mctp_format.h:34-53`, `nvdm_payload_cmd_response.h` and `kern_fsp_cot_payload.h`.
Unsupported fragmented responses, malformed sizes and nonzero firmware errors refuse.
Task ID is captured, not interpreted as a GSP RPC sequence number.

The vendor secure-boot deadline is max(scaled four seconds, default GPU timeout).
This library receives finite poll budgets; a native caller must implement that timer
policy with its own monotonic clock and approved pause. No production timing or reset
policy is asserted by a synthetic check-count simulation. Warm/resume, confidential
compute and firmware debug variants are not implemented by this cold-production path.

## Composed launcher and native effect seam

`build.sh` builds ONLY `build/w0` and `build/fwprep`. There is no `build/ogd`, no composed
`boot`, `hello` or `exec`, and no end-to-end native GPU startup. Host units cover
protocol building, modeled boot/RPC, resource records and queue/completion ownership;
their passing tests do not create a launcher. `gsp/dispatch.om` still refuses hardware.
`chan/dma.om` and `gsp/mmio.om` target Linux VFIO/map handles, NOT native Aienux capabilities.

The missing native seam is concrete: load/relocate/link the .om unit to a kernel ABI;
provide non-forgeable profile-bound PCI/MMIO, SMMU-owned DMA-window and IRQ capabilities;
keep CPU VA, IOVA and GPU VA distinct; enforce ordered publish/MMIO/cache visibility;
submit a GPU store and engine/system visibility fence; observe uncached completion;
then prove engine quiescence or bus-master-off before SMMU abort/unmap/reclaim. Current
published/quarantined windows intentionally cannot be reclaimed. A Linux invalid-fd
or anonymous-memory test is not this seam. Neither this SEC2 candidate nor a BOOT_42
read establishes GPU-initiated DMA containment or compute.

## Minimal W0 identity authorization request (not execution)

Request only one `build/w0 000f:01:00.0 20` invocation, no optional HEXOFF, after an
exclusive approved window and a fresh boot with NVIDIA held back. It reads PCI config
and BOOT_0/1/42 through pread and read-only BAR mapping and compares both views.
**Opening VFIO can implicitly FLR the GPU; closing/releasing it can SBR its parent
000f:00:00.0. Read-only register intent is NOT reset-free.** Empty reset_method does
not prevent release SBR. This cannot run beside the resident service on 18091.

Before authorization, parent must recheck current BDF, singleton IOMMU group, privileges,
pinned w0/compiler and restore recipe; obtain a current spark-window/quietlock reservation
and Drake's explicit approval for service stop, two reboots, VFIO bind/open and FLR/SBR.
The existing recovery stick is read-only: serial 5D0344B4, PARTUUID
f227357c-1e80-4fd0-a55e-2efbef1dd25c, current firmware Boot0002. Its historical attended
recovery proof is 2026-09-25, NOT a recovery boot today. Never overwrite it. See the
parent's `recovery-stick-readonly-20261028.md`; a candidate image needs a separate medium.

Exact proposed existing-script procedure, only after those authorizations:

1. Freeze and hash this checkout and binaries. `test ! -e build/ogd` is REQUIRED.
   Run `sh window/d2-pre.sh` (preflight only). The parent verifies it records the exact
   resident process argv/cwd/environment/coordinator restore key and no other GPU users.
   This must not be inferred from a stale receipt. Do not use `--go` before approval.
2. Parent records Drake's exact approved window in
   `/home/drakestapleton/handoffs/OwnDriver/window/APPROVED` using the existing three
   lines (`window: ...`, `reset: approved`, `reboot: approved`). Then from this frozen
   checkout: `sh window/d2-pre.sh --go D2`. Here D2 is only the existing recovery runner:
   **no ogd may exist or be introduced until the window closes**. No boot/hello/exec
   invocation is authorized. Do not replace it with a firmware-boot test.
3. W1 takes the chip lock, stops the process serving 18091, waits for no compute apps,
   records sysctls, installs temporary NVIDIA hold-back and recovery unit, and reboots.
   W2 sets restore state/removes hold-back FIRST, checks no NVIDIA modules, binds VFIO
   and requires root:root:0600. W3 requires runtime-active and executes precisely
   `sudo -n build/w0 000f:01:00.0 20`. Expected: config identity plus BOOT_0/1/42,
   successful pread/map comparison, exit 0. Record actual BOOT_42; do not manufacture
   an expected hexadecimal value from NVIDIA marketing or Linux RM chip naming.
4. With ogd absent, the runner MUST log boot and hello NOT_RUN, then unbind VFIO
   (possible SBR), clear override/PM, and reboot to the NVIDIA-enabled normal boot.
   R loads/rebinds NVIDIA, restores saved sysctls and the exact recorded resident
   launch recipe, waits for 18091 `/v1/models`, checks one greedy chat and exactly
   one resident GPU process, removes the temporary unit and checks privileges.
5. Any failure follows W7/R, not a retrying GPU probe. The runner has one reboot
   fallback. If restore still fails, stop and require Drake's physical power-cycle /
   attended recovery procedure. Preserve logs. W0 identity success is not firmware,
   RPC, DMA or compute qualification. Firmware loading stays NOT_RUN.

The D2 label does not grant additional authority: if `build/ogd` exists, this procedure
REFUSES before starting; a W0-only stage would be needed before authorizing that tree.
The live 18091 must remain untouched until the parent relays exact current approval.
