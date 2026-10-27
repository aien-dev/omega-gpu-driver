/* tests/seq_ref.c -- TEST-ONLY C referee for tests/seq_diff.sh. Never linked into the product.
 * Runs aienux PR #441 gpu/gsp_seq.c (gsp_seq_run) against gpu/gsp_sim.c for every case on stdin and prints
 * the trace tests/seq_trace.om prints for gsp/seq.om. Case line (decimal):
 *   name busy budget core corefail nwords end m w0 .. w(m-1)
 * busy = sim busy_reads, budget = poll_budget, core = 1 supplies the core callback (it fails when the
 * opcode equals corefail), words past m are 0. A line starting with # is a comment. */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "gsp_seq.h"
#include "gsp_sim.h"

struct ctx {
    struct ck_gpu_regs r;
    uint32_t fail, ncalls, ops[16], ndelay, us;
};

static uint32_t rd(void *c, uint32_t a) { struct ctx *x = c; return x->r.rd(x->r.ctx, a); }
static void wr(void *c, uint32_t a, uint32_t v) { struct ctx *x = c; x->r.wr(x->r.ctx, a, v); }
static int core(void *c, uint32_t op)
{
    struct ctx *x = c;
    if (x->ncalls < 16) x->ops[x->ncalls] = op;
    x->ncalls++;
    return op == x->fail ? -1 : 0;
}
static void dly(void *c, uint32_t us) { struct ctx *x = c; x->ndelay++; x->us += us; }

int main(void)
{
    static struct ck_gspsim sim;
    char name[64];
    while (scanf("%63s", name) == 1) {
        if (name[0] == '#') {
            int ch;
            while ((ch = getchar()) != EOF && ch != '\n') {}
            continue;
        }
        unsigned long long busy, bud, con, fail, nw, end, m;
        if (scanf("%llu %llu %llu %llu %llu %llu %llu", &busy, &bud, &con, &fail, &nw, &end, &m) != 7) return 2;
        if (nw > (1u << 20) || m > nw || busy > 0xffffffffu || bud > 0xffffffffu || end > 0xffffffffu) return 2;
        uint32_t *buf = calloc(nw ? nw : 1, 4);
        if (!buf) return 2;
        for (unsigned long long i = 0; i < m; i++) {
            unsigned long long w;
            if (scanf("%llu", &w) != 1 || w > 0xffffffffu) return 2;
            buf[i] = (uint32_t)w;
        }
        struct ck_gspsim_cfg cfg;
        memset(&cfg, 0, sizeof cfg);
        cfg.busy_reads = (uint32_t)busy;
        ck_gspsim_init(&sim, &cfg);
        struct ctx x;
        memset(&x, 0, sizeof x);
        x.r = ck_gspsim_regs(&sim);
        x.fail = (uint32_t)fail;
        gsp_seq_io io;
        memset(&io, 0, sizeof io);
        io.rd = rd;
        io.wr = wr;
        io.core = con ? core : NULL;
        io.delay_us = dly;
        io.ctx = &x;
        io.poll_budget = (uint32_t)bud;
        const char *why = 0;
        int rc = gsp_seq_run(buf, (uint32_t)nw, (uint32_t)end, &io, &why);
        printf("== %s rc=%d why=%s delays=%u/%u core=%u ops=", name, rc, why ? why : "-", x.ndelay, x.us, x.ncalls);
        for (uint32_t i = 0; i < x.ncalls && i < 16; i++) printf("%u,", x.ops[i]);
        printf(" save=");
        for (int i = 0; i < GSP_SEQ_REG_SAVE; i++) printf("%#x,", io.save[i]);
        printf(" nlog=%u violations=%u\n", sim.nlog, sim.violations);
        for (uint32_t i = 0; i < sim.nlog && i < CK_GSPSIM_LOG_MAX; i++)
            printf("%c %06x %08x\n", sim.log[i].write ? 'W' : 'R', sim.log[i].off, sim.log[i].val);
        free(buf);
    }
    return 0;
}
