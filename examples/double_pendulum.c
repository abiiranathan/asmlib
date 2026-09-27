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

/* On a hosted build we use the system <math.h>. In the freestanding wasm
 * build there is no <math.h>: asmlib *is* the math library, so we include its
 * header with ASMLIB_MATH_STD_NAMES, which declares sin/cos/sqrt/fabs (and the
 * float variants) under the standard names the code below uses. */
#ifdef ASMLIB_MATH_STD_NAMES
#include "asmlib_math.h"
#else
#include <math.h>
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
 * Exported entry points. The wasm build exports every symbol; the JS driver
 * calls these. `samples` is the number of RK4 steps to run (== number of
 * (x,y) frames produced). The trajectory is written into a caller-provided
 * buffer of 2*samples doubles: x = l1 sin th1 + l2 sin th2,
 * y = -(l1 cos th1 + l2 cos th2) (origin at the pivot, y up).
 *
 * Returns the accumulated energy drift in ulps-ish units (how faithfully the
 * integrator conserved energy), a single scalar that is very sensitive to any
 * error in the math or memory routines.
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

double double_pendulum_run(double th1, double th2, long samples, double *out)
{
    state s;
    s.th1 = th1;
    s.w1  = 0.0;
    s.th2 = th2;
    s.w2  = 0.0;

    double e0 = energy(&s);
    for (long i = 0; i < samples; i++) {
        rk4(&s, DT);
        out[2 * i + 0] = L1 * sin(s.th1) + L2 * sin(s.th2);
        out[2 * i + 1] = -(L1 * cos(s.th1) + L2 * cos(s.th2));
    }
    double e1 = energy(&s);
    return fabs((e1 - e0) / e0);               /* relative energy drift        */
}

/* Single-precision variant using the float math backend. */
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
        out[2 * i + 0] = l1 * sinf(a1) + l2 * sinf(a2);
        out[2 * i + 1] = -(l1 * cosf(a1) + l2 * cosf(a2));
    }
    return sqrtf(w1 * w1 + w2 * w2);           /* final angular speed          */
}
