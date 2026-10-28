/* tests/dispatch_ref.c -- TEST-ONLY C referee for tests/dispatch_diff.sh.
 * Never linked into the product.
 * Runs reference prevalidation and gsp_seq_run against gsp_sim for every case in tests/dispatch_cases.txt.
 * Opcodes and payload sizes from rmgspseq.h and kernel_gsp.c:5297-5432.
 * Input format (decimal):
 * name busy budget core corefail perms gen_off tok_off bstate pkt_trunc mode nwords end m w0 .. w(m-1)
 */
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

static int c_core(void *c, uint32_t op)
{
    struct ctx *x = c;
    if (x->ncalls < 16) x->ops[x->ncalls] = op;
    x->ncalls++;
    return op == x->fail ? -1 : 0;
}

static void delay_us(void *c, uint32_t us)
{
    struct ctx *x = c;
    x->ndelay++;
    x->us += us;
}

static uint32_t payload_dwords(uint32_t op)
{
    switch (op) {
    case GSP_SEQ_REG_WRITE: return 2;
    case GSP_SEQ_REG_MODIFY: return 3;
    case GSP_SEQ_REG_POLL: return 5;
    case GSP_SEQ_DELAY_US: return 1;
    case GSP_SEQ_REG_STORE: return 2;
    case GSP_SEQ_CORE_RESET:
    case GSP_SEQ_CORE_START:
    case GSP_SEQ_CORE_WAIT:
    case GSP_SEQ_CORE_RESUME: return 0;
    default: return 0xffffffffu;
    }
}

static const char *why_text(int rc)
{
    switch (rc) {
    case -1: return "empty buffer";
    case -2: return "cmdIndex not inside the buffer";
    case -3: return "unknown opcode";
    case -4: return "opcode overruns cmdIndex";
    case -5: return "poll timed out";
    case -6: return "save index out of range";
    case -7: return "core opcode with no core callback";
    case -8: return "core opcode failed";
    case -9: return "nwords over 16384";
    case -10: return "stale token or invalid state";
    case -11: return "poll budget over 999998";
    case -12: return "remote error quarantined";
    case -13: return "packet shape truncated";
    default: return "-";
    }
}

static int map_why_to_code(const char *why)
{
    if (!why) return 0;
    if (!strcmp(why, "empty buffer")) return -1;
    if (!strcmp(why, "cmdIndex not inside the buffer")) return -2;
    if (!strcmp(why, "unknown opcode")) return -3;
    if (!strcmp(why, "opcode overruns cmdIndex")) return -4;
    if (!strcmp(why, "poll timed out")) return -5;
    if (!strcmp(why, "save index out of range")) return -6;
    if (!strcmp(why, "core opcode with no core callback")) return -7;
    if (!strcmp(why, "core opcode failed")) return -8;
    if (!strcmp(why, "nwords over 16384")) return -9;
    if (!strcmp(why, "delay sleep failed")) return -10;
    if (!strcmp(why, "poll budget over 999998")) return -11;
    return -1;
}

static int prevalidate(const uint32_t *buf, uint32_t nw, uint32_t end, uint32_t perms, int has_core, uint32_t bud, uint32_t mode)
{
    if (nw == 0) return -1;
    if (end >= nw) return -2;
    if (nw > 16384) return -9;
    if (bud > 999998) return -11;
    uint32_t i = 0;
    while (i < end) {
        uint32_t op = buf[i++];
        uint32_t n = payload_dwords(op);
        if (n == 0xffffffffu) return -3;
        if (i + n > end) return -4;
        if (op == GSP_SEQ_REG_STORE) {
            if (buf[i + 1] >= 8) return -6;
        }
        if (op >= GSP_SEQ_CORE_RESET && op <= GSP_SEQ_CORE_RESUME) {
            uint32_t bit = 1u << (op - GSP_SEQ_CORE_RESET);
            /* Host model flags (perms/has_core) authorize host simulation only (mode == 0).
             * Hardware core operations require typed engine capabilities; non-sim mode (mode != 0)
             * unconditionally refuses core operations. */
            if (mode != 0 || !has_core || !(perms & bit)) return -7;
        }
        i += n;
    }
    return 0;
}

int main(void)
{
    char line[65536];
    while (fgets(line, sizeof line, stdin)) {
        char *p = line;
        while (*p == ' ' || *p == '\t') p++;
        if (*p == '#' || *p == '\n' || *p == '\0') continue;
        char name[64];
        long long busy, bud, core, fail, perms, gen_off, tok_off, bstate, pkt_trunc, mode, nw, end, m;
        int off = 0;
        if (sscanf(p, "%63s %lld %lld %lld %lld %lld %lld %lld %lld %lld %lld %lld %lld %lld%n",
                   name, &busy, &bud, &core, &fail, &perms, &gen_off, &tok_off, &bstate, &pkt_trunc, &mode, &nw, &end, &m, &off) != 14) {
            fprintf(stderr, "dispatch_ref: malformed line: %s\n", line);
            return 2;
        }
        p += off;
        uint32_t alloc_nw = (nw > 0) ? (uint32_t)nw : 1;
        uint32_t *buf = calloc(alloc_nw, sizeof(uint32_t));
        for (long long i = 0; i < m && i < nw; i++) {
            long long w = 0;
            if (sscanf(p, "%lld%n", &w, &off) != 1) {
                fprintf(stderr, "dispatch_ref: short words in: %s\n", line);
                free(buf);
                return 2;
            }
            buf[i] = (uint32_t)w;
            p += off;
        }
        while (*p == ' ' || *p == '\t' || *p == '\r' || *p == '\n') p++;
        if (*p != '\0') {
            fprintf(stderr, "dispatch_ref: trailing words (m does not cover the line): %s\n", line);
            free(buf);
            return 2;
        }

        struct ck_gspsim_cfg cfg;
        memset(&cfg, 0, sizeof cfg);
        cfg.busy_reads = (uint32_t)busy;
        struct ck_gspsim sim;
        ck_gspsim_init(&sim, &cfg);

        struct ctx x;
        memset(&x, 0, sizeof x);
        x.r = ck_gspsim_regs(&sim);
        x.fail = (uint32_t)fail;

        uint32_t state = (uint32_t)bstate;
        uint32_t bprev = 9;
        uint32_t dead = 0;
        uint32_t bselen = pkt_trunc ? 100 : (120 + (uint32_t)nw * 4);
        uint32_t save[8] = {0};
        int rc = 0;

        if (state != 11 || gen_off != 0 || tok_off != 0) {
            rc = -10;
        } else if (mode != 0) {
            /* No typed MMIO lease/span: refuse the WHOLE dispatch before unpack/effects.
             * This is the explicit unavailable-effect gate, not vendor register validation. */
            dead = 1; state = 12; rc = -7;
        } else if (bselen < 120 + (uint32_t)nw * 4) {
            dead = 1; state = 12; rc = -13;
        } else if (nw == 0) {
            dead = 1; state = 12; rc = -1;
        } else if (nw > 16384) {
            dead = 1; state = 12; rc = -9;
        } else if ((uint32_t)end >= (uint32_t)nw) {
            dead = 1; state = 12; rc = -2;
        } else {
            int pr = prevalidate(buf, (uint32_t)nw, (uint32_t)end, (uint32_t)perms, (int)core, (uint32_t)bud, (uint32_t)mode);
            if (pr != 0) {
                dead = 1; state = 12; rc = pr;
            } else {
                struct gsp_seq_io io;
                memset(&io, 0, sizeof io);
                io.rd = rd;
                io.wr = wr;
                io.core = core ? c_core : NULL;
                io.delay_us = delay_us;
                io.ctx = &x;
                io.poll_budget = (uint32_t)bud;
                const char *why = NULL;
                int s_rc = gsp_seq_run(buf, (uint32_t)nw, (uint32_t)end, &io, &why);
                if (s_rc != 0) {
                    dead = 1; state = 12;
                    rc = map_why_to_code(why);
                } else {
                    state = bprev;
                    dead = 0;
                    rc = 0;
                    for (int k = 0; k < 8; k++) save[k] = io.save[k];
                }
            }
        }

        printf("== %s rc=%d state=%u dead=%u why=%s delays=%u/%u core=%u ops=",
               name, rc, state, dead, why_text(rc), x.ndelay, x.us, x.ncalls);
        for (uint32_t i = 0; i < x.ncalls && i < 16; i++) printf("%u,", x.ops[i]);
        printf(" save=");
        for (int i = 0; i < 8; i++) printf("%#x,", save[i]);
        printf(" nlog=%u violations=%u\n", sim.nlog, sim.violations);
        for (uint32_t i = 0; i < sim.nlog && i < CK_GSPSIM_LOG_MAX; i++)
            printf("%c %06x %08x\n", sim.log[i].write ? 'W' : 'R', sim.log[i].off, sim.log[i].val);

        free(buf);
    }
    return 0;
}
