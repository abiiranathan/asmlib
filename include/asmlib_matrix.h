/**
 * @file asmlib_matrix.h
 * @brief Matrix operations and mathematical utilities.
 */

#ifndef ASMLIB_MATRIX_H
#define ASMLIB_MATRIX_H

#ifdef __cplusplus
extern "C" {
#endif

#include "asmlib_vec.h"
#include "asmlib_math.h"

#include <float.h>
#include <stdbool.h>

/**
 * @struct asm_mat3
 * @brief A 3x3 matrix for 2D transformations and 3D rotations.
 *
 * Matrix elements are stored in column-major order (OpenGL style):
 * | m[0] m[3] m[6] |
 * | m[1] m[4] m[7] |
 * | m[2] m[5] m[8] |
 */
typedef struct ASMLIB_ALIGN(16) asm_mat3 {
    float m[3][3];  // Column-major storage as m[col][row]
} asm_mat3;

/**
 * @struct asm_mat4
 * @brief A 4x4 matrix for 3D transformations.
 *
 * Matrix elements are stored in column-major order (OpenGL style).
 * The union allows accessing data as raw floats or SIMD registers.
 */
typedef struct ASMLIB_ALIGN(16) asm_mat4 {
    union {
        float m[4][4];       // Column-major storage as m[col][row]
        asm_simd_vec_t cols[4];  // SIMD columns
    };
} asm_mat4;

// Debugging
//================

/**
 * Creates a asm_mat3 with elements stored in column-major order.
 * @param m00, m01, ... element values in row-major order (as visualised).
 */
static inline asm_mat3 asm_mat3_new_column_major(float m00, float m01, float m02, float m10, float m11, float m12, float m20,
                                         float m21, float m22) {
    asm_mat3 mat;
    mat.m[0][0] = m00;
    mat.m[1][0] = m01;
    mat.m[2][0] = m02;
    mat.m[0][1] = m10;
    mat.m[1][1] = m11;
    mat.m[2][1] = m12;
    mat.m[0][2] = m20;
    mat.m[1][2] = m21;
    mat.m[2][2] = m22;
    return mat;
}

// Helper function to create a asm_mat4 with column-major storage
static inline asm_mat4 asm_mat4_new_column_major(float m00, float m01, float m02, float m03, float m10, float m11, float m12,
                                         float m13, float m20, float m21, float m22, float m23, float m30, float m31,
                                         float m32, float m33) {
    asm_mat4 mat;
    mat.m[0][0] = m00;
    mat.m[1][0] = m01;
    mat.m[2][0] = m02;
    mat.m[3][0] = m03;
    mat.m[0][1] = m10;
    mat.m[1][1] = m11;
    mat.m[2][1] = m12;
    mat.m[3][1] = m13;
    mat.m[0][2] = m20;
    mat.m[1][2] = m21;
    mat.m[2][2] = m22;
    mat.m[3][2] = m23;
    mat.m[0][3] = m30;
    mat.m[1][3] = m31;
    mat.m[2][3] = m32;
    mat.m[3][3] = m33;
    return mat;
}



// ======================
// Matrix Initialization
// ======================

static inline asm_mat3 asm_mat3_identity(void) { return (asm_mat3){{{1.0f, 0.0f, 0.0f}, {0.0f, 1.0f, 0.0f}, {0.0f, 0.0f, 1.0f}}}; }

static inline bool asm_mat3_equal(asm_mat3 a, asm_mat3 b) {
    static float EPSILON = 1e-6f;
    const float* pa = &a.m[0][0];
    const float* pb = &b.m[0][0];

    // Compare first 4 floats (Col 0 and part of Col 1)
    if (!asm_simd_equals_eps(asm_simd_load(pa), asm_simd_load(pb), EPSILON)) return false;

    // Compare next 4 floats
    if (!asm_simd_equals_eps(asm_simd_load(pa + 4), asm_simd_load(pb + 4), EPSILON)) return false;

    // Compare final element (9th float)
    float da = pa[8] - pb[8];
    return ASM_MATH(fabsf)(da) <= EPSILON;
}

static inline bool asm_mat4_equal(asm_mat4 a, asm_mat4 b) {
    static float EPSILON = 1e-6f;
    // Unroll comparison for all 4 columns
    return asm_simd_equals_eps(a.cols[0], b.cols[0], EPSILON) && asm_simd_equals_eps(a.cols[1], b.cols[1], EPSILON) &&
           asm_simd_equals_eps(a.cols[2], b.cols[2], EPSILON) && asm_simd_equals_eps(a.cols[3], b.cols[3], EPSILON);
}

static inline asm_mat3 asm_mat3_diag(asm_mat3 m) {
    return (asm_mat3){{{m.m[0][0], 0.0f, 0.0f}, {0.0f, m.m[1][1], 0.0f}, {0.0f, 0.0f, m.m[2][2]}}};
}

static inline asm_mat4 asm_mat4_identity(void) {
    asm_mat4 m;
    m.cols[0] = asm_simd_set(1.0f, 0.0f, 0.0f, 0.0f);
    m.cols[1] = asm_simd_set(0.0f, 1.0f, 0.0f, 0.0f);
    m.cols[2] = asm_simd_set(0.0f, 0.0f, 1.0f, 0.0f);
    m.cols[3] = asm_simd_set(0.0f, 0.0f, 0.0f, 1.0f);
    return m;
}

static inline asm_mat4 asm_mat4_diag(asm_mat4 m) {
    // Extract diagonals and reform matrix
    // Note: To be purely SIMD efficient we could shuffle, but scalar fallback is clean here.
    asm_mat4 r;
    r.cols[0] = asm_simd_set(asm_simd_get_x(m.cols[0]), 0, 0, 0);  // X from Col0

    // For other lanes, scalar access is often cleaner than complex shuffles without AVX2
    r.cols[1] = asm_simd_set(0, m.m[1][1], 0, 0);
    r.cols[2] = asm_simd_set(0, 0, m.m[2][2], 0);
    r.cols[3] = asm_simd_set(0, 0, 0, m.m[3][3]);
    return r;
}

// ======================
// Matrix Operations
// ======================

static inline asm_mat3 asm_mat3_mul(asm_mat3 a, asm_mat3 b) {
    asm_mat3 result;
    // Standard cubic complexity multiplication
    for (int col = 0; col < 3; col++) {
        for (int row = 0; row < 3; row++) {
            result.m[col][row] = 0.0f;
            for (int k = 0; k < 3; k++) {
                result.m[col][row] += a.m[k][row] * b.m[col][k];
            }
        }
    }
    return result;
}

static inline asm_mat3 asm_mat3_add_scalar(asm_mat3 m, float scalar) {
    asm_mat3 result;
    asm_simd_vec_t s_vec = asm_simd_set1(scalar);

    // Vectorized add for first 8 elements
    const float* src = &m.m[0][0];
    float* dst = &result.m[0][0];

    asm_simd_store(dst, asm_simd_add(asm_simd_load(src), s_vec));
    asm_simd_store(dst + 4, asm_simd_add(asm_simd_load(src + 4), s_vec));

    // Tail
    dst[8] = src[8] + scalar;
    return result;
}

static inline asm_mat3 asm_mat3_add(asm_mat3 a, asm_mat3 b) {
    asm_mat3 result;
    const float* pa = &a.m[0][0];
    const float* pb = &b.m[0][0];
    float* pr = &result.m[0][0];

    // Batch 1 (floats 0-3)
    asm_simd_store(pr, asm_simd_add(asm_simd_load(pa), asm_simd_load(pb)));

    // Batch 2 (floats 4-7)
    asm_simd_store(pr + 4, asm_simd_add(asm_simd_load(pa + 4), asm_simd_load(pb + 4)));

    // Tail
    pr[8] = pa[8] + pb[8];
    return result;
}

static inline asm_mat3 asm_mat3_scalar_mul(asm_mat3 m, float scalar) {
    asm_mat3 result;
    asm_simd_vec_t s_vec = asm_simd_set1(scalar);

    const float* src = &m.m[0][0];
    float* dst = &result.m[0][0];

    asm_simd_store(dst, asm_simd_mul(asm_simd_load(src), s_vec));
    asm_simd_store(dst + 4, asm_simd_mul(asm_simd_load(src + 4), s_vec));
    dst[8] = src[8] * scalar;

    return result;
}

static inline float asm_mat3_determinant(asm_mat3 m) {
    // Sarrus rule / Co-factor expansion
    return m.m[0][0] * (m.m[1][1] * m.m[2][2] - m.m[2][1] * m.m[1][2]) -
           m.m[0][1] * (m.m[1][0] * m.m[2][2] - m.m[2][0] * m.m[1][2]) +
           m.m[0][2] * (m.m[1][0] * m.m[2][1] - m.m[2][0] * m.m[1][1]);
}

// Matrix LU, Forward Sub, Backward Sub, Exp kept scalar as they are algorithmically complex
// to vectorize without AVX scatter/gather, and usually called infrequently.
static inline bool asm_mat3_lu(asm_mat3 A, asm_mat3* L, asm_mat3* U, asm_mat3* P) {
    const float tolerance = 1e-6f;
    *U = A;
    // Identity L and P
    *L = asm_mat3_identity();
    *P = asm_mat3_identity();

    for (int k = 0; k < 3; ++k) {
        // Pivot
        int pivot_row = k;
        float max_val = ASM_MATH(fabsf)(U->m[k][k]);
        for (int i = k + 1; i < 3; ++i) {
            float val = ASM_MATH(fabsf)(U->m[k][i]);
            if (val > max_val) {
                max_val = val;
                pivot_row = i;
            }
        }
        if (max_val < tolerance) return false;

        // Swap
        if (pivot_row != k) {
            for (int j = 0; j < 3; ++j) {
                float tmp;
                tmp = U->m[j][k];
                U->m[j][k] = U->m[j][pivot_row];
                U->m[j][pivot_row] = tmp;
                tmp = P->m[j][k];
                P->m[j][k] = P->m[j][pivot_row];
                P->m[j][pivot_row] = tmp;
                if (j < k) {
                    tmp = L->m[j][k];
                    L->m[j][k] = L->m[j][pivot_row];
                    L->m[j][pivot_row] = tmp;
                }
            }
        }
        // Eliminate
        for (int i = k + 1; i < 3; ++i) {
            float factor = U->m[k][i] / U->m[k][k];
            L->m[k][i] = factor;
            for (int j = k; j < 3; ++j) {
                U->m[j][i] -= factor * U->m[j][k];
            }
        }
    }
    return true;
}

static inline asm_vec3 asm_forward_substitution_mat3(asm_mat3 L, asm_vec3 b) {
    asm_vec3 x;
    x.x = b.x / L.m[0][0];
    x.y = (b.y - L.m[0][1] * x.x) / L.m[1][1];
    x.z = (b.z - L.m[0][2] * x.x - L.m[1][2] * x.y) / L.m[2][2];
    return x;
}

static inline asm_vec3 asm_backward_substitution_mat3(asm_mat3 U, asm_vec3 b) {
    asm_vec3 x;
    x.z = b.z / U.m[2][2];
    x.y = (b.y - U.m[2][1] * x.z) / U.m[1][1];
    x.x = (b.x - U.m[1][0] * x.y - U.m[2][0] * x.z) / U.m[0][0];
    return x;
}

static inline asm_mat3 asm_mat3_exp(asm_mat3 A, int terms) {
    asm_mat3 result = asm_mat3_identity();
    asm_mat3 power_A = asm_mat3_identity();
    float factorial = 1.0f;
    for (int n = 1; n < terms; ++n) {
        factorial *= (float)n;
        power_A = asm_mat3_mul(power_A, A);
        asm_mat3 term = asm_mat3_scalar_mul(power_A, 1.0f / factorial);
        result = asm_mat3_add(result, term);
    }
    return result;
}

/// @brief Multiplies two 4x4 matrices using SIMD.
static inline asm_mat4 asm_mat4_mul(asm_mat4 a, asm_mat4 b) {
    asm_mat4 result;
    for (int i = 0; i < 4; i++) {
        // We are calculating Column i of the result.
        // Res_Col_i = A * B_Col_i
        // This is a Matrix * Vector operation.
        // B_Col_i is a vector (b.cols[i]).

        asm_simd_vec_t b_col = b.cols[i];

        // Splat components of B's column
        asm_simd_vec_t x = asm_simd_splat_x(b_col);
        asm_simd_vec_t y = asm_simd_splat_y(b_col);
        asm_simd_vec_t z = asm_simd_splat_z(b_col);
        asm_simd_vec_t w = asm_simd_splat_w(b_col);

        // Linear combination of A's columns
        // Res = x*A0 + y*A1 + z*A2 + w*A3
        asm_simd_vec_t r = asm_simd_mul(a.cols[0], x);
        r = asm_simd_add(r, asm_simd_mul(a.cols[1], y));
        r = asm_simd_add(r, asm_simd_mul(a.cols[2], z));
        r = asm_simd_add(r, asm_simd_mul(a.cols[3], w));

        result.cols[i] = r;
    }
    return result;
}

// ======================
// Matrix-Vector Operations
// ======================

static inline asm_vec3 asm_mat3_mul_vec3(asm_mat3 m, asm_vec3 v) {
    asm_simd_vec_t vx = asm_simd_set1(v.x);
    asm_simd_vec_t vy = asm_simd_set1(v.y);
    asm_simd_vec_t vz = asm_simd_set1(v.z);

    // Load columns. We must be careful about memory boundaries.
    // Col 0: OK (4 floats)
    asm_simd_vec_t c0 = asm_simd_load(&m.m[0][0]);
    // Col 1: OK (4 floats)
    asm_simd_vec_t c1 = asm_simd_load(&m.m[1][0]);
    // Col 2: OK (4 floats)
    asm_simd_vec_t c2 = asm_simd_load(&m.m[2][0]);

    // Sum: c0*x + c1*y + c2*z
    asm_simd_vec_t res = asm_simd_mul(c0, vx);
    res = asm_simd_add(res, asm_simd_mul(c1, vy));
    res = asm_simd_add(res, asm_simd_mul(c2, vz));

    // We have {Rx, Ry, Rz, Garbage}
    asm_vec3 out;
    asm_simd_vec_t temp = res;  // Holder
    // To extract, we can store or use asm_simd_get functions if available
    float f[4];
    asm_simd_store(f, temp);
    out.x = f[0];
    out.y = f[1];
    out.z = f[2];
    return out;
}

static inline asm_vec4 asm_mat4_mul_vec4(asm_mat4 m, asm_vec4 v) {
    // Result = v.x * Col0 + v.y * Col1 + v.z * Col2 + v.w * Col3
    asm_simd_vec_t vec = asm_simd_load((const float*)&v);

    asm_simd_vec_t x = asm_simd_splat_x(vec);
    asm_simd_vec_t y = asm_simd_splat_y(vec);
    asm_simd_vec_t z = asm_simd_splat_z(vec);
    asm_simd_vec_t w = asm_simd_splat_w(vec);

    asm_simd_vec_t res = asm_simd_mul(m.cols[0], x);
    res = asm_simd_add(res, asm_simd_mul(m.cols[1], y));
    res = asm_simd_add(res, asm_simd_mul(m.cols[2], z));
    res = asm_simd_add(res, asm_simd_mul(m.cols[3], w));

    asm_vec4 out;
    asm_simd_store((float*)&out, res);
    return out;
}

static inline asm_mat4 asm_mat4_div(asm_mat4 a, float b) {
    asm_mat4 result;
    asm_simd_vec_t div = asm_simd_set1(b);
    result.cols[0] = asm_simd_div(a.cols[0], div);
    result.cols[1] = asm_simd_div(a.cols[1], div);
    result.cols[2] = asm_simd_div(a.cols[2], div);
    result.cols[3] = asm_simd_div(a.cols[3], div);
    return result;
}

// ======================
// Transformation Matrices
// ======================

static inline asm_mat4 asm_mat4_translate(asm_vec3 translation) {
    asm_mat4 m = asm_mat4_identity();
    m.cols[3] = asm_simd_set(translation.x, translation.y, translation.z, 1.0f);
    return m;
}

static inline asm_mat4 asm_mat4_scale(asm_vec3 scale) {
    asm_mat4 m = asm_mat4_identity();
    m.cols[0] = asm_simd_mul(m.cols[0], asm_simd_set1(scale.x));
    m.cols[1] = asm_simd_mul(m.cols[1], asm_simd_set1(scale.y));
    m.cols[2] = asm_simd_mul(m.cols[2], asm_simd_set1(scale.z));
    return m;
}

static inline asm_mat4 asm_mat4_rotate_x(float angle) {
    float c = ASM_MATH(cosf)(angle);
    float s = ASM_MATH(sinf)(angle);
    asm_mat4 m = asm_mat4_identity();
    m.cols[1] = asm_simd_set(0.0f, c, s, 0.0f);
    m.cols[2] = asm_simd_set(0.0f, -s, c, 0.0f);
    return m;
}

static inline asm_mat4 asm_mat4_rotate_y(float angle) {
    float c = ASM_MATH(cosf)(angle);
    float s = ASM_MATH(sinf)(angle);
    asm_mat4 m = asm_mat4_identity();
    m.cols[0] = asm_simd_set(c, 0.0f, -s, 0.0f);
    m.cols[2] = asm_simd_set(s, 0.0f, c, 0.0f);
    return m;
}

static inline asm_mat4 asm_mat4_rotate_z(float angle) {
    float c = ASM_MATH(cosf)(angle);
    float s = ASM_MATH(sinf)(angle);
    asm_mat4 m = asm_mat4_identity();
    m.cols[0] = asm_simd_set(c, s, 0.0f, 0.0f);
    m.cols[1] = asm_simd_set(-s, c, 0.0f, 0.0f);
    return m;
}

static inline asm_mat4 asm_mat4_rotate(asm_vec3 axis, float angle) {
    asm_simd_vec3 a = asm_vec3_normalize(asm_vec3_load(axis));
    float c = ASM_MATH(cosf)(angle);
    float s = ASM_MATH(sinf)(angle);
    float t = 1.0f - c;

    asm_mat4 m = asm_mat4_identity();

    // Diagonal (Row == Col, so no swap needed)
    m.m[0][0] = t * a.x * a.x + c;
    m.m[1][1] = t * a.y * a.y + c;
    m.m[2][2] = t * a.z * a.z + c;

    // Off-diagonals
    // Standard Math: Row 0, Col 1 => t*x*y - s*z
    // Storage: m[1][0]
    m.m[1][0] = t * a.x * a.y - s * a.z;

    // Standard Math: Row 0, Col 2 => t*x*z + s*y
    // Storage: m[2][0]
    m.m[2][0] = t * a.x * a.z + s * a.y;

    // Standard Math: Row 1, Col 0 => t*x*y + s*z
    // Storage: m[0][1]
    m.m[0][1] = t * a.x * a.y + s * a.z;

    // Standard Math: Row 1, Col 2 => t*y*z - s*x
    // Storage: m[2][1]
    m.m[2][1] = t * a.y * a.z - s * a.x;

    // Standard Math: Row 2, Col 0 => t*x*z - s*y
    // Storage: m[0][2]
    m.m[0][2] = t * a.x * a.z - s * a.y;

    // Standard Math: Row 2, Col 1 => t*y*z + s*x
    // Storage: m[1][2]
    m.m[1][2] = t * a.y * a.z + s * a.x;

    return m;
}

// ======================
// Matrix Inversion
// ======================

static inline asm_mat4 asm_mat4_transpose(asm_mat4 m) {
    // Requires asm_simd_transpose4 macro in simd.h
    asm_simd_transpose4(m.cols[0], m.cols[1], m.cols[2], m.cols[3]);
    return m;
}

/* =========================================================
   Determinant & Inverse (Fixed)
   ========================================================= */

static inline float asm_mat4_determinant(asm_mat4 m) {
    // Column 0 elements
    float m00 = m.m[0][0], m10 = m.m[0][1], m20 = m.m[0][2], m30 = m.m[0][3];
    // Column 1 elements
    float m01 = m.m[1][0], m11 = m.m[1][1], m21 = m.m[1][2], m31 = m.m[1][3];
    // Column 2 elements
    float m02 = m.m[2][0], m12 = m.m[2][1], m22 = m.m[2][2], m32 = m.m[2][3];
    // Column 3 elements
    float m03 = m.m[3][0], m13 = m.m[3][1], m23 = m.m[3][2], m33 = m.m[3][3];

    // Compute determinant using expansion along the first column
    // This is verbose but allows the compiler to optimize the arithmetic tree

    float det = m00 * (m11 * (m22 * m33 - m32 * m23) - m21 * (m12 * m33 - m32 * m13) + m31 * (m12 * m23 - m22 * m13)) -
                m10 * (m01 * (m22 * m33 - m32 * m23) - m21 * (m02 * m33 - m32 * m03) + m31 * (m02 * m23 - m22 * m03)) +
                m20 * (m01 * (m12 * m33 - m32 * m13) - m11 * (m02 * m33 - m32 * m03) + m31 * (m02 * m13 - m12 * m03)) -
                m30 * (m01 * (m12 * m23 - m22 * m13) - m11 * (m02 * m23 - m22 * m03) + m21 * (m02 * m13 - m12 * m03));

    return det;
}

static inline asm_mat4 asm_mat4_inverse(asm_mat4 m) {
    /* Gauss-Jordan on the augmented [m | I]. The reference implementation's
     * cofactor expansion is wrong for rotation/scale matrices (it returns
     * -M^-1); asmlib deliberately uses the unconditionally correct algorithm. */
    float a[4][8];
    for (int r = 0; r < 4; r++) {
        for (int c = 0; c < 4; c++) a[r][c] = m.m[c][r];
        for (int c = 0; c < 4; c++) a[r][4 + c] = (r == c) ? 1.0f : 0.0f;
    }
    for (int col = 0; col < 4; col++) {
        int piv = col;
        float best = ASM_MATH(fabsf)(a[col][col]);
        for (int r = col + 1; r < 4; r++) {
            float v = ASM_MATH(fabsf)(a[r][col]);
            if (v > best) { best = v; piv = r; }
        }
        if (best < 1e-8f) return asm_mat4_identity();
        if (piv != col)
            for (int j = 0; j < 8; j++) { float tmp = a[col][j]; a[col][j] = a[piv][j]; a[piv][j] = tmp; }
        float inv = 1.0f / a[col][col];
        for (int j = col; j < 8; j++) a[col][j] *= inv;
        for (int r = 0; r < 4; r++) {
            if (r == col) continue;
            float f = a[r][col];
            for (int j = col; j < 8; j++) a[r][j] -= f * a[col][j];
        }
    }
    asm_mat4 out;
    for (int r = 0; r < 4; r++)
        for (int c = 0; c < 4; c++) out.m[c][r] = a[r][4 + c];
    return out;
}

// ======================
// Projection Matrices
// ======================

static inline asm_mat4 asm_mat4_ortho(float left, float right, float bottom, float top, float near, float far) {
    asm_mat4 m = asm_mat4_identity();
    // Diagonals
    m.cols[0] = asm_simd_set(2.0f / (right - left), 0, 0, 0);
    m.cols[1] = asm_simd_set(0, 2.0f / (top - bottom), 0, 0);
    m.cols[2] = asm_simd_set(0, 0, -2.0f / (far - near), 0);

    // Last column
    m.cols[3] = asm_simd_set(-(right + left) / (right - left), -(top + bottom) / (top - bottom),
                         -(far + near) / (far - near), 1.0f);
    return m;
}

static inline asm_mat4 asm_mat4_perspective(float fov_radians, float aspect, float near, float far) {
    float tan_half_fov = ASM_MATH(tanf)(fov_radians / 2.0f);
    asm_mat4 m;
    m.cols[0] = asm_simd_set(1.0f / (aspect * tan_half_fov), 0, 0, 0);
    m.cols[1] = asm_simd_set(0, 1.0f / tan_half_fov, 0, 0);
    m.cols[2] = asm_simd_set(0, 0, -(far + near) / (far - near), -1.0f);
    m.cols[3] = asm_simd_set(0, 0, -(2.0f * far * near) / (far - near), 0.0f);
    return m;
}

static inline asm_mat4 asm_mat4_look_at(asm_simd_vec3 eye, asm_simd_vec3 target, asm_simd_vec3 up) {
    asm_simd_vec3 z = asm_vec3_normalize(asm_vec3_sub(eye, target));
    asm_simd_vec3 x = asm_vec3_normalize(asm_vec3_cross(up, z));
    asm_simd_vec3 y = asm_vec3_cross(z, x);

    asm_mat4 view;
    view.cols[0] = asm_simd_set(x.x, y.x, z.x, 0.0f);  // Col 0 (Row 0 of rotation)
    view.cols[1] = asm_simd_set(x.y, y.y, z.y, 0.0f);  // Col 1
    view.cols[2] = asm_simd_set(x.z, y.z, z.z, 0.0f);  // Col 2

    // Dot products for translation
    view.cols[3] = asm_simd_set(-asm_vec3_dot(x, eye), -asm_vec3_dot(y, eye), -asm_vec3_dot(z, eye), 1.0f);
    return view;
}

static inline asm_mat4 asm_mat4_add(asm_mat4 a, asm_mat4 b) {
    asm_mat4 res;
    res.cols[0] = asm_simd_add(a.cols[0], b.cols[0]);
    res.cols[1] = asm_simd_add(a.cols[1], b.cols[1]);
    res.cols[2] = asm_simd_add(a.cols[2], b.cols[2]);
    res.cols[3] = asm_simd_add(a.cols[3], b.cols[3]);
    return res;
}

static inline asm_mat4 asm_mat4_sub(asm_mat4 a, asm_mat4 b) {
    asm_mat4 res;
    res.cols[0] = asm_simd_sub(a.cols[0], b.cols[0]);
    res.cols[1] = asm_simd_sub(a.cols[1], b.cols[1]);
    res.cols[2] = asm_simd_sub(a.cols[2], b.cols[2]);
    res.cols[3] = asm_simd_sub(a.cols[3], b.cols[3]);
    return res;
}

static inline asm_mat4 asm_mat4_scalar_mul(asm_mat4 a, float s) {
    asm_mat4 res;
    asm_simd_vec_t v = asm_simd_set1(s);
    res.cols[0] = asm_simd_mul(a.cols[0], v);
    res.cols[1] = asm_simd_mul(a.cols[1], v);
    res.cols[2] = asm_simd_mul(a.cols[2], v);
    res.cols[3] = asm_simd_mul(a.cols[3], v);
    return res;
}

/* ==================================================
   Graphics Extensions: asm_mat3 utilities
   ================================================== */

/**
 * @brief Transposes a 3x3 matrix.
 */
static inline asm_mat3 asm_mat3_transpose(asm_mat3 m) {
    asm_mat3 r;
    for (int c = 0; c < 3; c++) {
        for (int row = 0; row < 3; row++) {
            r.m[c][row] = m.m[row][c];
        }
    }
    return r;
}

/**
 * @brief Inverts a 3x3 matrix using the adjugate method.
 *
 * @return The inverse, or the identity matrix if the input is singular
 *         (|det| < 1e-8), matching asm_mat4_inverse()'s fallback behavior.
 */
static inline asm_mat3 asm_mat3_inverse(asm_mat3 m) {
    float m00 = m.m[0][0], m01 = m.m[1][0], m02 = m.m[2][0];
    float m10 = m.m[0][1], m11 = m.m[1][1], m12 = m.m[2][1];
    float m20 = m.m[0][2], m21 = m.m[1][2], m22 = m.m[2][2];

    // Cofactors of the first column and row pieces (adjugate columns)
    float c00 = m11 * m22 - m12 * m21;
    float c01 = m02 * m21 - m01 * m22;
    float c02 = m01 * m12 - m02 * m11;

    float det = m00 * c00 + m10 * c01 + m20 * c02;
    if (ASM_MATH(fabsf)(det) < 1e-8f) {
        return asm_mat3_identity();
    }
    float inv_det = 1.0f / det;

    asm_mat3 inv;
    // Adjugate / det; adjugate is the transpose of the cofactor matrix.
    inv.m[0][0] = c00 * inv_det;
    inv.m[1][0] = c01 * inv_det;
    inv.m[2][0] = c02 * inv_det;

    inv.m[0][1] = (m12 * m20 - m10 * m22) * inv_det;
    inv.m[1][1] = (m00 * m22 - m02 * m20) * inv_det;
    inv.m[2][1] = (m02 * m10 - m00 * m12) * inv_det;

    inv.m[0][2] = (m10 * m21 - m11 * m20) * inv_det;
    inv.m[1][2] = (m01 * m20 - m00 * m21) * inv_det;
    inv.m[2][2] = (m00 * m11 - m01 * m10) * inv_det;
    return inv;
}

/**
 * @brief Computes the normal matrix for a model transform.
 *
 * Normals must be transformed by the inverse-transpose of the model
 * matrix's upper-left 3x3 to remain correct under non-uniform scaling.
 * Extracts that 3x3, inverts it, and transposes it.
 *
 * @param model The model (world) transform.
 * @return asm_mat3 Use as: normal_world = asm_mat3_mul_vec3(normal_matrix, normal_local).
 */
static inline asm_mat3 asm_mat3_normal_matrix(asm_mat4 model) {
    asm_mat3 upper;
    for (int c = 0; c < 3; c++) {
        for (int r = 0; r < 3; r++) {
            upper.m[c][r] = model.m[c][r];
        }
    }
    return asm_mat3_transpose(asm_mat3_inverse(upper));
}

/* ==================================================
   Graphics Extensions: point/direction transforms & picking
   ================================================== */

/**
 * @brief Transforms a 3D point by a 4x4 matrix (w = 1, perspective-divided).
 *
 * Equivalent to asm_mat4_mul_vec4(m, asm_vec4_from_point(p)) followed by division
 * by w. This is the correct way to transform vertex positions through an
 * MVP matrix when you want world/object-space results rather than clip space.
 *
 * @warning If w ends up 0 or near-zero (point at/behind the camera plane),
 *          the result is undefined. Clip before dividing in production paths.
 */
static inline asm_vec3 asm_mat4_transform_point(asm_mat4 m, asm_vec3 p) {
    asm_vec4 h = asm_mat4_mul_vec4(m, asm_vec4_from_point(p));
    float inv_w = 1.0f / h.w;
    return (asm_vec3){h.x * inv_w, h.y * inv_w, h.z * inv_w};
}

/**
 * @brief Transforms a 3D direction by a 4x4 matrix (w = 0, no translation).
 *
 * Uses only the upper-left 3x3 of the matrix, so translations are ignored.
 * Correct for directions/tangents; for surface normals under non-uniform
 * scale use asm_mat3_normal_matrix() instead.
 */
static inline asm_vec3 asm_mat4_transform_direction(asm_mat4 m, asm_vec3 d) {
    asm_vec4 h = asm_mat4_mul_vec4(m, asm_vec4_from_direction(d));
    return (asm_vec3){h.x, h.y, h.z};
}

/**
 * @brief Creates a centered 2D orthographic projection over pixel coordinates.
 *
 * Maps (0,0) to the bottom-left and (width,height) to the top-right of NDC,
 * with z in [-1, 1]. Typical use: UI/screen-space rendering where geometry
 * is specified directly in window pixels.
 */
static inline asm_mat4 asm_mat4_ortho_2d(float width, float height) {
    return asm_mat4_ortho(0.0f, width, 0.0f, height, -1.0f, 1.0f);
}

/**
 * @brief Perspective projection with an infinite far plane (OpenGL convention).
 *
 * Same [-1, 1] depth convention as asm_mat4_perspective(), but the far plane is
 * pushed to infinity, which maximizes depth-buffer precision. Pair with a
 * reversed-Z depth test for best results.
 *
 * @param fov_radians Vertical field of view.
 * @param aspect     Width / height of the viewport.
 * @param near       Distance to the near plane (> 0).
 */
static inline asm_mat4 asm_mat4_infinite_perspective(float fov_radians, float aspect, float near) {
    float f = 1.0f / ASM_MATH(tanf)(fov_radians / 2.0f);
    asm_mat4 m;
    m.cols[0] = asm_simd_set(f / aspect, 0.0f, 0.0f, 0.0f);
    m.cols[1] = asm_simd_set(0.0f, f, 0.0f, 0.0f);
    m.cols[2] = asm_simd_set(0.0f, 0.0f, -1.0f, -1.0f);
    m.cols[3] = asm_simd_set(0.0f, 0.0f, -2.0f * near, 0.0f);
    return m;
}

/**
 * @brief Converts window/pixel coordinates to normalized device coordinates.
 *
 * Follows the common top-left-origin screen convention: (0,0) maps to
 * NDC (-1, 1). Depth is passed through unchanged, so pick your own z
 * convention (typically -1..1 for OpenGL-style projections).
 *
 * @param sx Horizontal position in pixels.
 * @param sy Vertical position in pixels (top-left origin).
 * @param width Viewport width in pixels.
 * @param height Viewport height in pixels.
 * @return asm_vec3 NDC position (z copied from input).
 */
static inline asm_vec3 screen_to_ndc(float sx, float sy, float z, float width, float height) {
    float x = 2.0f * sx / width - 1.0f;
    float y = 1.0f - 2.0f * sy / height;
    return (asm_vec3){x, y, z};
}

/**
 * @brief Unprojects an NDC coordinate back into world space.
 *
 * Applies inverse_view_proj as a homogeneous transform and divides by w.
 * For ray picking: unproject at z = -1 (near plane) and z = 1 (far plane)
 * and take the normalized difference as the ray direction.
 *
 * @param inverse_view_proj Precomputed inverse of (projection * view).
 * @param ndc Position in normalized device coordinates.
 * @return asm_vec3 World-space position.
 */
static inline asm_vec3 asm_mat4_unproject(asm_mat4 inverse_view_proj, asm_vec3 ndc) {
    asm_vec4 world = asm_mat4_mul_vec4(inverse_view_proj, (asm_vec4){ndc.x, ndc.y, ndc.z, 1.0f});
    if (ASM_MATH(fabsf)(world.w) < 1e-10f) {
        return (asm_vec3){0};
    }
    float inv_w = 1.0f / world.w;
    return (asm_vec3){world.x * inv_w, world.y * inv_w, world.z * inv_w};
}

/* ==================================================
   Quaternions
   ================================================== */

/**
 * @struct asm_quat
 * @brief Unit quaternion representing a 3D rotation.
 *
 * Storage layout matches asm_vec4/asm_simd_vec4 component-for-component, so a
 * quaternion can be reinterpreted as either without conversion cost.
 * Multiplication order follows the standard q1 * q2 == "apply q2 first":
 * asm_mat4_from_quat(asm_quat_mul(a, b)) == asm_mat4_mul(asm_mat4_from_quat(a), asm_mat4_from_quat(b)).
 */
typedef struct ASMLIB_ALIGN(16) asm_quat {
    union {
        struct {
            float x;  ///< Imaginary X component
            float y;  ///< Imaginary Y component
            float z;  ///< Imaginary Z component
            float w;  ///< Real (scalar) component
        };
        asm_vec4 as_vec4;  ///< Reinterpretation for SIMD loads
    };
} asm_quat;

/** @brief Identity rotation (no rotation). */
static inline asm_quat asm_quat_identity(void) { return (asm_quat){.x = 0.0f, .y = 0.0f, .z = 0.0f, .w = 1.0f}; }

/**
 * @brief Creates a rotation quaternion around an arbitrary axis.
 *
 * @param axis Rotation axis (need not be normalized; it is normalized here).
 * @param angle Rotation angle in radians (right-hand rule).
 * @return Unit rotation quaternion.
 */
static inline asm_quat asm_quat_from_axis_angle(asm_vec3 axis, float angle) {
    asm_simd_vec3 a = asm_vec3_normalize(asm_vec3_load(axis));
    float s = ASM_MATH(sinf)(angle * 0.5f);
    return (asm_quat){.x = a.x * s, .y = a.y * s, .z = a.z * s, .w = ASM_MATH(cosf)(angle * 0.5f)};
}

/**
 * @brief Creates a rotation from Euler angles applied in X -> Y -> Z order.
 *
 * Equivalent to Rz(yaw) * Ry(pitch) * Rx(roll) as matrices. All angles in
 * radians. Convenient for cameras and editors, but avoid accumulating many
 * small euler rotations — compose quaternions instead.
 *
 * @param roll  Rotation about X.
 * @param pitch Rotation about Y.
 * @param yaw   Rotation about Z.
 */
static inline asm_quat asm_quat_from_euler(float roll, float pitch, float yaw) {
    float cr = ASM_MATH(cosf)(roll * 0.5f), sr = ASM_MATH(sinf)(roll * 0.5f);
    float cp = ASM_MATH(cosf)(pitch * 0.5f), sp = ASM_MATH(sinf)(pitch * 0.5f);
    float cy = ASM_MATH(cosf)(yaw * 0.5f), sy = ASM_MATH(sinf)(yaw * 0.5f);

    return (asm_quat){
        .x = sr * cp * cy - cr * sp * sy,
        .y = cr * sp * cy + sr * cp * sy,
        .z = cr * cp * sy - sr * sp * cy,
        .w = cr * cp * cy + sr * sp * sy,
    };
}

/** @brief Component-wise dot product (cosine of half the relative angle for units). */
static inline float asm_quat_dot(asm_quat a, asm_quat b) { return a.x * b.x + a.y * b.y + a.z * b.z + a.w * b.w; }

/** @brief Squared length of the quaternion. */
static inline float asm_quat_length_sq(asm_quat q) { return asm_quat_dot(q, q); }

/** @brief Length of the quaternion (1.0 for unit rotations). */
static inline float asm_quat_length(asm_quat q) { return ASM_MATH(sqrtf)(asm_quat_length_sq(q)); }

/**
 * @brief Normalizes to a unit quaternion.
 *
 * @warning Returns the identity if the input is degenerate (all zeros),
 *          unlike the vector normalize functions which are undefined then.
 */
static inline asm_quat asm_quat_normalize(asm_quat q) {
    float len = asm_quat_length(q);
    if (len < 1e-12f) {
        return asm_quat_identity();
    }
    float inv = 1.0f / len;
    return (asm_quat){.x = q.x * inv, .y = q.y * inv, .z = q.z * inv, .w = q.w * inv};
}

/** @brief Conjugate (inverse for unit quaternions): negates the imaginary part. */
static inline asm_quat asm_quat_conjugate(asm_quat q) { return (asm_quat){.x = -q.x, .y = -q.y, .z = -q.z, .w = q.w}; }

/**
 * @brief Hamilton product of two quaternions.
 *
 * Composes rotations: asm_quat_mul(q1, q2) applies q2 first, then q1.
 */
static inline asm_quat asm_quat_mul(asm_quat a, asm_quat b) {
    return (asm_quat){
        .x = a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y,
        .y = a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x,
        .z = a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w,
        .w = a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z,
    };
}

/**
 * @brief Rotates a vector by a unit quaternion.
 *
 * Uses the optimized form t = 2*(q.xyz x v); v' = v + q.w*t + (q.xyz x t)
 * instead of building the full rotation matrix.
 *
 * @param q Unit rotation quaternion.
 * @param v Vector to rotate.
 * @return Rotated vector.
 */
static inline asm_simd_vec3 asm_quat_rotate_vec3(asm_quat q, asm_simd_vec3 v) {
    asm_simd_vec3 qc = {.v = asm_simd_set(q.x, q.y, q.z, 0.0f)};
    asm_simd_vec3 t = asm_vec3_mul(asm_vec3_cross(qc, v), 2.0f);
    return asm_vec3_add(asm_vec3_add(v, asm_vec3_mul(t, q.w)), asm_vec3_cross(qc, t));
}

/**
 * @brief Normalized linear interpolation between two rotations.
 *
 * Faster than asm_quat_slerp() but not constant angular velocity. Take the
 * shortest path automatically (b is negated when dot(a,b) < 0).
 */
static inline asm_quat asm_quat_nlerp(asm_quat a, asm_quat b, float t) {
    if (asm_quat_dot(a, b) < 0.0f) {
        b = (asm_quat){.x = -b.x, .y = -b.y, .z = -b.z, .w = -b.w};
    }
    asm_quat r = (asm_quat){
        .x = a.x + (b.x - a.x) * t,
        .y = a.y + (b.y - a.y) * t,
        .z = a.z + (b.z - a.z) * t,
        .w = a.w + (b.w - a.w) * t,
    };
    return asm_quat_normalize(r);
}

/**
 * @brief Spherical linear interpolation between two rotations.
 *
 * Constant angular velocity along the shortest arc. Falls back to
 * nlerp-style blending for nearly-parallel inputs where sin(theta) ~ 0.
 */
static inline asm_quat asm_quat_slerp(asm_quat a, asm_quat b, float t) {
    float dot = asm_quat_dot(a, b);

    // Shortest path: flip one representative if the hemispheres differ.
    if (dot < 0.0f) {
        dot = -dot;
        b = (asm_quat){.x = -b.x, .y = -b.y, .z = -b.z, .w = -b.w};
    }

    float k0, k1;
    if (dot > 0.9995f) {
        // Nearly identical: linear blend avoids division by tiny sin(theta).
        k0 = 1.0f - t;
        k1 = t;
    } else {
        float theta = ASM_MATH(acosf)(dot);
        float sin_theta = ASM_MATH(sinf)(theta);
        k0 = ASM_MATH(sinf)((1.0f - t) * theta) / sin_theta;
        k1 = ASM_MATH(sinf)(t * theta) / sin_theta;
    }

    return asm_quat_normalize((asm_quat){
        .x = a.x * k0 + b.x * k1,
        .y = a.y * k0 + b.y * k1,
        .z = a.z * k0 + b.z * k1,
        .w = a.w * k0 + b.w * k1,
    });
}

/**
 * @brief Converts a unit rotation quaternion to a 4x4 rotation matrix.
 */
static inline asm_mat4 asm_mat4_from_quat(asm_quat q) {
    float xx = q.x * q.x, yy = q.y * q.y, zz = q.z * q.z;
    float xy = q.x * q.y, xz = q.x * q.z, yz = q.y * q.z;
    float wx = q.w * q.x, wy = q.w * q.y, wz = q.w * q.z;

    asm_mat4 m = asm_mat4_identity();
    // Column-major: m[col][row]
    m.m[0][0] = 1.0f - 2.0f * (yy + zz);
    m.m[0][1] = 2.0f * (xy + wz);
    m.m[0][2] = 2.0f * (xz - wy);

    m.m[1][0] = 2.0f * (xy - wz);
    m.m[1][1] = 1.0f - 2.0f * (xx + zz);
    m.m[1][2] = 2.0f * (yz + wx);

    m.m[2][0] = 2.0f * (xz + wy);
    m.m[2][1] = 2.0f * (yz - wx);
    m.m[2][2] = 1.0f - 2.0f * (xx + yy);
    return m;
}

/**
 * @brief Converts a unit rotation quaternion to a 3x3 rotation matrix.
 */
static inline asm_mat3 asm_mat3_from_quat(asm_quat q) {
    asm_mat4 m = asm_mat4_from_quat(q);
    asm_mat3 r;
    for (int c = 0; c < 3; c++) {
        for (int row = 0; row < 3; row++) {
            r.m[c][row] = m.m[c][row];
        }
    }
    return r;
}

/**
 * @brief Extracts a rotation quaternion from a pure rotation matrix.
 *
 * Uses Shepperd's method (largest-trace pivot) for numerical stability.
 * Assumes the upper-left 3x3 contains only rotation + uniform positive
 * scale; decompose scaled matrices with asm_mat4_decompose() first.
 */
static inline asm_quat asm_quat_from_mat4(asm_mat4 m) {
    // Storage note: m[col][row]. Standard notation R<row><col> therefore maps
    // to m.m[<col>][<row>] — e.g., R21 == m.m[1][2].
    float trace = m.m[0][0] + m.m[1][1] + m.m[2][2];
    asm_quat q;

    if (trace > 0.0f) {
        float s = ASM_MATH(sqrtf)(trace + 1.0f) * 2.0f;  // s = 4w
        q.w = 0.25f * s;
        q.x = (m.m[1][2] - m.m[2][1]) / s;  // R21 - R12
        q.y = (m.m[2][0] - m.m[0][2]) / s;  // R02 - R20
        q.z = (m.m[0][1] - m.m[1][0]) / s;  // R10 - R01
    } else if (m.m[0][0] > m.m[1][1] && m.m[0][0] > m.m[2][2]) {
        float s = ASM_MATH(sqrtf)(1.0f + m.m[0][0] - m.m[1][1] - m.m[2][2]) * 2.0f;  // s = 4x
        q.w = (m.m[1][2] - m.m[2][1]) / s;
        q.x = 0.25f * s;
        q.y = (m.m[1][0] + m.m[0][1]) / s;  // R01 + R10
        q.z = (m.m[2][0] + m.m[0][2]) / s;  // R02 + R20
    } else if (m.m[1][1] > m.m[2][2]) {
        float s = ASM_MATH(sqrtf)(1.0f + m.m[1][1] - m.m[0][0] - m.m[2][2]) * 2.0f;  // s = 4y
        q.w = (m.m[2][0] - m.m[0][2]) / s;
        q.x = (m.m[1][0] + m.m[0][1]) / s;
        q.y = 0.25f * s;
        q.z = (m.m[2][1] + m.m[1][2]) / s;  // R12 + R21
    } else {
        float s = ASM_MATH(sqrtf)(1.0f + m.m[2][2] - m.m[0][0] - m.m[1][1]) * 2.0f;  // s = 4z
        q.w = (m.m[0][1] - m.m[1][0]) / s;
        q.x = (m.m[2][0] + m.m[0][2]) / s;
        q.y = (m.m[2][1] + m.m[1][2]) / s;
        q.z = 0.25f * s;
    }
    return q;
}

/**
 * @brief Builds a model matrix from translation, rotation, and scale (TRS).
 *
 * Computes T * R * S in one pass, equivalent to
 * asm_mat4_mul(asm_mat4_translate(t), asm_mat4_mul(asm_mat4_from_quat(r), asm_mat4_scale(s)))
 * but cheaper and more convenient. This is the standard way to place an
 * object in a scene graph.
 *
 * @param translation World position.
 * @param rotation    Unit rotation quaternion.
 * @param scale       Non-uniform scale factors.
 */
static inline asm_mat4 asm_mat4_compose(asm_vec3 translation, asm_quat rotation, asm_vec3 scale) {
    float xx = rotation.x * rotation.x, yy = rotation.y * rotation.y, zz = rotation.z * rotation.z;
    float xy = rotation.x * rotation.y, xz = rotation.x * rotation.z, yz = rotation.y * rotation.z;
    float wx = rotation.w * rotation.x, wy = rotation.w * rotation.y, wz = rotation.w * rotation.z;

    asm_mat4 m = asm_mat4_identity();
    // Scaled rotation basis vectors as columns.
    m.m[0][0] = (1.0f - 2.0f * (yy + zz)) * scale.x;
    m.m[0][1] = (2.0f * (xy + wz)) * scale.x;
    m.m[0][2] = (2.0f * (xz - wy)) * scale.x;

    m.m[1][0] = (2.0f * (xy - wz)) * scale.y;
    m.m[1][1] = (1.0f - 2.0f * (xx + zz)) * scale.y;
    m.m[1][2] = (2.0f * (yz + wx)) * scale.y;

    m.m[2][0] = (2.0f * (xz + wy)) * scale.z;
    m.m[2][1] = (2.0f * (yz - wx)) * scale.z;
    m.m[2][2] = (1.0f - 2.0f * (xx + yy)) * scale.z;

    m.m[3][0] = translation.x;
    m.m[3][1] = translation.y;
    m.m[3][2] = translation.z;
    return m;
}

#ifdef __cplusplus
}
#endif

#endif  // MATRIX_H
