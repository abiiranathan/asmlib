/*==============================================================================
 * math_bench.c - asm math library vs. the host libm
 *------------------------------------------------------------------------------
 * Times every asm_* math routine against its libm counterpart on representative
 * input distributions and reports nanoseconds per call and the speedup
 * (> 1.00x means asmlib is faster).
 *
 * Both sides are called through a volatile function pointer so the compiler
 * cannot inline our routines or substitute builtins (the file is compiled with
 * -fno-builtin), and inputs are pre-generated so the loops cannot be folded.
 * Each measurement is the best of several trials to limit scheduler noise.
 *============================================================================*/

#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include <stdio.h>
#include <stdint.h>
#include <time.h>
#include <math.h>

#include "asmlib_math.h"

#define N        2048                   /* inputs per measurement */
#define REP      32                     /* sweeps over the input array */
#define TRIALS   7                      /* trials; the fastest is reported */

typedef double (*u1fn)(double);
typedef double (*u2fn)(double, double);
typedef void   (*scfn)(double, double *, double *);

static volatile double dsink;           /* defeats dead-code elimination */
static uint64_t rng_state = 0x123456789abcdef0ULL;

static uint64_t rnd64(void)
{
    uint64_t x = rng_state;
    x ^= x >> 12;
    x ^= x << 25;
    x ^= x >> 27;
    rng_state = x;
    return x * 0x2545F4914F6CDD1DULL;
}

static double urand(void)               /* uniform [0,1) */
{
    return (double)(rnd64() >> 11) * 0x1.0p-53;
}

static double urand_sym(void)           /* uniform [-1,1) */
{
    return 2.0 * urand() - 1.0;
}

static double now_ns(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1e9 + ts.tv_nsec;
}

/* ---- representative input pools ----------------------------------------- */
static double Xreal[N];                 /* [-100, 100]                     */
static double Xbig[N];                  /* [-1e15, 1e15] (reduction stress)*/
static double Xpos[N];                  /* positive, 2^[-1001, 1000]       */
static double Xbase[N];                 /* [0.1, 10] (pow base)            */
static double Xunit[N];                 /* [-1, 1]                         */
static double Xone[N];                  /* [1, 1e6] (acosh)                */
static double Xtiny[N];                 /* 2^[-60,-1] with random sign     */
static double Xbinx[N], Xbiny[N];       /* binary operands, y != 0         */

static void fill_inputs(void)
{
    for (int i = 0; i < N; i++) {
        Xreal[i] = 100.0 * urand_sym();
        Xbig[i]  = 1e15 * urand_sym();
        Xpos[i]  = ldexp(0.5 + 0.5 * urand(), (int)(rnd64() % 2001) - 1000);
        Xbase[i] = 0.1 + 9.9 * urand();
        Xunit[i] = urand_sym();
        Xone[i]  = 1.0 + 1e6 * urand();
        Xtiny[i] = ldexp(urand_sym(), -(int)(1 + rnd64() % 60));
        Xbinx[i] = 100.0 * urand_sym();
        double y = 100.0 * urand_sym();
        Xbiny[i] = (y == 0.0) ? 1.0 : y;
    }
}

/* Four independent accumulators break the FP add dependency chain so the
 * measurement reflects the routine, not the summing overhead. */
static double best_u1(u1fn f, const double *in)
{
    u1fn volatile vf = f;
    double best = 1e300;
    for (int t = 0; t < TRIALS; t++) {
        double a0 = 0, a1 = 0, a2 = 0, a3 = 0;
        double t0 = now_ns();
        for (int r = 0; r < REP; r++)
            for (int i = 0; i < N; i += 4) {
                a0 += vf(in[i]);
                a1 += vf(in[i + 1]);
                a2 += vf(in[i + 2]);
                a3 += vf(in[i + 3]);
            }
        double t1 = now_ns();
        dsink += a0 + a1 + a2 + a3;
        if (t1 - t0 < best)
            best = t1 - t0;
    }
    return best / ((double)REP * N);
}

static double best_u2(u2fn f, const double *x, const double *y)
{
    u2fn volatile vf = f;
    double best = 1e300;
    for (int t = 0; t < TRIALS; t++) {
        double a0 = 0, a1 = 0, a2 = 0, a3 = 0;
        double t0 = now_ns();
        for (int r = 0; r < REP; r++)
            for (int i = 0; i < N; i += 4) {
                a0 += vf(x[i], y[i]);
                a1 += vf(x[i + 1], y[i + 1]);
                a2 += vf(x[i + 2], y[i + 2]);
                a3 += vf(x[i + 3], y[i + 3]);
            }
        double t1 = now_ns();
        dsink += a0 + a1 + a2 + a3;
        if (t1 - t0 < best)
            best = t1 - t0;
    }
    return best / ((double)REP * N);
}

static double best_sincos(scfn f, const double *in)
{
    scfn volatile vf = f;
    double best = 1e300;
    for (int t = 0; t < TRIALS; t++) {
        double as = 0, ac = 0;
        double t0 = now_ns();
        for (int r = 0; r < REP; r++)
            for (int i = 0; i < N; i++) {
                double s, c;
                vf(in[i], &s, &c);
                as += s;
                ac += c;
            }
        double t1 = now_ns();
        dsink += as + ac;
        if (t1 - t0 < best)
            best = t1 - t0;
    }
    return best / ((double)REP * N);
}

static void r1(const char *name, u1fn libm_fn, u1fn asm_fn, const double *in)
{
    double l = best_u1(libm_fn, in);
    double a = best_u1(asm_fn, in);
    printf("  %-10s %10.2f %10.2f %8.2fx\n", name, l, a, l / a);
}

static void r2(const char *name, u2fn libm_fn, u2fn asm_fn,
               const double *x, const double *y)
{
    double l = best_u2(libm_fn, x, y);
    double a = best_u2(asm_fn, x, y);
    printf("  %-10s %10.2f %10.2f %8.2fx\n", name, l, a, l / a);
}

int main(void)
{
    fill_inputs();

    printf("asmlib math vs libm (ns/call, best of %d; >1.00x means asmlib faster)\n",
           TRIALS);
    printf("  %-10s %10s %10s %9s\n", "function", "libm", "asmlib", "speedup");
    printf("  %-10s %10s %10s %9s\n", "", "ns/call", "ns/call", "");

    printf("\n== basic ==\n");
    r1("fabs",  fabs,  ASM_MATH(fabs),  Xreal);
    r1("floor", floor, ASM_MATH(floor), Xreal);
    r1("ceil",  ceil,  ASM_MATH(ceil),  Xreal);
    r1("trunc", trunc, ASM_MATH(trunc), Xreal);
    r1("round", round, ASM_MATH(round), Xreal);
    r1("rint",  rint,  ASM_MATH(rint),  Xreal);
    r1("sqrt",  sqrt,  ASM_MATH(sqrt),  Xpos);
    r1("cbrt",  cbrt,  ASM_MATH(cbrt),  Xreal);
    r2("hypot", hypot, ASM_MATH(hypot), Xreal, Xreal);

    printf("\n== exp / log ==\n");
    r1("exp",   exp,   ASM_MATH(exp),   Xreal);
    r1("exp2",  exp2,  ASM_MATH(exp2),  Xreal);
    r1("expm1", expm1, ASM_MATH(expm1), Xtiny);
    r1("log",   log,   ASM_MATH(log),   Xpos);
    r1("log2",  log2,  ASM_MATH(log2),  Xpos);
    r1("log10", log10, ASM_MATH(log10), Xpos);
    r1("log1p", log1p, ASM_MATH(log1p), Xtiny);
    r2("pow",   pow,   ASM_MATH(pow),   Xbase, Xreal);

    printf("\n== trigonometric ==\n");
    r1("sin",   sin,   ASM_MATH(sin),   Xreal);
    r1("cos",   cos,   ASM_MATH(cos),   Xreal);
    r1("tan",   tan,   ASM_MATH(tan),   Xreal);
    r1("sin big", sin, ASM_MATH(sin),   Xbig);   /* Payne-Hanek reduction */
    r1("asin",  asin,  ASM_MATH(asin),  Xunit);
    r1("acos",  acos,  ASM_MATH(acos),  Xunit);
    r1("atan",  atan,  ASM_MATH(atan),  Xreal);
    r2("atan2", atan2, ASM_MATH(atan2), Xreal, Xreal);
    {
        double l = best_sincos(sincos, Xreal);
        double a = best_sincos(ASM_MATH(sincos), Xreal);
        printf("  %-10s %10.2f %10.2f %8.2fx\n", "sincos", l, a, l / a);
    }

    printf("\n== hyperbolic ==\n");
    r1("sinh",  sinh,  ASM_MATH(sinh),  Xreal);
    r1("cosh",  cosh,  ASM_MATH(cosh),  Xreal);
    r1("tanh",  tanh,  ASM_MATH(tanh),  Xreal);
    r1("asinh", asinh, ASM_MATH(asinh), Xreal);
    r1("acosh", acosh, ASM_MATH(acosh), Xone);
    r1("atanh", atanh, ASM_MATH(atanh), Xunit);

    printf("\n== arithmetic ==\n");
    r2("fmod",      fmod,      ASM_MATH(fmod),      Xreal, Xbiny);
    r2("remainder", remainder, ASM_MATH(remainder), Xreal, Xbiny);

    (void)dsink;
    return 0;
}
