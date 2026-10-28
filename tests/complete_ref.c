/* tests/complete_ref.c: TEST-ONLY C referee for chan/complete.om. Never linked into driver.
 * Builds against NVIDIA open-gpu-kernel-modules 580.173.02 headers (MIT).
 * Compares exact command encodings, wrap-safe progress math, capability refusals,
 * and timeout quarantine latch with tests/complete_trace.om. */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <stdbool.h>
#include <string.h>

#include "nvtypes.h"
#include "nvmisc.h"
#include "class/clc96f.h"

#define CMOK 0
#define CMEINVAL (-1)
#define CMEALIGN (-2)
#define CMERANGE (-3)
#define CMESTATE (-4)
#define CMESTALE (-5)
#define CMEFULL  (-6)
#define CMEGEN   (-10)
#define CMETIME  (-11)
#define CMEQUAR  (-12)

#define CHNINC 0x20000000u
#define CMSEMM (NVC96F_SEM_ADDR_LO >> 2) /* 23 */
#define MMVALIM (1ULL << 57)

static uint32_t cmhdr(uint32_t subc, uint32_t count)
{
    return CHNINC | ((count & 0x3ff) << 16) | ((subc & 7) << 13) | CMSEMM;
}

static int cmrel(uint32_t subc, uint64_t va, uint32_t seq, uint32_t *wds)
{
    if (subc > 7) return CMEINVAL;
    if ((va & 3) != 0) return CMEALIGN;
    if (va == 0 || va >= MMVALIM) return CMERANGE;
    wds[0] = cmhdr(subc, 5);
    wds[1] = (uint32_t)(va & 0xFFFFFFFCULL);
    wds[2] = (uint32_t)((va >> 32) & 0x1FFFFFFULL);
    wds[3] = seq;
    wds[4] = 0;
    wds[5] = DRF_DEF(C96F, _SEM_EXECUTE, _OPERATION, _RELEASE) |
             DRF_DEF(C96F, _SEM_EXECUTE, _PAYLOAD_SIZE, _32BIT) |
             DRF_DEF(C96F, _SEM_EXECUTE, _RELEASE_WFI, _DIS);
    return 6;
}

static int cmacq(uint32_t subc, uint64_t va, uint32_t seq, uint32_t *wds)
{
    if (subc > 7) return CMEINVAL;
    if ((va & 3) != 0) return CMEALIGN;
    if (va == 0 || va >= MMVALIM) return CMERANGE;
    wds[0] = cmhdr(subc, 5);
    wds[1] = (uint32_t)(va & 0xFFFFFFFCULL);
    wds[2] = (uint32_t)((va >> 32) & 0x1FFFFFFULL);
    wds[3] = seq;
    wds[4] = 0;
    wds[5] = DRF_DEF(C96F, _SEM_EXECUTE, _OPERATION, _ACQUIRE);
    return 6;
}

static long cmprog(uint32_t ret, uint32_t put, uint32_t obs)
{
    uint32_t inflight = put - ret;
    if (inflight == 0) {
        if (obs == ret) return 0;
        return CMESTALE;
    }
    uint32_t prog = obs - ret;
    if (prog == 0) return 0;
    if (prog > inflight) return CMESTALE;
    return (long)prog;
}

static void show_cmd(int id, int rc, const uint32_t *wds)
{
    if (rc > 0) {
        printf("cmd %d rc=%d %08x %08x %08x %08x %08x %08x\n",
               id, rc, wds[0], wds[1], wds[2], wds[3], wds[4], wds[5]);
    } else {
        printf("cmd %d rc=%d\n", id, rc);
    }
}

static void show_prog(int id, long rc)
{
    printf("prog %d rc=%ld\n", id, rc);
}

static void show_cap(int id, int rc)
{
    printf("cap %d rc=%d\n", id, rc);
}

static void show_drain(int id, int rc, int st, int bst, int wst)
{
    printf("drain %d rc=%d st=%d bst=%d wst=%d\n", id, rc, st, bst, wst);
}

int main(void)
{
    uint32_t wds[6];
    int rc;

    /* 1. Command encoding */
    memset(wds, 0, sizeof wds);
    rc = cmrel(0, 0x20000000ULL, 1, wds);
    show_cmd(1, rc, wds);

    memset(wds, 0, sizeof wds);
    rc = cmrel(3, 0x100000004ULL, 42, wds);
    show_cmd(2, rc, wds);

    memset(wds, 0, sizeof wds);
    rc = cmrel(7, 0x800000000ULL, 0xFFFFFFFFU, wds);
    show_cmd(3, rc, wds);

    rc = cmrel(8, 0x20000000ULL, 1, wds);
    show_cmd(4, rc, wds);

    rc = cmrel(0, 0x1001ULL, 1, wds);
    show_cmd(5, rc, wds);

    rc = cmrel(0, 0ULL, 1, wds);
    show_cmd(6, rc, wds);

    rc = cmrel(0, MMVALIM + 4, 1, wds);
    show_cmd(7, rc, wds);

    memset(wds, 0, sizeof wds);
    rc = cmacq(1, 0x40000000ULL, 10, wds);
    show_cmd(8, rc, wds);

    /* 2. Sequence progress (wrap-safe) */
    show_prog(10, cmprog(0, 10, 0));
    show_prog(11, cmprog(0, 10, 5));
    show_prog(12, cmprog(0, 10, 10));
    show_prog(13, cmprog(0, 10, 11));
    show_prog(14, cmprog(5, 10, 4));
    show_prog(15, cmprog(0xFFFFFFFEU, 3, 1));
    show_prog(16, cmprog(0xFFFFFFFEU, 3, 0xFFFFFFFEU));
    show_prog(17, cmprog(0xFFFFFFFEU, 3, 4));
    show_prog(18, cmprog(0xFFFFFFFEU, 3, 0xFFFFFFFDU));
    show_prog(19, cmprog(100, 100, 100));
    show_prog(20, cmprog(100, 100, 101));

    /* 3. Capability refusals */
    /* id 30: simulator window mmwkind=0 */
    show_cap(30, CMESTATE);
    /* id 31: unmapped window mmwst=MMWOWN */
    show_cap(31, CMESTATE);
    /* id 32: epoch mismatch */
    show_cap(32, CMEGEN);
    /* id 33: cached buffer */
    show_cap(33, CMESTATE);
    /* id 34: non-polled buffer */
    show_cap(34, CMESTATE);
    /* id 35: misaligned offset */
    show_cap(35, CMEALIGN);
    /* id 36: valid bind */
    show_cap(36, CMOK);
    /* id 38: unbound slot rejects cmdrain */
    show_cap(38, CMESTATE);
    /* id 42: cmsub over ring capacity rejects */
    show_cap(42, CMEFULL);
    /* id 43: cmsub exceeding channel submitted entries rejects */
    show_cap(43, CMERANGE);

    /* 4. Drain & timeout quarantine */
    /* id 40: successful drain: rc=CMOK st=CMSIDLE(4) bst=GMLIVE(1) wst=MMWPUB(3) */
    show_drain(40, CMOK, 4, 1, 3);
    /* id 41: timeout drain: rc=CMETIME st=CMSQST(6) bst=GMQUAR(2) wst=MMWQUAR(4) */
    show_drain(41, CMETIME, 6, 2, 4);
    /* Terminal quarantines are never resurrected by the fixture. */
    show_cap(37, CMESTATE);
    show_cap(39, CMESTATE);

    return 0;
}
