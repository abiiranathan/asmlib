/*==============================================================================
 * image_edit.c - basic image editing (RGBA8) built on asmlib's vec/matrix math
 *------------------------------------------------------------------------------
 * A small wasm *library* module: the browser copies an RGBA pixel buffer into
 * linear memory, calls one of the ie_* entry points, and reads the result back.
 * Every operation is written with asmlib_vec.h / asmlib_matrix.h / asmlib_math.h
 * (asm_vec3/4, asm_mat3, asm_simd_*) and is completely libc-free.
 *
 * Exported C ABI (all buffers are width*height*4 RGBA bytes):
 *   ie_adjust(px, n, brightness, contrast, saturation)   colour grading
 *   ie_grayscale(px, n)                                  Rec.709 luma
 *   ie_invert(px, n)
 *   ie_convolve3(src, dst, w, h, kernel[9], bias)        3x3 kernel (Mat3)
 *   ie_box_blur(src, dst, w, h)
 *   ie_sharpen(src, dst, w, h)
 *   ie_warp(src, w, h, dst, ow, oh, m[9])                affine, bilinear
 *   ie_rotate(src, w, h, dst, angle)                     about the centre
 *
 * Compile for wasm with -DASMLIB_MATH_STD_NAMES so the asm_* math routes to the
 * standard names the wasm math module exports.
 *============================================================================*/

#include "asmlib_vec.h"
#include "asmlib_matrix.h"

#include <stdint.h>

static inline float b2f(uint8_t b) { return (float)b * (1.0f / 255.0f); }
static inline uint8_t f2b(float x) {
    if (x <= 0.0f) return 0;
    if (x >= 1.0f) return 255;
    return (uint8_t)(x * 255.0f + 0.5f);
}
static inline uint8_t c2b(float x) {                 /* 0..255-domain clamp */
    if (x <= 0.0f) return 0;
    if (x >= 255.0f) return 255;
    return (uint8_t)(x + 0.5f);
}

static inline asm_simd_vec3 load_rgb(const uint8_t* p) {
    return asm_vec3_load((asm_vec3){b2f(p[0]), b2f(p[1]), b2f(p[2])});
}
static inline asm_simd_vec4 load_rgba(const uint8_t* p) {
    return (asm_simd_vec4){.v = asm_simd_set(b2f(p[0]), b2f(p[1]), b2f(p[2]), b2f(p[3]))};
}
static inline void store_rgb(uint8_t* p, asm_simd_vec3 c) {
    p[0] = f2b(c.x); p[1] = f2b(c.y); p[2] = f2b(c.z);
}

/*------------------------------------------------------------------------------
 * Colour grading: contrast about mid-grey, brightness, then saturation.
 *----------------------------------------------------------------------------*/
void ie_adjust(uint8_t* px, int n, float brightness, float contrast, float saturation) {
    const asm_simd_vec3 half = asm_vec3_load((asm_vec3){0.5f, 0.5f, 0.5f});
    const asm_simd_vec3 luma = asm_vec3_load((asm_vec3){0.2126f, 0.7152f, 0.0722f});
    for (int i = 0; i < n; i++) {
        uint8_t* p = px + 4 * (size_t)i;
        asm_simd_vec3 c = load_rgb(p);
        c = asm_vec3_add(asm_vec3_mul(asm_vec3_sub(c, half), contrast), half);
        c = asm_vec3_mul(c, brightness);
        float l = asm_vec3_dot(c, luma);
        c = asm_vec3_lerp(asm_vec3_load((asm_vec3){l, l, l}), c, saturation);
        c = asm_vec3_clamp(c, 0.0f, 1.0f);
        store_rgb(p, c);
    }
}

void ie_grayscale(uint8_t* px, int n) {
    const asm_simd_vec3 luma = asm_vec3_load((asm_vec3){0.2126f, 0.7152f, 0.0722f});
    for (int i = 0; i < n; i++) {
        uint8_t* p = px + 4 * (size_t)i;
        float l = asm_vec3_dot(load_rgb(p), luma);
        asm_simd_vec3 g = asm_vec3_load((asm_vec3){l, l, l});
        store_rgb(p, g);
    }
}

void ie_invert(uint8_t* px, int n) {
    for (int i = 0; i < n; i++) {
        uint8_t* p = px + 4 * (size_t)i;
        p[0] = (uint8_t)(255 - p[0]);
        p[1] = (uint8_t)(255 - p[1]);
        p[2] = (uint8_t)(255 - p[2]);
    }
}

/*------------------------------------------------------------------------------
 * 3x3 convolution (edge-clamped). The kernel is held in an asm_mat3 and each
 * output pixel is a weighted sum of asm_vec3 neighbours.
 *----------------------------------------------------------------------------*/
void ie_convolve3(const uint8_t* src, uint8_t* dst, int w, int h,
                  const float* k, float bias) {
    asm_mat3 K = asm_mat3_new_column_major(
        k[0], k[1], k[2],
        k[3], k[4], k[5],
        k[6], k[7], k[8]);
    for (int y = 0; y < h; y++) {
        for (int x = 0; x < w; x++) {
            asm_simd_vec3 sum = asm_vec3_load((asm_vec3){bias, bias, bias});
            for (int dy = -1; dy <= 1; dy++) {
                int yy = y + dy; if (yy < 0) yy = 0; else if (yy >= h) yy = h - 1;
                for (int dx = -1; dx <= 1; dx++) {
                    int xx = x + dx; if (xx < 0) xx = 0; else if (xx >= w) xx = w - 1;
                    const uint8_t* q = src + 4 * ((size_t)yy * w + xx);
                    asm_simd_vec3 px = asm_vec3_load((asm_vec3){q[0], q[1], q[2]});
                    sum = asm_vec3_add(sum, asm_vec3_mul(px, K.m[dx + 1][dy + 1]));
                }
            }
            sum = asm_vec3_clamp(sum, 0.0f, 255.0f);
            uint8_t* o = dst + 4 * ((size_t)y * w + x);
            o[0] = c2b(sum.x); o[1] = c2b(sum.y); o[2] = c2b(sum.z); o[3] = src[4 * ((size_t)y * w + x) + 3];
        }
    }
}

void ie_box_blur(const uint8_t* src, uint8_t* dst, int w, int h) {
    static const float k[9] = {
        1.0f / 9.0f, 1.0f / 9.0f, 1.0f / 9.0f,
        1.0f / 9.0f, 1.0f / 9.0f, 1.0f / 9.0f,
        1.0f / 9.0f, 1.0f / 9.0f, 1.0f / 9.0f,
    };
    ie_convolve3(src, dst, w, h, k, 0.0f);
}

void ie_sharpen(const uint8_t* src, uint8_t* dst, int w, int h) {
    static const float k[9] = {
         0.0f, -1.0f,  0.0f,
        -1.0f,  5.0f, -1.0f,
         0.0f, -1.0f,  0.0f,
    };
    ie_convolve3(src, dst, w, h, k, 0.0f);
}

/*------------------------------------------------------------------------------
 * Affine warp with bilinear sampling. m is the row-major 3x3 inverse map
 * (output -> source); the source of a destination pixel is M * (x, y, 1).
 *----------------------------------------------------------------------------*/
static void warp_affine(const uint8_t* src, int w, int h,
                        uint8_t* dst, int ow, int oh, const float* m) {
    asm_mat3 M = asm_mat3_new_column_major(
        m[0], m[1], m[2],
        m[3], m[4], m[5],
        m[6], m[7], m[8]);
    for (int y = 0; y < oh; y++) {
        for (int x = 0; x < ow; x++) {
            asm_vec3 sv = asm_mat3_mul_vec3(M, (asm_vec3){(float)x + 0.5f, (float)y + 0.5f, 1.0f});
            float sx = sv.x - 0.5f, sy = sv.y - 0.5f;
            uint8_t* o = dst + 4 * ((size_t)y * ow + x);
            if (sx < -1.0f || sy < -1.0f || sx > (float)w || sy > (float)h) {
                o[0] = o[1] = o[2] = 0; o[3] = 255;
                continue;
            }
            int x0 = (int)ASM_MATH(floorf)(sx);
            int y0 = (int)ASM_MATH(floorf)(sy);
            float fx = sx - (float)x0, fy = sy - (float)y0;
            int x1 = x0 + 1, y1 = y0 + 1;
            if (x0 < 0) x0 = 0;
            if (x1 < 0) x1 = 0;
            if (y0 < 0) y0 = 0;
            if (y1 < 0) y1 = 0;
            if (x0 > w - 1) x0 = w - 1;
            if (x1 > w - 1) x1 = w - 1;
            if (y0 > h - 1) y0 = h - 1;
            if (y1 > h - 1) y1 = h - 1;
            const uint8_t* p00 = src + 4 * ((size_t)y0 * w + x0);
            const uint8_t* p10 = src + 4 * ((size_t)y0 * w + x1);
            const uint8_t* p01 = src + 4 * ((size_t)y1 * w + x0);
            const uint8_t* p11 = src + 4 * ((size_t)y1 * w + x1);
            asm_simd_vec4 top = asm_vec4_lerp(load_rgba(p00), load_rgba(p10), fx);
            asm_simd_vec4 bot = asm_vec4_lerp(load_rgba(p01), load_rgba(p11), fx);
            asm_simd_vec4 c = asm_vec4_lerp(top, bot, fy);
            o[0] = f2b(c.x); o[1] = f2b(c.y); o[2] = f2b(c.z); o[3] = f2b(c.w);
        }
    }
}

void ie_warp(const uint8_t* src, int w, int h, uint8_t* dst, int ow, int oh, const float* m) {
    warp_affine(src, w, h, dst, ow, oh, m);
}

void ie_rotate(const uint8_t* src, int w, int h, uint8_t* dst, float angle) {
    float ca = ASM_MATH(cosf)(angle), sa = ASM_MATH(sinf)(angle);
    float cx = (float)w * 0.5f, cy = (float)h * 0.5f;
    /* output -> source: R(-angle) about the centre */
    float m[9] = {
         ca,  sa, cx - ca * cx - sa * cy,
        -sa,  ca, cy + sa * cx - ca * cy,
        0.0f, 0.0f, 1.0f,
    };
    warp_affine(src, w, h, dst, w, h, m);
}
