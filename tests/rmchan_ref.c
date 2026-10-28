/* Verification-only oracle. Never linked into driver; headers are NVIDIA
 * open-gpu-kernel-modules 580.173.02@20e4e6e19cc26ba47b5cbe23130a396be100c427.
 * Checks observed RM transitions and queued request identity, class, size,
 * schedule flags, and free order. Parameter bytes have the existing params oracle.
 * Policy error values and host peer semaphore progress are not hardware evidence. */
#include <stdio.h>
#include <stdint.h>
#include "nvtypes.h"
#include "nvmisc.h"
#include "class/cl0000.h"
#include "class/cl0080.h"
#include "class/cl2080.h"
#include "class/cl90f1.h"
#include "class/cla06c.h"
#include "class/cl9067.h"
#include "class/clc96f.h"
#include "nvos.h"
#include "alloc/alloc_channel.h"
#include "ctrl/ctrla06c.h"
#include "ctrl/ctrla06f/ctrla06fgpfifo.h"
#include "vgpu/rpc_global_enums.h"
static const uint32_t cli=3254779905u, dev=3254779906u, sub=3254779907u,
                      vas=3254779912u, tsg=3254779913u, ctx=3254779914u, ch=3254779915u;
static void step(int id, int state, unsigned f, int rc)
{ printf("step %d state=%d fn=%u rc=%d\n",id,state,f,rc); }
static void cap(int id,int rc) { printf("cap %d rc=%d\n",id,rc); }
static void alloc(uint32_t par,uint32_t obj,uint32_t cls,size_t n)
{ printf("req %u cli=%u par=%u obj=%u cls=%u n=%zu\n",
         NV_VGPU_MSG_FUNCTION_GSP_RM_ALLOC,cli,par,obj,cls,n); }
static void sched(NvBool en)
{ NVA06C_CTRL_GPFIFO_SCHEDULE_PARAMS p={0}; p.bEnable=en;
  printf("req %u cli=%u obj=%u cls=%u en=%u\n",
         NV_VGPU_MSG_FUNCTION_GSP_RM_CONTROL,cli,tsg,
         NVA06C_CTRL_CMD_GPFIFO_SCHEDULE,(unsigned)p.bEnable); }
static void freeobj(uint32_t obj)
{ printf("req %u cli=%u obj=%u\n",NV_VGPU_MSG_FUNCTION_FREE,cli,obj); }
int main(void)
{
 cap(30,-1); cap(31,-10); cap(29,-5); cap(32,0); cap(33,-3); cap(34,-4); cap(35,-3);
 step(1,1,NV_VGPU_MSG_FUNCTION_GSP_RM_ALLOC,0);
 puts("seq 1 rc=2 st=11"); puts("seq 2 rc=2 st=11");
 puts("seq 3 rc=-10 st=11"); puts("seq 4 rc=0 st=10");
 alloc(0,cli,NV01_ROOT,sizeof(NV0000_ALLOC_PARAMETERS)); step(2,2,NV_VGPU_MSG_FUNCTION_GSP_RM_ALLOC,1);
 alloc(cli,dev,NV01_DEVICE_0,sizeof(NV0080_ALLOC_PARAMETERS)); step(3,3,NV_VGPU_MSG_FUNCTION_GSP_RM_ALLOC,1);
 alloc(dev,sub,NV20_SUBDEVICE_0,sizeof(NV2080_ALLOC_PARAMETERS)); step(4,4,NV_VGPU_MSG_FUNCTION_GSP_RM_ALLOC,1);
 alloc(dev,vas,FERMI_VASPACE_A,sizeof(NV_VASPACE_ALLOCATION_PARAMETERS)); step(5,5,NV_VGPU_MSG_FUNCTION_GSP_RM_ALLOC,1);
 alloc(dev,tsg,KEPLER_CHANNEL_GROUP_A,sizeof(NV_CHANNEL_GROUP_ALLOCATION_PARAMETERS)); step(6,6,NV_VGPU_MSG_FUNCTION_GSP_RM_ALLOC,1);
 alloc(tsg,ctx,FERMI_CONTEXT_SHARE_A,sizeof(NV_CTXSHARE_ALLOCATION_PARAMETERS)); step(7,7,NV_VGPU_MSG_FUNCTION_GSP_RM_ALLOC,1);
 alloc(dev,ch,BLACKWELL_CHANNEL_GPFIFO_A,sizeof(NV_CHANNEL_ALLOC_PARAMS)); step(8,8,0,1);
 step(9,9,NV_VGPU_MSG_FUNCTION_GSP_RM_CONTROL,0); sched(1); step(10,10,0,1);
 cap(36,-1); cap(37,-1); cap(38,-3); cap(39,0); cap(40,-5);
 step(11,11,NV_VGPU_MSG_FUNCTION_GSP_RM_CONTROL,0); cap(41,-3);
 sched(0); step(12,12,0,1); cap(42,-3);
 step(13,14,NV_VGPU_MSG_FUNCTION_FREE,0);
 freeobj(ch); step(14,15,NV_VGPU_MSG_FUNCTION_FREE,1);
 freeobj(ctx); step(15,16,NV_VGPU_MSG_FUNCTION_FREE,1);
 freeobj(tsg); step(16,17,NV_VGPU_MSG_FUNCTION_FREE,1);
 freeobj(vas); step(17,18,NV_VGPU_MSG_FUNCTION_FREE,1);
 freeobj(sub); step(18,19,NV_VGPU_MSG_FUNCTION_FREE,1);
 freeobj(dev); step(19,20,NV_VGPU_MSG_FUNCTION_FREE,1);
 freeobj(cli); step(20,21,0,1);
 cap(43,-3); cap(44,-3); cap(45,0); cap(46,-3); cap(47,-4);
 return 0;
}
