/*==============================================================================
 * fuzz_linalg.c - libFuzzer target for the vector/matrix/quaternion math
 *------------------------------------------------------------------------------
 * Turns bytes into small floats and checks the invariants that must always
 * hold: results stay finite, a normalised vector has unit length, a
 * well-conditioned 4x4 inverse satisfies M * M^-1 = I, and quaternion rotation
 * is finite. NaN/Inf inputs are sanitised away so the checks are meaningful.
 *============================================================================*/

#include "asmlib_matrix.h"

#include <stdint.h>
#include <math.h>
#include <string.h>

int LLVMFuzzerTestOneInput(const uint8_t *d, size_t n) {
    if (n < 24 * 4) return 0;

    float f[24];
    for (int k = 0; k < 24; k++) {
        int32_t s;
        memcpy(&s, d + 4 * k, sizeof s);
        f[k] = (float)(s % 2001 - 1000) * 0.001f;   /* [-1, 1] */
    }

    asm_simd_vec3 A = asm_vec3_load((asm_vec3){f[0], f[1], f[2]});
    asm_simd_vec3 B = asm_vec3_load((asm_vec3){f[3], f[4], f[5]});
    asm_simd_vec3 C = asm_vec3_cross(A, B);
    float dot = asm_vec3_dot(A, B);
    float la = asm_vec3_length(A);
    if (!isfinite(dot) || !isfinite(la) || !isfinite(C.x) || !isfinite(C.y) || !isfinite(C.z))
        __builtin_trap();

    if (la > 1e-3f) {
        asm_simd_vec3 u = asm_vec3_normalize(A);
        float lu = asm_vec3_length(u);
        if (!(fabsf(lu - 1.0f) < 1e-3f)) __builtin_trap();
    }

    asm_mat4 m;
    for (int c = 0; c < 4; c++)
        for (int r = 0; r < 4; r++) m.m[c][r] = f[(c * 4 + r) % 24];
    float det = asm_mat4_determinant(m);
    if (isfinite(det) && fabsf(det) > 0.05f) {
        asm_mat4 mi = asm_mat4_inverse(m);
        asm_mat4 p = asm_mat4_mul(m, mi);
        for (int c = 0; c < 4; c++)
            for (int r = 0; r < 4; r++) {
                float want = (c == r) ? 1.0f : 0.0f;
                if (!(fabsf(p.m[c][r] - want) < 5e-2f)) __builtin_trap();
            }
    }

    float qlen = sqrtf(f[6] * f[6] + f[7] * f[7] + f[8] * f[8] + f[9] * f[9]);
    if (qlen > 1e-3f) {
        asm_quat q = asm_quat_normalize((asm_quat){f[6], f[7], f[8], f[9]});
        if (!isfinite(q.w) || !isfinite(q.x) || !isfinite(q.y) || !isfinite(q.z))
            __builtin_trap();
        asm_simd_vec3 r = asm_quat_rotate_vec3(q, A);
        if (!isfinite(r.x) || !isfinite(r.y) || !isfinite(r.z)) __builtin_trap();
    }
    return 0;
}
