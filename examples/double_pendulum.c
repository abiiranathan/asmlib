/*==============================================================================
 * double_pendulum.c - a real-world asmlib example: a double pendulum
 *------------------------------------------------------------------------------
 * A double pendulum is a classic chaotic system requiring sin/cos/sqrt (and,
 * in the RK4 integrator below, a lot of arithmetic) every step. This example
 * integrates the equations of motion with classical Runge-Kutta 4 and is built
 * for *WebAssembly* against the asmlib math + libc backends, so it exercises
 * the library as a drop-in <math.h>/libc in a freestanding module:
 *
 *   - math:  sin, cos, sqrt, fabs              (src/math)
 *   - libc:  malloc, free, memset, memcpy, sqrt (src/libc)
 *
 * Build/run:
 *   make wasm-example        # builds build/double_pendulum.wasm
 *   node examples/double_pendulum.js
 *
 * The same source also compiles natively against the x86-64 library or the
 * host libm, so the physics can be compared across backends.
 *
 * Equations of motion (angles th1, th2 from vertical; m1=m2=m, l1=l2=l):
 *
 *   a1 = (-g(2m)sin(th1) - m g sin(th1-2 th2) - 2 sin(d) m (w2^2 l2 + w1^2 l1 cos(d)))
 *        / (l1 (2m - m cos(2 th1 - 2 th2)))
 *   a2 = ( 2 sin(d)(w1^2 l1 (m1+m2) + g(m1+m2)cos(th1) + w2^2 l2 m2 cos(d)))
 *        / (l2 (2m1+m2 - m2 cos(2 th1 - 2 th2)))
 *
 * with d = th1 - th2. The system is computed in double precision throughout.
 *============================================================================*/

#include <stddef.h>

/* On a hosted build we use the system <math.h> and <stdlib.h>. In the
 * freestanding wasm build there is no libc: asmlib *is* the math library and
 * its portable backend is the libc, so we include the asmlib headers with the
 * standard-name macros defined, which declare sin/cos/sqrt/fabs and
 * malloc/free under the standard names the code below uses. */
#ifdef ASMLIB_MATH_STD_NAMES
#include "asmlib_math.h"
#include "portable.h"
#else
#include <math.h>
#include <stdlib.h>
#endif

#define G   9.81
#define L1  1.0
#define L2  1.0
#define M1  1.0
#define M2  1.0
#define DT  0.0005                             /* RK4 step, seconds            */

typedef struct {
    double th1, w1, th2, w2;
} state;

/* d(state)/dt for the double pendulum; returns into `out`. */
static void deriv(const state *s, state *out)
{
    double m1 = M1, m2 = M2, l1 = L1, l2 = L2, g = G;
    double d  = s->th1 - s->th2;
    double cd = cos(d), sd = sin(d);
    double den1 = l1 * (2.0 * m1 + m2 - m2 * cos(2.0 * s->th1 - 2.0 * s->th2));
    double den2 = l2 * (2.0 * m1 + m2 - m2 * cos(2.0 * s->th1 - 2.0 * s->th2));

    out->th1 = s->w1;
    out->th2 = s->w2;
    out->w1 = (-g * (2.0 * m1 + m2) * sin(s->th1)
               - m2 * g * sin(s->th1 - 2.0 * s->th2)
               - 2.0 * sd * m2 * (s->w2 * s->w2 * l2 + s->w1 * s->w1 * l1 * cd))
              / den1;
    out->w2 = (2.0 * sd * (s->w1 * s->w1 * l1 * (m1 + m2)
               + g * (m1 + m2) * cos(s->th1)
               + s->w2 * s->w2 * l2 * m2 * cd)) / den2;
}

static state axpy(double h, const state *a, const state *b)  /* a + h*b */
{
    state r;
    r.th1 = a->th1 + h * b->th1;
    r.w1  = a->w1  + h * b->w1;
    r.th2 = a->th2 + h * b->th2;
    r.w2  = a->w2  + h * b->w2;
    return r;
}

/* One RK4 step: s += (k1 + 2k2 + 2k3 + k4)/6. */
static void rk4(state *s, double h)
{
    state k1, k2, k3, k4, t;
    deriv(s, &k1);
    t = axpy(h / 2.0, s, &k1); deriv(&t, &k2);
    t = axpy(h / 2.0, s, &k2); deriv(&t, &k3);
    t = axpy(h,       s, &k3); deriv(&t, &k4);

    s->th1 += h / 6.0 * (k1.th1 + 2.0 * k2.th1 + 2.0 * k3.th1 + k4.th1);
    s->w1  += h / 6.0 * (k1.w1  + 2.0 * k2.w1  + 2.0 * k3.w1  + k4.w1);
    s->th2 += h / 6.0 * (k1.th2 + 2.0 * k2.th2 + 2.0 * k3.th2 + k4.th2);
    s->w2  += h / 6.0 * (k1.w2  + 2.0 * k2.w2  + 2.0 * k3.w2  + k4.w2);
}

/*------------------------------------------------------------------------------
 * Library API. These are the only symbols the web UI needs; the module is
 * linked with an explicit export list (see the Makefile) rather than
 * --export-all, so this is a clean C ABI:
 *
 *   dp_init(th1, th2)              reset the pendulum to rest at (th1, th2)
 *   dp_step(n)                     advance n RK4 steps (DT seconds each)
 *   dp_state()                     -> pointer to {th1, w1, th2, w2}
 *   dp_tip_x() / dp_tip_y()        current tip position (metres)
 *   dp_energy_drift()              relative energy change since dp_init
 *   dp_buffer(n)                   -> pointer to 2*n doubles for a trajectory
 *   dp_run(th1, th2, n, out)       batch: fill out with n frames, return drift
 *
 * The simulation state is a single file-scope struct, so the UI can step it
 * one frame at a time and draw. All math goes through the asmlib wasm module.
 *------------------------------------------------------------------------------
 * float32 version: the same physics in single precision, to also exercise the
 * float math backend.
 *------------------------------------------------------------------------------*/

/* Total mechanical energy of the state (a conserved quantity). */
static double energy(const state *s)
{
    double v1x =  L1 * s->w1 * cos(s->th1);
    double v1y = -L1 * s->w1 * sin(s->th1);
    double v2x = v1x + L2 * s->w2 * cos(s->th2);
    double v2y = v1y - L2 * s->w2 * sin(s->th2);
    double ke = 0.5 * M1 * (v1x * v1x + v1y * v1y)
              + 0.5 * M2 * (v2x * v2x + v2y * v2y);
    double pe = M1 * G * (L1 - L1 * cos(s->th1))
              + M2 * G * (2.0 * L1 - L1 * cos(s->th1) - L2 * cos(s->th2));
    return ke + pe;
}

/* ---- persistent simulation state ---------------------------------------- */
static state  g_s;
static double g_e0;                            /* energy at the last dp_init   */

double *dp_state(void)        { return (double *)&g_s; }
double  dp_tip_x(void)        { return L1 * sin(g_s.th1) + L2 * sin(g_s.th2); }
double  dp_tip_y(void)        { return -(L1 * cos(g_s.th1) + L2 * cos(g_s.th2)); }
double  dp_energy_drift(void) { return fabs((energy(&g_s) - g_e0) / g_e0); }

void dp_init(double th1, double th2)
{
    g_s.th1 = th1; g_s.w1 = 0.0;
    g_s.th2 = th2; g_s.w2 = 0.0;
    g_e0 = energy(&g_s);
}

/* Advance the persistent state by n RK4 steps. Returns the energy drift. */
double dp_step(long n)
{
    for (long i = 0; i < n; i++)
        rk4(&g_s, DT);
    return dp_energy_drift();
}

/* A reusable trajectory buffer (2*n doubles) that the UI can hand to the
 * module and read back without allocating every frame. `n` may grow it. */
static double *g_buf;
static long    g_bufcap;

double *dp_buffer(long n)
{
    if (n > g_bufcap) {
        free(g_buf);
        g_buf = (double *)malloc((size_t)n * 2u * sizeof(double));
        g_bufcap = g_buf ? n : 0;
    }
    return g_buf;
}

/* Batch run from a fresh state into a caller-supplied buffer (kept for the
 * command-line cross-check and the native comparison). */
double dp_run(double th1, double th2, long samples, double *out)
{
    dp_init(th1, th2);
    for (long i = 0; i < samples; i++) {
        rk4(&g_s, DT);
        out[2 * i + 0] = L1 * sin(g_s.th1) + L2 * sin(g_s.th2);
        out[2 * i + 1] = -(L1 * cos(g_s.th1) + L2 * cos(g_s.th2));
    }
    return dp_energy_drift();
}

/* Keep the older name used by the Node smoke test as an alias. */
double double_pendulum_run(double th1, double th2, long samples, double *out)
{
    return dp_run(th1, th2, samples, out);
}

/* Single-precision batch path (exercises the float math backend). If `out` is
 * non-NULL it receives 2*samples (x,y) frames; it may be NULL if the caller
 * only wants the returned final angular speed. */
float double_pendulum_run_f(float th1, float th2, long samples, float *out)
{
    float g = 9.81f, l1 = 1.0f, l2 = 1.0f, m1 = 1.0f, m2 = 1.0f, h = 0.0005f;
    float a1 = th1, w1 = 0.0f, a2 = th2, w2 = 0.0f;
    for (long i = 0; i < samples; i++) {
        /* A lighter explicit integrator is enough to exercise the float path. */
        float d  = a1 - a2;
        float den = l1 * (2.0f * m1 + m2 - m2 * cosf(2.0f * a1 - 2.0f * a2));
        float acc1 = (-g * (2.0f * m1 + m2) * sinf(a1)
                      - m2 * g * sinf(a1 - 2.0f * a2)
                      - 2.0f * sinf(d) * m2 * (w2 * w2 * l2 + w1 * w1 * l1 * cosf(d)))
                     / den;
        float den2 = l2 * (2.0f * m1 + m2 - m2 * cosf(2.0f * a1 - 2.0f * a2));
        float acc2 = (2.0f * sinf(d) * (w1 * w1 * l1 * (m1 + m2)
                      + g * (m1 + m2) * cosf(a1) + w2 * w2 * l2 * m2 * cosf(d)))
                     / den2;
        w1 += h * acc1; w2 += h * acc2;
        a1 += h * w1;   a2 += h * w2;
        if (out) {
            out[2 * i + 0] = l1 * sinf(a1) + l2 * sinf(a2);
            out[2 * i + 1] = -(l1 * cosf(a1) + l2 * cosf(a2));
        }
    }
    return sqrtf(w1 * w1 + w2 * w2);           /* final angular speed          */
}
