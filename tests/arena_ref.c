/* Test-only oracle. Production composition is Omega; this links the unchanged pinned C builder.
 * Synthetic bytes are not authenticated firmware. No device access. */
#include "gb10_gsp_boot.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#define CAP 16777216u
static _Alignas(4096) unsigned char arena[CAP];
static unsigned char input[CAP], si[936], raw[65456], hdr[512];
static uint64_t cfg[10], src[7], sz[7];
static uint32_t r32(const unsigned char *p) { return (uint32_t)p[0]|(uint32_t)p[1]<<8|(uint32_t)p[2]<<16|(uint32_t)p[3]<<24; }
static void w64(unsigned off,uint64_t v) { for(unsigned i=0;i<8;i++) hdr[off+i]=(unsigned char)(v>>(8*i)); }
/* Independent decoding of canonical serialized registry; passed to C's own registry encoder. */
static int registry(gsp_reg_entry *e, unsigned *count) {
 uint64_t n=cfg[9]; *count=0; if(!n) return 1;
 if(n<8 || n>sizeof raw || r32(raw)!=n) return 0;
 unsigned c=r32(raw+4); if(!c || c>32 || 8u+16u*c>n) return 0;
 size_t p=8+16*c;
 for(unsigned i=0;i<c;i++) {
  const unsigned char *a=raw+8+16*i;
  if(r32(a)!=p || p>=n || !raw[p] || a[5] || a[6] || a[7]) return 0;
  e[i].name=(const char*)raw+p;
  const unsigned char *z=memchr(raw+p,0,n-p); if(!z) return 0;
  p=(size_t)(z-raw)+1; e[i].type=a[4]; e[i].dword=0; e[i].bytes=NULL; e[i].len=0;
  if(a[4]==1) { if(r32(a+12)!=4) return 0; e[i].dword=r32(a+8); }
  else { unsigned l=r32(a+12); if((a[4]!=2 && a[4]!=3)||!l||r32(a+8)!=p||l>n-p) return 0;
   e[i].bytes=raw+p; e[i].len=l; p+=l; }
 }
 if(p!=n) return 0;
 *count=c;
 return 1;
}
int main(void) {
 int m=getchar(); if(m==EOF) return 2;
 uint64_t base=1048576, cap=CAP, used=0;
 uint64_t init[]={1,40,268435456,8192,7,9,45056,2560,0,0}; memcpy(cfg,init,sizeof cfg);
 uint64_t sizes[]={4097,257,196608,4103,48,384,384}; memcpy(sz,sizes,sizeof sz);
 if(m==2) sz[0]=512u*4096u+1;
 size_t pos=0; for(unsigned s=0;s<7;s++) { src[s]=pos; for(uint64_t i=0;i<sz[s];i++) input[pos+i]=(unsigned char)(i*37+(s+1)*19); pos+=sz[s]; }
 for(unsigned i=0;i<936;i++) si[i]=(unsigned char)(i*13+129);
 if(m==1 || m==3 || m==4 || m>=30) { cfg[9]=26; raw[0]=26;raw[4]=1;raw[8]=24;raw[12]=1;raw[16]=239;raw[17]=190;raw[18]=173;raw[19]=222;raw[20]=4;raw[24]='X'; }
 if(m==3 || m==4) { cfg[9]=29;raw[0]=29;raw[12]=m==3?2:3;raw[16]=26;raw[17]=raw[18]=raw[19]=0;raw[20]=3;raw[26]=255;raw[27]=128;raw[28]=0; }
 switch(m) {
 case 10:cfg[0]=0;break; case 11:base++;break;
 case 12:cap=CAP-1;base=UINT64_MAX-4095;break;
 case 13:cfg[1]=0;break;case 14:cfg[1]=65;break;case 15:cfg[2]=0;break;case 16:cfg[3]=8193;break;
 case 17:cfg[6]=45055;break;case 18:sz[0]=0;break;case 19:src[1]=CAP;break;
 case 20:sz[2]=196607;break;case 21:sz[4]=47;break;case 22:cap=4096;break;
 case 23:cfg[1]=20;break;case 24:cfg[2]=UINT64_MAX-4095;break;case 25:used=4096;break;
 case 26:cfg[8]=1;break;case 27:cfg[4]=UINT64_C(1)<<32;break;case 28:cfg[9]=65457;break;
 case 29:sz[6]=383;break;case 30:raw[0]=25;break;case 31:raw[4]=33;break;
 case 32:raw[8]=25;break;case 33:raw[24]=0;break;case 34:raw[25]=88;break;
 case 35:raw[13]=1;break;case 36:raw[12]=4;break;case 37:raw[20]=3;break;
 case 38:raw[12]=2;raw[16]=26;raw[17]=raw[18]=raw[19]=0;raw[20]=1;break;
 case 39:cfg[1]=20;cfg[2]=4096;break;
 case 40:cfg[2]=4097;break;
 default:break;
 }
 /* Adapter checks contracts absent from pointer-based original API, before forming pointers. */
 if(cfg[0]!=1 || cfg[4]>UINT32_MAX || cfg[5]>UINT32_MAX || cap>CAP) return 3;
 for(unsigned i=0;i<7;i++) if(!sz[i] || src[i]>CAP || sz[i]>CAP-src[i]) return 3;
 if(sz[4]!=48 || sz[5]!=384 || sz[6]!=384 || cfg[3]>UINT64_MAX-cfg[2]) return 3;
 gsp_reg_entry regs[32]; unsigned nr; if(!registry(regs,&nr)) return 3;
 gsp_boot_in in={.rm_elf=input+src[0],.rm_elf_size=sz[0],.rm_sig=input+src[1],.rm_sig_size=sz[1],
  .bootloader=input+src[2],.bootloader_size=sz[2],.bl_code_off=cfg[6],.bl_data_off=cfg[7],.bl_manifest_off=cfg[8],
  .fmc=input+src[3],.fmc_size=sz[3],.fmc_hash=input+src[4],.fmc_pubkey=input+src[5],.fmc_sig=input+src[6],
  .sysmem_heap_pa=cfg[2],.sysmem_heap_size=cfg[3],.system_info=si,.regs=regs,.nregs=nr,
  .gpu_instance=cfg[4],.fmc_regkeys=cfg[5],.dma_bits=cfg[1]};
 gsp_arena a; gsp_boot_plan p; const char *why;
 if(gsp_arena_init(&a,arena,base,cap)) return 3;
 a.used=used;
 if(gsp_boot_build(&a,&in,&p,&why)) return 3;
 gsp_region regions[17]={p.wpr_meta,p.libos_args,p.log[0],p.log[1],p.log[2],p.log[3],p.log[4],p.log[5],p.log[6],p.args_cached,p.rpc_shared,p.radix3,p.bootloader,p.signature,p.fmc,p.fmc_params,{p.elf_data_pa,in.rm_elf_size}};
 w64(0,a.used);w64(8,p.cmdq_pa-base);w64(16,p.statq_pa-base);w64(24,p.tx_seq);w64(32,p.cot_packet_len);w64(40,p.emem_queue_tail);
 for(unsigned i=0;i<17;i++) { w64(48+i*8,regions[i].pa-base);w64(184+i*8,regions[i].size); }
 for(unsigned i=0;i<4;i++) w64(320+i*8,p.radix3_level_pages[i]);
 if(fwrite(hdr,1,sizeof hdr,stdout)!=sizeof hdr || fwrite(arena,1,a.used,stdout)!=a.used || fwrite(p.cot_packet,1,1024,stdout)!=1024) return 4;
 return 0;
}
