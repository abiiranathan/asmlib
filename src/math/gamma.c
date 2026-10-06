/*
 * Gamma function, ported from musl libc (tgamma.c and lgamma_r.c).
 *
 * tgamma:
 * "A Precision Approximation of the Gamma Function" - Cornelius Lanczos (1964)
 * "Lanczos Implementation of the Gamma Function" - Paul Godfrey (2001)
 * "An Analysis of the Lanczos Gamma Approximation" - Glendon Ralph Pugh (2004)
 *
 * Approximation method:
 *                         (x - 0.5)         S(x)
 * Gamma(x) = (x + g - 0.5)         *  ----------------
 *                                     exp(x + g - 0.5)
 * with S(x) ~= [ a0 + a1/(x+1) + ... + aN/(x+N) ].
 * For x < 0 the reflection formula Gamma(x)*Gamma(-x) = -pi/(x sin(pi x)) is
 * used.
 *
 * lgamma: origin FreeBSD /usr/src/lib/msun/src/e_lgamma_r.c, reentrant version
 * of log|Gamma(x)|. The musl wrapper exposes the sign of Gamma through a global
 * signgam; that side effect is intentionally dropped here: this port returns
 * log|Gamma(x)| only and keeps the internal helper static.
 */

#include "upstream.h"

/*==============================================================================
 * tgamma
 *============================================================================*/

static const double gamma_pi = 3.141592653589793238462643383279502884;

/* sin(pi x) with x > 0x1p-100, if sin(pi*x)==0 the sign is arbitrary */
static double gamma_sinpi(double x)
{
	int n;

	/* argument reduction: x = |x| mod 2 */
	/* spurious inexact when x is odd int */
	x = x * 0.5;
	x = 2 * (x - ASM_MATH(floor)(x));

	/* reduce x into [-.25,.25] */
	n = 4 * x;
	n = (n+1)/2;
	x -= n * 0.5;

	x *= gamma_pi;
	switch (n) {
	default: /* case 4 */
	case 0:
		return ASM_MATH(sin)(x);
	case 1:
		return ASM_MATH(cos)(x);
	case 2:
		return ASM_MATH(sin)(-x);
	case 3:
		return -ASM_MATH(cos)(x);
	}
}

#define GAMMA_N 12
static const double gmhalf = 5.524680040776729583740234375;
/* n! for small integer n */
static const double fact[] = {
	1, 1, 2, 6, 24, 120, 720, 5040.0, 40320.0, 362880.0, 3628800.0, 39916800.0,
	479001600.0, 6227020800.0, 87178291200.0, 1307674368000.0, 20922789888000.0,
	355687428096000.0, 6402373705728000.0, 121645100408832000.0,
	2432902008176640000.0, 51090942171709440000.0, 1124000727777607680000.0,
};

/*------------------------------------------------------------------------------
 * Minimal double-double ("two-double") arithmetic.
 *------------------------------------------------------------------------------
 * The Lanczos series and its exponential are evaluated in ~106-bit precision so
 * the final result is faithful to well under 1 ulp; plain double loses several
 * ulp here. two_sum/two_prod are exact error-free transforms; add/mul/div round
 * only once at renormalisation.
 *----------------------------------------------------------------------------*/
typedef struct { double hi, lo; } gdd;

static gdd g_two_sum(double a, double b)
{
	gdd r;
	double bb;

	r.hi = a + b;
	bb = r.hi - a;
	r.lo = (a - (r.hi - bb)) + (b - bb);
	return r;
}

static gdd g_quick_two_sum(double a, double b)
{
	gdd r;

	r.hi = a + b;
	r.lo = b - (r.hi - a);
	return r;
}

static gdd g_add(gdd a, gdd b)
{
	gdd s;

	s = g_two_sum(a.hi, b.hi);
	s.lo += a.lo + b.lo;
	return g_quick_two_sum(s.hi, s.lo);
}

static gdd g_mul(gdd a, gdd b)
{
	gdd p;

	p.hi = a.hi * b.hi;
#if defined(__FP_FAST_FMA)
	p.lo = __builtin_fma(a.hi, b.hi, -p.hi);
#else
	/* No hardware FMA (clang does not define __FP_FAST_FMA even with -mfma,
	 * and wasm has no FMA at all): use the library's own correctly rounded
	 * software fma. A Dekker split would overflow for huge inputs here. */
	p.lo = ASM_MATH(fma)(a.hi, b.hi, -p.hi);
#endif
	p.lo += a.hi * b.lo + b.hi * a.lo;
	return g_quick_two_sum(p.hi, p.lo);
}

static gdd g_div(gdd a, gdd b)
{
	double q1, q2;
	gdd p, r;

	q1 = a.hi / b.hi;
	p = g_mul((gdd){q1, 0.0}, b);
	r = g_add(a, (gdd){-p.hi, -p.lo});
	q2 = r.hi / b.hi;
	return g_quick_two_sum(q1, q2);
}

/* m in [0.5,1), y = m * 2^(*k) (bit manipulation; y > 0) */
static double g_frexp(double y, int *k)
{
	union { double f; uint64_t u; } v = {y};
	int e = (int)((v.u >> 52) & 0x7ff);

	if (e == 0) {					/* subnormal: scale up first */
		v.f *= 0x1p54;
		e = (int)((v.u >> 52) & 0x7ff) - 54;
	}
	*k = e - 1022;
	v.u = (v.u & ~(0x7ffULL << 52)) | (1022ULL << 52);
	return v.f;
}

/* log(y) in double-double: reduce to m in [1/sqrt2, sqrt2) and sum the atanh
 * series log(m) = 2*atanh(s), s = (m-1)/(m+1), with double-double coefficients. */
static gdd g_log(double y)
{
	static const gdd ln2 = { 0.6931471805599453, 2.3190468138462996e-17 };
	static const gdd inv_odd[24] = {
		{ 1, 0 },					/* 1/1  */
		{ 0.33333333333333331, 1.8503717077085941e-17 },	/* 1/3  */
		{ 0.20000000000000001, -1.1102230246251566e-17 },	/* 1/5  */
		{ 0.14285714285714285, 7.9301644616082606e-18 },	/* 1/7  */
		{ 0.1111111111111111, 6.1679056923619804e-18 },	/* 1/9  */
		{ 0.090909090909090912, -2.5232341468753558e-18 },	/* 1/11 */
		{ 0.076923076923076927, -4.2700885562506023e-18 },	/* 1/13 */
		{ 0.066666666666666666, 9.251858538542971e-19 },	/* 1/15 */
		{ 0.058823529411764705, 8.1634045928320333e-19 },	/* 1/17 */
		{ 0.052631578947368418, 2.9216395384872539e-18 },	/* 1/19 */
		{ 0.047619047619047616, 2.6433881538694202e-18 },	/* 1/21 */
		{ 0.043478260869565216, 1.2067641572012571e-18 },	/* 1/23 */
		{ 0.040000000000000001, -8.3266726846886737e-19 },	/* 1/25 */
		{ 0.037037037037037035, 2.0559685641206601e-18 },	/* 1/27 */
		{ 0.034482758620689655, 4.7854440716601574e-19 },	/* 1/29 */
		{ 0.032258064516129031, 8.9534114889125525e-19 },	/* 1/31 */
		{ 0.030303030303030304, -8.4107804895845195e-19 },	/* 1/33 */
		{ 0.028571428571428571, 8.9214350193092927e-19 },	/* 1/35 */
		{ 0.027027027027027029, -1.50030138462859e-18 },	/* 1/37 */
		{ 0.02564102564102564, 8.8960178255220869e-19 },	/* 1/39 */
		{ 0.024390243902439025, -8.4620657364722295e-19 },	/* 1/41 */
		{ 0.023255813953488372, 3.2273925134452225e-19 },	/* 1/43 */
		{ 0.022222222222222223, -8.4808703269977233e-19 },	/* 1/45 */
		{ 0.021276595744680851, 5.1672614178032549e-19 },	/* 1/47 */
	};
	gdd s, z, p;
	int k, n;
	double m;

	m = g_frexp(y, &k);
	if (m < 0.70710678118654752440) { m *= 2.0; k--; }
	s = g_div(g_two_sum(m, -1.0), g_two_sum(m, 1.0));
	z = g_mul(s, s);
	p = (gdd){0.0, 0.0};
	for (n = 24; n >= 1; n--)
		p = g_add(g_mul(p, z), inv_odd[n - 1]);
	return g_add(g_mul((gdd){(double)k, 0.0}, ln2),
	             g_mul(g_mul((gdd){2.0, 0.0}, s), p));
}

/* Lanczos coefficients at double-double precision (the double literals in a
 * plain double port carry only ~17 of the ~50 available digits, which is the
 * dominant error there). */
static const gdd Snum[GAMMA_N+1] = {
	{ 23531376880.410759, 7.1640403892445162e-07 },
	{ 42919803642.649101, -2.488366319702998e-06 },
	{ 35711959237.355667, 9.3518237295154714e-07 },
	{ 17921034426.037209, 1.142790849504459e-06 },
	{ 6039542586.3520279, 1.119978853943073e-07 },
	{ 1439720407.3117216, 1.1032398967435741e-07 },
	{ 248874557.86205417, -1.2666548646789895e-08 },
	{ 31426415.585400194, 4.5094199041738073e-10 },
	{ 2876370.6289353725, -1.5682816961562744e-11 },
	{ 186056.26539522348, 1.1829865440498822e-11 },
	{ 8071.6720023658163, -8.6604415029284447e-14 },
	{ 210.82427775157936, -1.3246695303211193e-14 },
	{ 2.5066282746310002, 2.8552552937793735e-17 },
};
static const double Sden[GAMMA_N+1] = {
	0, 39916800, 120543840, 150917976, 105258076, 45995730, 13339535,
	2637558, 357423, 32670, 1925, 66, 1,
};

/* S(x) rational function for positive x, in double-double. */
static gdd g_S(double x)
{
	gdd num = {0.0, 0.0}, den = {0.0, 0.0};
	int i;

	if (x < 8)
		for (i = GAMMA_N; i >= 0; i--) {
			num = g_add(g_mul(num, (gdd){x, 0.0}), Snum[i]);
			den = g_add(g_mul(den, (gdd){x, 0.0}), (gdd){Sden[i], 0.0});
		}
	else
		for (i = 0; i <= GAMMA_N; i++) {
			num = g_add(g_div(num, (gdd){x, 0.0}), Snum[i]);
			den = g_add(g_div(den, (gdd){x, 0.0}), (gdd){Sden[i], 0.0});
		}
	return g_div(num, den);
}

double ASM_MATH(tgamma)(double x)
{
	union { double f; uint64_t i; } u = {x};
	double absx, e;
	uint32_t ix = u.i>>32 & 0x7fffffff;
	int sign = u.i>>63;
	gdd S, E, r, ydd, z0dd, ly;

	/* special cases */
	if (ix >= 0x7ff00000)
		/* tgamma(nan)=nan, tgamma(inf)=inf, tgamma(-inf)=nan with invalid */
		return x + INFINITY;
	if (ix < (0x3ff-54)<<20)
		/* |x| < 2^-54: tgamma(x) ~ 1/x, +-0 raises div-by-zero */
		return 1/x;

	/* integer arguments */
	/* raise inexact when non-integer */
	if (x == ASM_MATH(floor)(x)) {
		if (sign)
			return 0/0.0;
		if (x <= sizeof fact/sizeof *fact)
			return fact[(int)x - 1];
	}

	/* x >= 172: tgamma(x)=inf with overflow */
	/* x =< -184: tgamma(x)=+-0 with underflow */
	if (ix >= 0x40670000) { /* |x| >= 184 */
		if (sign) {
			FORCE_EVAL((float)(0x1p-126/x));
			if (ASM_MATH(floor)(x) * 0.5 == ASM_MATH(floor)(x * 0.5))
				return 0;
			return -0.0;
		}
		x *= 0x1p1023;
		return x;
	}

	absx = sign ? -x : x;

	/* Exact y = absx + g - 0.5 and z0 = absx - 0.5 as double-doubles, so no
	 * rounding correction is needed later. */
	ydd = g_two_sum(absx, gmhalf);
	z0dd = g_two_sum(absx, -0.5);
	/* log(y) for a two-double y: log(yhi) plus the first-order correction. */
	ly = g_log(ydd.hi);
	ly = g_add(ly, g_div((gdd){ydd.lo, 0.0}, (gdd){ydd.hi, 0.0}));
	S = g_S(absx);
	/* E = z0*log(y) - y, the exponent of S * y^z0 * exp(-y) */
	E = g_add(g_mul(z0dd, ly), (gdd){-ydd.hi, -ydd.lo});
	e = ASM_MATH(exp)(E.hi);
	if (!(e <= DBL_MAX / S.hi)) {
		/* S*exp(E) overflowed: for x<0 the reflection drives the result to a
		 * signed zero, otherwise tgamma overflows to +inf. */
		if (x < 0) {
			double rf = -gamma_pi / (gamma_sinpi(absx) * absx);
			return rf < 0 ? -0.0 : 0.0;
		}
		return x + INFINITY;
	}
	r = g_mul(S, (gdd){e, 0.0});
	r = g_add(r, g_mul(r, (gdd){E.lo, 0.0}));	/* exp(Ehi)*(1+Elo) */
	if (x < 0) {
		/* reflection formula for negative x */
		/* sinpi(absx) is not 0, integers are already handled */
		gdd sn = g_mul((gdd){gamma_sinpi(absx), 0.0}, (gdd){absx, 0.0});
		r = g_div(g_div((gdd){-gamma_pi, 0.0}, sn), r);
	}
	return r.hi + r.lo;
}

/*==============================================================================
 * lgamma: log|Gamma(x)| (the signgam side effect is intentionally omitted)
 *============================================================================*/

static const double
lpi =  3.14159265358979311600e+00, /* 0x400921FB, 0x54442D18 */
a0  =  7.72156649015328655494e-02, /* 0x3FB3C467, 0xE37DB0C8 */
a1  =  3.22467033424113591611e-01, /* 0x3FD4A34C, 0xC4A60FAD */
a2  =  6.73523010531292681824e-02, /* 0x3FB13E00, 0x1A5562A7 */
a3  =  2.05808084325167332806e-02, /* 0x3F951322, 0xAC92547B */
a4  =  7.38555086081402883957e-03, /* 0x3F7E404F, 0xB68FEFE8 */
a5  =  2.89051383673415629091e-03, /* 0x3F67ADD8, 0xCCB7926B */
a6  =  1.19270763183362067845e-03, /* 0x3F538A94, 0x116F3F5D */
a7  =  5.10069792153511336608e-04, /* 0x3F40B6C6, 0x89B99C00 */
a8  =  2.20862790713908385557e-04, /* 0x3F2CF2EC, 0xED10E54D */
a9  =  1.08011567247583939954e-04, /* 0x3F1C5088, 0x987DFB07 */
a10 =  2.52144565451257326939e-05, /* 0x3EFA7074, 0x428CFA52 */
a11 =  4.48640949618915160150e-05, /* 0x3F07858E, 0x90A45837 */
tc  =  1.46163214496836224576e+00, /* 0x3FF762D8, 0x6356BE3F */
tf  = -1.21486290535849611461e-01, /* 0xBFBF19B9, 0xBCC38A42 */
/* tt = -(tail of tf) */
tt  = -3.63867699703950536541e-18, /* 0xBC50C7CA, 0xA48A971F */
t0  =  4.83836122723810047042e-01, /* 0x3FDEF72B, 0xC8EE38A2 */
t1  = -1.47587722994593911752e-01, /* 0xBFC2E427, 0x8DC6C509 */
t2  =  6.46249402391333854778e-02, /* 0x3FB08B42, 0x94D5419B */
t3  = -3.27885410759859649565e-02, /* 0xBFA0C9A8, 0xDF35B713 */
t4  =  1.79706750811820387126e-02, /* 0x3F9266E7, 0x970AF9EC */
t5  = -1.03142241298341437450e-02, /* 0xBF851F9F, 0xBA91EC6A */
t6  =  6.10053870246291332635e-03, /* 0x3F78FCE0, 0xE370E344 */
t7  = -3.68452016781138256760e-03, /* 0xBF6E2EFF, 0xB3E914D7 */
t8  =  2.25964780900612472250e-03, /* 0x3F6282D3, 0x2E15C915 */
t9  = -1.40346469989232843813e-03, /* 0xBF56FE8E, 0xBF2D1AF1 */
t10 =  8.81081882437654011382e-04, /* 0x3F4CDF0C, 0xEF61A8E9 */
t11 = -5.38595305356740546715e-04, /* 0xBF41A610, 0x9C73E0EC */
t12 =  3.15632070903625950361e-04, /* 0x3F34AF6D, 0x6C0EBBF7 */
t13 = -3.12754168375120860518e-04, /* 0xBF347F24, 0xECC38C38 */
t14 =  3.35529192635519073543e-04, /* 0x3F35FD3E, 0xE8C2D3F4 */
u0  = -7.72156649015328655494e-02, /* 0xBFB3C467, 0xE37DB0C8 */
u1  =  6.32827064025093366517e-01, /* 0x3FE4401E, 0x8B005DFF */
u2  =  1.45492250137234768737e+00, /* 0x3FF7475C, 0xD119BD6F */
u3  =  9.77717527963372745603e-01, /* 0x3FEF4976, 0x44EA8450 */
u4  =  2.28963728064692451092e-01, /* 0x3FCD4EAE, 0xF6010924 */
u5  =  1.33810918536787660377e-02, /* 0x3F8B678B, 0xBF2BAB09 */
v1  =  2.45597793713041134822e+00, /* 0x4003A5D7, 0xC2BD619C */
v2  =  2.12848976379893395361e+00, /* 0x40010725, 0xA42B18F5 */
v3  =  7.69285150456672783825e-01, /* 0x3FE89DFB, 0xE45050AF */
v4  =  1.04222645593369134254e-01, /* 0x3FBAAE55, 0xD6537C88 */
v5  =  3.21709242282423911810e-03, /* 0x3F6A5ABB, 0x57D0CF61 */
s0  = -7.72156649015328655494e-02, /* 0xBFB3C467, 0xE37DB0C8 */
s1  =  2.14982415960608852501e-01, /* 0x3FCB848B, 0x36E20878 */
s2  =  3.25778796408930981787e-01, /* 0x3FD4D98F, 0x4F139F59 */
s3  =  1.46350472652464452805e-01, /* 0x3FC2BB9C, 0xBEE5F2F7 */
s4  =  2.66422703033638609560e-02, /* 0x3F9B481C, 0x7E939961 */
s5  =  1.84028451407337715652e-03, /* 0x3F5E26B6, 0x7368F239 */
s6  =  3.19475326584100867617e-05, /* 0x3F00BFEC, 0xDD17E945 */
r1  =  1.39200533467621045958e+00, /* 0x3FF645A7, 0x62C4AB74 */
r2  =  7.21935547567138069525e-01, /* 0x3FE71A18, 0x93D3DCDC */
r3  =  1.71933865632803078993e-01, /* 0x3FC601ED, 0xCCFBDF27 */
r4  =  1.86459191715652901344e-02, /* 0x3F9317EA, 0x742ED475 */
r5  =  7.77942496381893596434e-04, /* 0x3F497DDA, 0xCA41A95B */
r6  =  7.32668430744625636189e-06, /* 0x3EDEBAF7, 0xA5B38140 */
w0  =  4.18938533204672725052e-01, /* 0x3FDACFE3, 0x90C97D69 */
w1  =  8.33333333333329678849e-02, /* 0x3FB55555, 0x5555553B */
w2  = -2.77777777728775536470e-03, /* 0xBF66C16C, 0x16B02E5C */
w3  =  7.93650558643019558500e-04, /* 0x3F4A019F, 0x98CF38B6 */
w4  = -5.95187557450339963135e-04, /* 0xBF4380CB, 0x8C0FE741 */
w5  =  8.36339918996282139126e-04, /* 0x3F4B67BA, 0x4CDAD5D1 */
w6  = -1.63092934096575273989e-03; /* 0xBF5AB89D, 0x0B9E43E4 */

/* sin(pi*x) assuming x > 2^-100, if sin(pi*x)==0 the sign is arbitrary */
static double lgamma_sin_pi(double x)
{
	int n;

	/* spurious inexact if odd int */
	x = 2.0*(x*0.5 - ASM_MATH(floor)(x*0.5));  /* x mod 2.0 */

	n = (int)(x*4.0);
	n = (n+1)/2;
	x -= n*0.5f;
	x *= lpi;

	switch (n) {
	default: /* case 4: */
	case 0: return ASM_MATH(sin)(x);
	case 1: return ASM_MATH(cos)(x);
	case 2: return ASM_MATH(sin)(-x);
	case 3: return -ASM_MATH(cos)(x);
	}
}

/* log|Gamma(x)|; musl's __lgamma_r without the signgam out-parameter. */
static double lgamma_impl(double x)
{
	union {double f; uint64_t i;} u = {x};
	double_t t,y,z,nadj=0,p,p1,p2,p3,q,r,w;
	uint32_t ix;
	int sign,i;

	/* purge off +-inf, NaN, +-0, tiny and negative arguments */
	sign = u.i>>63;
	ix = u.i>>32 & 0x7fffffff;
	if (ix >= 0x7ff00000)
		return x*x;
	if (ix < (0x3ff-70)<<20) {  /* |x|<2**-70, return -log(|x|) */
		if(sign)
			x = -x;
		return -log(x);
	}
	if (sign) {
		x = -x;
		t = lgamma_sin_pi(x);
		if (t == 0.0) /* -integer */
			return 1.0/(x-x);
		if (t < 0.0)
			t = -t;
		nadj = log(lpi/(t*x));
	}

	/* purge off 1 and 2 */
	if ((ix == 0x3ff00000 || ix == 0x40000000) && (uint32_t)u.i == 0)
		r = 0;
	/* for x < 2.0 */
	else if (ix < 0x40000000) {
		if (ix <= 0x3feccccc) {   /* lgamma(x) = lgamma(x+1)-log(x) */
			r = -log(x);
			if (ix >= 0x3FE76944) {
				y = 1.0 - x;
				i = 0;
			} else if (ix >= 0x3FCDA661) {
				y = x - (tc-1.0);
				i = 1;
			} else {
				y = x;
				i = 2;
			}
		} else {
			r = 0.0;
			if (ix >= 0x3FFBB4C3) {  /* [1.7316,2] */
				y = 2.0 - x;
				i = 0;
			} else if(ix >= 0x3FF3B4C4) {  /* [1.23,1.73] */
				y = x - tc;
				i = 1;
			} else {
				y = x - 1.0;
				i = 2;
			}
		}
		switch (i) {
		case 0:
			z = y*y;
			p1 = a0+z*(a2+z*(a4+z*(a6+z*(a8+z*a10))));
			p2 = z*(a1+z*(a3+z*(a5+z*(a7+z*(a9+z*a11)))));
			p = y*p1+p2;
			r += (p-0.5*y);
			break;
		case 1:
			z = y*y;
			w = z*y;
			p1 = t0+w*(t3+w*(t6+w*(t9 +w*t12)));    /* parallel comp */
			p2 = t1+w*(t4+w*(t7+w*(t10+w*t13)));
			p3 = t2+w*(t5+w*(t8+w*(t11+w*t14)));
			p = z*p1-(tt-w*(p2+y*p3));
			r += tf + p;
			break;
		case 2:
			p1 = y*(u0+y*(u1+y*(u2+y*(u3+y*(u4+y*u5)))));
			p2 = 1.0+y*(v1+y*(v2+y*(v3+y*(v4+y*v5))));
			r += -0.5*y + p1/p2;
		}
	} else if (ix < 0x40200000) {  /* x < 8.0 */
		i = (int)x;
		y = x - (double)i;
		p = y*(s0+y*(s1+y*(s2+y*(s3+y*(s4+y*(s5+y*s6))))));
		q = 1.0+y*(r1+y*(r2+y*(r3+y*(r4+y*(r5+y*r6)))));
		r = 0.5*y+p/q;
		z = 1.0;    /* lgamma(1+s) = log(s) + lgamma(s) */
		switch (i) {
		case 7: z *= y + 6.0;  /* FALLTHRU */
		case 6: z *= y + 5.0;  /* FALLTHRU */
		case 5: z *= y + 4.0;  /* FALLTHRU */
		case 4: z *= y + 3.0;  /* FALLTHRU */
		case 3: z *= y + 2.0;  /* FALLTHRU */
			r += log(z);
			break;
		}
	} else if (ix < 0x43900000) {  /* 8.0 <= x < 2**58 */
		t = log(x);
		z = 1.0/x;
		y = z*z;
		w = w0+z*(w1+y*(w2+y*(w3+y*(w4+y*(w5+y*w6)))));
		r = (x-0.5)*(t-1.0)+w;
	} else                         /* 2**58 <= x <= inf */
		r =  x*(log(x)-1.0);
	if (sign)
		r = nadj - r;
	return r;
}

double ASM_MATH(lgamma)(double x)
{
	return lgamma_impl(x);
}
