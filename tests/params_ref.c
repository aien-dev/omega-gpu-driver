/* tests/params_ref.c: TEST-ONLY C referee for chan/params.om. Never linked into the product.
 * Builds against the NVIDIA open-gpu-kernel-modules 580.173.02 headers (MIT) and fills every
 * record through NVIDIA's own struct types, field names and DRF macros, then prints the same
 * text tests/params_dump.om prints: per case "<label> rc=<rc>[ size=<sizeof>]" and the record
 * bytes in lowercase hex, 32 per line; then the class/RPC/control constants from the headers.
 * The refusal rules (value does not fit -1, outside the legal set -2, wrong reply length -3)
 * are the port's contract and are mirrored here so the negative controls are compared too.
 * Build: cc -std=c11 -O1 -Wall -Werror $OGKM_INC -o params_ref tests/params_ref.c */
#include <stdio.h>
#include <stddef.h>
#include <string.h>
#include "nvtypes.h"
#include "nvmisc.h"
#include "class/cl0000.h"
#include "class/cl0080.h"
#include "class/cl2080.h"
#include "class/cl90f1.h"
#include "class/cla06c.h"
#include "class/cl9067.h"
#include "class/clc96f.h"
#include "class/clcec0.h"
#include "nvos.h"
#include "alloc/alloc_channel.h"
#include "ctrl/ctrl0080/ctrl0080gr.h"
#include "ctrl/ctrl0080/ctrl0080dma.h"
#include "ctrl/ctrla06c.h"
#include "ctrl/ctrla06f/ctrla06fgpfifo.h"
#include "ctrl/ctrl2080/ctrl2080internal.h"
#include "ctrl/ctrl2080/ctrl2080fifo.h"
#include "vgpu/rpc_global_enums.h"
#define RPC_STRUCTURES
#include "g_rpc-structures.h"

/* kernel_channel internal flags (nvidia/generated/g_kernel_channel_nvoc.h:181-190) */
#define NV_KERNELCHANNEL_ALLOC_INTERNALFLAGS_PRIVILEGE               1:0
#define NV_KERNELCHANNEL_ALLOC_INTERNALFLAGS_ERROR_NOTIFIER_TYPE     3:2
#define NV_KERNELCHANNEL_ALLOC_INTERNALFLAGS_ECC_ERROR_NOTIFIER_TYPE 5:4

#define U32MAX 0xFFFFFFFFull
#define EFIT (-1)
#define ERANGE_ (-2)
#define ELEN (-3)

static unsigned char rec[4096];
static size_t reclen;
static unsigned char reply[4096];
static NvU64 in[48];

static int fit4(NvU64 a, NvU64 b, NvU64 c, NvU64 d)
{
    return a <= U32MAX && b <= U32MAX && c <= U32MAX && d <= U32MAX;
}

#define TAKE(s) do { memset(rec, 0, sizeof rec); memcpy(rec, &(s), sizeof(s)); reclen = sizeof(s); } while (0)

static int enc_root(NvU64 hcli, NvU64 pid)
{
    NV0000_ALLOC_PARAMETERS p;
    if (!fit4(hcli, pid, 0, 0)) return EFIT;
    memset(&p, 0, sizeof p);
    p.hClient = (NvHandle)hcli;
    p.processID = (NvU32)pid;
    memcpy(p.processName, "aien-ogd", 8);
    TAKE(p);
    return (int)sizeof p;
}

static int enc_device(NvU64 devid, NvU64 hshare, NvU64 flags, NvU64 vamode, NvU64 vasize)
{
    NV0080_ALLOC_PARAMETERS p;
    if (!fit4(devid, hshare, flags, vamode)) return EFIT;
    memset(&p, 0, sizeof p);
    p.deviceId = (NvU32)devid;
    p.hClientShare = (NvHandle)hshare;
    p.flags = (NvU32)flags;
    p.vaSpaceSize = vasize;
    p.vaMode = (NvV32)vamode;
    TAKE(p);
    return (int)sizeof p;
}

static int enc_subdev(NvU64 subid)
{
    NV2080_ALLOC_PARAMETERS p;
    if (subid > U32MAX) return EFIT;
    memset(&p, 0, sizeof p);
    p.subDeviceId = (NvU32)subid;
    TAKE(p);
    return (int)sizeof p;
}

static int enc_vaspace(NvU64 index, NvU64 flags, NvU64 vasize, NvU64 vabase, NvU64 bigpg)
{
    NV_VASPACE_ALLOCATION_PARAMETERS p;
    if (!fit4(index, flags, bigpg, 0)) return EFIT;
    memset(&p, 0, sizeof p);
    p.index = (NvU32)index;
    p.flags = (NvV32)flags;
    p.vaSize = vasize;
    p.bigPageSize = (NvU32)bigpg;
    p.vaBase = vabase;
    TAKE(p);
    return (int)sizeof p;
}

static int enc_tsg(NvU64 herr, NvU64 hecc, NvU64 hvas, NvU64 eng)
{
    NV_CHANNEL_GROUP_ALLOCATION_PARAMETERS p;
    if (!fit4(herr, hecc, hvas, eng)) return EFIT;
    memset(&p, 0, sizeof p);
    p.hObjectError = (NvHandle)herr;
    p.hObjectEccError = (NvHandle)hecc;
    p.hVASpace = (NvHandle)hvas;
    p.engineType = (NvU32)eng;
    p.bIsCallingContextVgpuPlugin = NV_FALSE;
    TAKE(p);
    return (int)sizeof p;
}

static int enc_ctxsh(NvU64 hvas, NvU64 flags, NvU64 subctx)
{
    NV_CTXSHARE_ALLOCATION_PARAMETERS p;
    if (!fit4(hvas, flags, subctx, 0)) return EFIT;
    memset(&p, 0, sizeof p);
    p.hVASpace = (NvHandle)hvas;
    p.flags = (NvU32)flags;
    p.subctxId = (NvU32)subctx;
    TAKE(p);
    return (int)sizeof p;
}

static int wide(int k)
{
    return k == 1 || k == 7 || (k >= 16 && k <= 35 && (k - 16) % 4 < 2) || k == 38 || k == 39;
}

static void md(NV_MEMORY_DESC_PARAMS *m, int k)
{
    m->base = in[k];
    m->size = in[k + 1];
    m->addressSpace = (NvU32)in[k + 2];
    m->cacheAttrib = (NvU32)in[k + 3];
}

static int enc_chan(void)
{
    NV_CHANNEL_ALLOC_PARAMS p;
    NvU32 chid, flags, numChannelsPerUserd, internal;
    for (int k = 0; k < 42; k++)
        if (!wide(k) && in[k] > U32MAX) return EFIT;
    if (in[12] > 3 || in[13] > 3 || in[14] > 3) return ERANGE_;
    if (in[15] > 0xFFF) return ERANGE_;
    chid = (NvU32)in[15];
    memset(&p, 0, sizeof p);
    p.hObjectError = (NvHandle)in[0];
    p.gpFifoOffset = in[1];
    p.gpFifoEntries = (NvU32)in[2];
    /* kernel_channel.c:2812-2821, the IS_GSP_CLIENT rewrite */
    numChannelsPerUserd = NVBIT(DRF_SIZE(NVOS04_FLAGS_CHANNEL_USERD_INDEX_VALUE));
    flags = (NvU32)in[3];
    flags = FLD_SET_DRF(OS04, _FLAGS, _CHANNEL_USERD_INDEX_FIXED, _FALSE, flags);
    flags = FLD_SET_DRF(OS04, _FLAGS, _CHANNEL_USERD_INDEX_PAGE_FIXED, _TRUE, flags);
    flags = FLD_SET_DRF_NUM(OS04, _FLAGS, _CHANNEL_USERD_INDEX_VALUE, chid % numChannelsPerUserd, flags);
    flags = FLD_SET_DRF_NUM(OS04, _FLAGS, _CHANNEL_USERD_INDEX_PAGE_VALUE, chid / numChannelsPerUserd, flags);
    p.flags = flags;
    p.hContextShare = (NvHandle)in[4];
    p.hVASpace = (NvHandle)in[5];
    p.hUserdMemory[0] = (NvHandle)in[6];
    p.userdOffset[0] = in[7];
    p.engineType = (NvU32)in[8];
    p.subDeviceId = (NvU32)in[9];
    p.hObjectEccError = (NvHandle)in[10];
    md(&p.instanceMem, 16);
    md(&p.userdMem, 20);
    md(&p.ramfcMem, 24);
    md(&p.mthdbufMem, 28);
    p.hPhysChannelGroup = (NvHandle)in[11];
    /* kernel_channel.c:602-609 then :2824-2826 */
    internal = 0;
    internal = FLD_SET_DRF_NUM(_KERNELCHANNEL_ALLOC, _INTERNALFLAGS, _ERROR_NOTIFIER_TYPE, (NvU32)in[12], internal);
    internal = FLD_SET_DRF_NUM(_KERNELCHANNEL_ALLOC, _INTERNALFLAGS, _ECC_ERROR_NOTIFIER_TYPE, (NvU32)in[13], internal);
    internal = FLD_SET_DRF_NUM(_KERNELCHANNEL_ALLOC, _INTERNALFLAGS, _PRIVILEGE, (NvU32)in[14], internal);
    p.internalFlags = internal;
    md(&p.errorNotifierMem, 32);
    md(&p.eccErrorNotifierMem, 38);
    p.ProcessID = (NvU32)in[36];
    p.SubProcessID = (NvU32)in[37];
    TAKE(p);
    return (int)sizeof p;
}

static int enc_sched(NvU64 en, NvU64 skipsub, NvU64 skipen)
{
    NVA06C_CTRL_GPFIFO_SCHEDULE_PARAMS p;
    if (en > 1 || skipsub > 1 || skipen > 1) return ERANGE_;
    memset(&p, 0, sizeof p);
    p.bEnable = (NvBool)en;
    p.bSkipSubmit = (NvBool)skipsub;
    p.bSkipEnable = (NvBool)skipen;
    TAKE(p);
    return (int)sizeof p;
}

static int enc_grinfo(void)
{
    static NV2080_CTRL_INTERNAL_STATIC_GR_GET_INFO_PARAMS p;
    memset(&p, 0, sizeof p);
    TAKE(p);
    return (int)sizeof p;
}

static long long smver(NvU64 eng, size_t len)
{
    static NV2080_CTRL_INTERNAL_STATIC_GR_GET_INFO_PARAMS p;
    if (len != sizeof p) return ELEN;
    if (eng >= NV2080_CTRL_INTERNAL_GR_MAX_ENGINES) return ERANGE_;
    memcpy(&p, reply, sizeof p);
    return p.engineInfo[eng].infoList[NV0080_CTRL_GR_INFO_INDEX_SM_VERSION].data;
}

static int enc_setpd(void)
{
    rpc_set_page_directory_v1E_05 p;
    NvU32 flags;
    for (int k = 0; k < 11; k++)
        if (k != 3 && in[k] > U32MAX) return EFIT;
    if (in[5] > NV0080_CTRL_DMA_SET_PAGE_DIRECTORY_FLAGS_APERTURE_SYSMEM_NONCOH || in[6] > 1) return ERANGE_;
    memset(&p, 0, sizeof p);
    p.hClient = (NvHandle)in[0];
    p.hDevice = (NvHandle)in[1];
    p.pasid = (NvU32)in[2];
    p.params.physAddress = in[3];
    p.params.numEntries = (NvU32)in[4];
    flags = 0;
    flags = FLD_SET_DRF_NUM(0080, _CTRL_DMA_SET_PAGE_DIRECTORY_FLAGS, _APERTURE, (NvU32)in[5], flags);
    flags = FLD_SET_DRF_NUM(0080, _CTRL_DMA_SET_PAGE_DIRECTORY_FLAGS, _PRESERVE_PDES, (NvU32)in[6], flags);
    p.params.flags = flags;
    p.params.hVASpace = (NvHandle)in[7];
    p.params.chId = (NvU32)in[8];
    p.params.subDeviceId = (NvU32)in[9];
    p.params.pasid = (NvU32)in[10];
    TAKE(p);
    return (int)sizeof p;
}

static int enc_unsetpd(NvU64 hcli, NvU64 hdev, NvU64 hvas, NvU64 subdev)
{
    rpc_unset_page_directory_v1E_05 p;
    if (!fit4(hcli, hdev, hvas, subdev)) return EFIT;
    memset(&p, 0, sizeof p);
    p.hClient = (NvHandle)hcli;
    p.hDevice = (NvHandle)hdev;
    p.params.hVASpace = (NvHandle)hvas;
    p.params.subDeviceId = (NvU32)subdev;
    TAKE(p);
    return (int)sizeof p;
}

static void show(const char *label, long long rc)
{
    printf("%s rc=%lld", label, rc);
    if (rc <= 0) {
        printf("\n");
        return;
    }
    printf(" size=%zu\n", reclen);
    for (size_t i = 0; i < reclen; i++)
        printf("%02x%s", rec[i], (i % 32 == 31 || i + 1 == reclen) ? "\n" : "");
}

static void chan_inputs(void)
{
    for (int k = 0; k < 48; k++)
        in[k] = wide(k) ? (NvU64)k * 0x0101010101010101ull + 2 : (NvU64)k * 0x01010101ull + 1;
    in[3] = 0xFFFFFFFFull;
    in[8] = NV2080_ENGINE_TYPE_GRAPHICS;
    in[12] = 3;
    in[13] = 2;
    in[14] = 2;
    in[15] = 4011;
}

static void setpd_inputs(void)
{
    memset(in, 0, sizeof in);
    in[0] = 3254779905u;
    in[1] = 3254779906u;
    in[2] = 0;
    in[3] = 2147745792ull;
    in[4] = 512;
    in[5] = 2;
    in[6] = 1;
    in[7] = 3254779912u;
    in[8] = 4011;
    in[9] = 0;
    in[10] = 0;
}

int main(void)
{
    show("NV0000_ALLOC_PARAMETERS root", enc_root(3254779905u, 4242));
    show("NV0000_ALLOC_PARAMETERS root hClient>u32", enc_root(4294967296ull, 1));
    show("NV0080_ALLOC_PARAMETERS device", enc_device(0, 3254779905u, 3, 2, 1099511627776ull));
    show("NV0080_ALLOC_PARAMETERS device vaMode>u32", enc_device(0, 3254779905u, 3, 4294967296ull, 0));
    show("NV2080_ALLOC_PARAMETERS subdevice", enc_subdev(0));
    show("NV2080_ALLOC_PARAMETERS subdevice id>u32", enc_subdev(4294967296ull));
    show("NV_VASPACE_ALLOCATION_PARAMETERS vaspace",
         enc_vaspace(0, NV_VASPACE_ALLOCATION_FLAGS_IS_EXTERNALLY_OWNED | NV_VASPACE_ALLOCATION_FLAGS_ENABLE_PAGE_FAULTING,
                     1099511627776ull, 8589934592ull, 65536));
    show("NV_VASPACE_ALLOCATION_PARAMETERS vaspace bigPageSize>u32", enc_vaspace(0, 72, 1, 0, 4294967296ull));
    show("NV_CHANNEL_GROUP_ALLOCATION_PARAMETERS tsg", enc_tsg(0, 0, 3254779912u, NV2080_ENGINE_TYPE_GRAPHICS));
    show("NV_CHANNEL_GROUP_ALLOCATION_PARAMETERS tsg engineType>u32", enc_tsg(0, 0, 3254779912u, 4294967296ull));
    show("NV_CTXSHARE_ALLOCATION_PARAMETERS ctxshare",
         enc_ctxsh(3254779912u, NV_CTXSHARE_ALLOCATION_FLAGS_SUBCONTEXT_ASYNC, 0));
    show("NV_CTXSHARE_ALLOCATION_PARAMETERS ctxshare flags>u32", enc_ctxsh(3254779912u, 4294967296ull, 0));
    chan_inputs();
    show("NV_CHANNEL_ALLOC_PARAMS channel", enc_chan());
    in[15] = 4096;
    show("NV_CHANNEL_ALLOC_PARAMS channel chid=4096", enc_chan());
    in[15] = 4011;
    in[2] = 4294967296ull;
    show("NV_CHANNEL_ALLOC_PARAMS channel gpFifoEntries>u32", enc_chan());
    in[2] = 2 * 0x01010101ull + 1;
    in[14] = 4;
    show("NV_CHANNEL_ALLOC_PARAMS channel privilege=4", enc_chan());
    in[14] = 2;
    in[15] = 0;
    show("NV_CHANNEL_ALLOC_PARAMS channel chid=0", enc_chan());
    show("NVA06C_CTRL_GPFIFO_SCHEDULE_PARAMS schedule", enc_sched(1, 0, 0));
    show("NVA06C_CTRL_GPFIFO_SCHEDULE_PARAMS schedule bEnable=2", enc_sched(2, 0, 0));
    show("NV2080_CTRL_INTERNAL_STATIC_GR_GET_INFO_PARAMS grinfo", enc_grinfo());
    setpd_inputs();
    show("rpc_set_page_directory_v1E_05 setpd", enc_setpd());
    in[5] = 3;
    show("rpc_set_page_directory_v1E_05 setpd aperture=3", enc_setpd());
    in[5] = 2;
    in[4] = 4294967296ull;
    show("rpc_set_page_directory_v1E_05 setpd numEntries>u32", enc_setpd());
    show("rpc_unset_page_directory_v1E_05 unsetpd", enc_unsetpd(3254779905u, 3254779906u, 3254779912u, 0));
    show("rpc_unset_page_directory_v1E_05 unsetpd hVASpace>u32", enc_unsetpd(3254779905u, 3254779906u, 4294967296ull, 0));
    for (int i = 0; i < 3712; i++)
        reply[i] = (unsigned char)((i * 7 + 3) & 255);
    printf("smver eng=0 rc=%lld\n", smver(0, 3712));
    printf("smver eng=7 rc=%lld\n", smver(7, 3712));
    printf("smver eng=8 rc=%lld\n", smver(8, 3712));
    printf("smver len=3711 rc=%lld\n", smver(0, 3711));
    printf("const NV01_ROOT %u\n", (unsigned)NV01_ROOT);
    printf("const NV01_DEVICE_0 %u\n", (unsigned)NV01_DEVICE_0);
    printf("const NV20_SUBDEVICE_0 %u\n", (unsigned)NV20_SUBDEVICE_0);
    printf("const FERMI_VASPACE_A %u\n", (unsigned)FERMI_VASPACE_A);
    printf("const KEPLER_CHANNEL_GROUP_A %u\n", (unsigned)KEPLER_CHANNEL_GROUP_A);
    printf("const FERMI_CONTEXT_SHARE_A %u\n", (unsigned)FERMI_CONTEXT_SHARE_A);
    printf("const BLACKWELL_CHANNEL_GPFIFO_A %u\n", (unsigned)BLACKWELL_CHANNEL_GPFIFO_A);
    printf("const BLACKWELL_COMPUTE_B %u\n", (unsigned)BLACKWELL_COMPUTE_B);
    printf("const NV_VGPU_MSG_FUNCTION_SET_PAGE_DIRECTORY %u\n", (unsigned)NV_VGPU_MSG_FUNCTION_SET_PAGE_DIRECTORY);
    printf("const NV_VGPU_MSG_FUNCTION_GSP_RM_CONTROL %u\n", (unsigned)NV_VGPU_MSG_FUNCTION_GSP_RM_CONTROL);
    printf("const NV_VGPU_MSG_FUNCTION_UNSET_PAGE_DIRECTORY %u\n", (unsigned)NV_VGPU_MSG_FUNCTION_UNSET_PAGE_DIRECTORY);
    printf("const NV_VGPU_MSG_FUNCTION_GSP_RM_ALLOC %u\n", (unsigned)NV_VGPU_MSG_FUNCTION_GSP_RM_ALLOC);
    printf("const NVA06C_CTRL_CMD_GPFIFO_SCHEDULE %u\n", (unsigned)NVA06C_CTRL_CMD_GPFIFO_SCHEDULE);
    printf("const NV2080_CTRL_CMD_INTERNAL_STATIC_KGR_GET_INFO %u\n", (unsigned)NV2080_CTRL_CMD_INTERNAL_STATIC_KGR_GET_INFO);
    printf("const NV2080_ENGINE_TYPE_GRAPHICS %u\n", (unsigned)NV2080_ENGINE_TYPE_GRAPHICS);
    printf("const NV_CTXSHARE_ALLOCATION_FLAGS_SUBCONTEXT_ASYNC %u\n", (unsigned)NV_CTXSHARE_ALLOCATION_FLAGS_SUBCONTEXT_ASYNC);
    return 0;
}
