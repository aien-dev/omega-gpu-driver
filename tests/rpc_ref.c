/* Test-only oracle. Never linked into the Omega driver. Builds against pinned aienux C. */
#include "gb10_gsp_boot.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static unsigned char cmd[GSP_MQ_QUEUE_SIZE], stat[GSP_MQ_QUEUE_SIZE];
static void put(unsigned char *p, unsigned v) { for(unsigned i=0;i<4;i++)p[i]=(unsigned char)(v>>(8*i)); }
static void init(unsigned char *p) {
 put(p+4,GSP_MQ_QUEUE_SIZE);put(p+8,GSP_MQ_MSG_SIZE);put(p+12,GSP_MQ_MSG_COUNT);
 put(p+20,1);put(p+24,32);put(p+28,4096);
}
static void emit(void) { if(fwrite(cmd,1,sizeof cmd,stdout)!=sizeof cmd)exit(2); }
int main(void) {
 gsp_mq q={cmd,stat,0,0,0}; const char *why=0; unsigned seq;
 init(cmd); init(stat);
 unsigned char payload[8192];for(unsigned i=0;i<sizeof payload;i++)payload[i]=(unsigned char)i;
 gsp_seg s={payload,17};
 if(gsp_mq_send(&q,72,&s,1,17,0,&seq,&why))return 3;
 emit();
 s.len=8192;
 if(gsp_mq_send(&q,76,&s,1,8192,1,&seq,&why))return 4;
 emit();
 /* Force a wrapped two-slot command, peer read pointer is in stat, not cmd. */
 put(cmd+16,62);put(stat+32,10);s.len=4020;
 if(gsp_mq_send(&q,76,&s,1,4020,1,&seq,&why))return 5;
 emit();
 /* Existing paroot encoder: match its independent NV0000_ALLOC_PARAMETERS fixture. */
 unsigned char root[120]={0};put(root,7);put(root+4,42);memcpy(root+8,"aien-ogd",8);
 if(gsp_rpc_rm_alloc(&q,7,0,7,0,root,sizeof root,&seq,&why))return 6;
 emit();
 return 0;
}
