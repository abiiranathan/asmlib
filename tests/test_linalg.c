/*==============================================================================
 * test_linalg.c - functional tests for the asmlib vector/matrix/quaternion API
 *------------------------------------------------------------------------------
 * The ported solidc math is header-only and self-contained, so this checks it
 * against hand-computed values, algebraic identities (M * M^-1 = I, unit
 * normalisation, quaternion/matrix agreement) and a small independent scalar
 * reference, rather than against another library.
 *============================================================================*/

#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include <stdio.h>
#include <math.h>
#include <stddef.h>

#include "asmlib_matrix.h"

static unsigned long checks = 0;
static unsigned long failures = 0;
#define CHECK(cond, msg)                                                     \
    do {                                                                     \
        checks++;                                                            \
        if (!(cond)) {                                                       \
            printf("FAIL: %-26s line %-4d (%s)\n", (msg), __LINE__, #cond);  \
            failures++;                                                      \
        }                                                                    \
    } while (0)

static int approx(float a, float b, float eps) { return fabsf(a - b) <= eps; }
static int near3(asm_simd_vec3 v, float x, float y, float z, float eps) {
    return approx(v.x, x, eps) && approx(v.y, y, eps) && approx(v.z, z, eps);
}
static int near4(asm_simd_vec4 v, float x, float y, float z, float w, float eps) {
    return approx(v.x, x, eps) && approx(v.y, y, eps) && approx(v.z, z, eps) && approx(v.w, w, eps);
}

/*------------------------------------------------------------------------------
 * Vectors
 *----------------------------------------------------------------------------*/
static void test_vec2(void) {
    asm_simd_vec2 a = asm_vec2_load((asm_vec2){3.0f, 4.0f});
    asm_simd_vec2 b = asm_vec2_load((asm_vec2){1.0f, 2.0f});
    asm_simd_vec2 s = asm_vec2_add(a, b);
    CHECK(approx(s.x, 4.0f, 1e-6f) && approx(s.y, 6.0f, 1e-6f), "vec2 add");
    asm_simd_vec2 d = asm_vec2_sub(a, b);
    CHECK(approx(d.x, 2.0f, 1e-6f) && approx(d.y, 2.0f, 1e-6f), "vec2 sub");
    asm_simd_vec2 m = asm_vec2_mul(a, 2.0f);
    CHECK(approx(m.x, 6.0f, 1e-6f) && approx(m.y, 8.0f, 1e-6f), "vec2 mul");
    asm_simd_vec2 dv = asm_vec2_div(a, 2.0f);
    CHECK(approx(dv.x, 1.5f, 1e-6f) && approx(dv.y, 2.0f, 1e-6f), "vec2 div");
    CHECK(approx(asm_vec2_div(a, 0.0f).x, 0.0f, 1e-6f), "vec2 div zero-guard");
    CHECK(approx(asm_vec2_dot(a, b), 11.0f, 1e-6f), "vec2 dot");
    CHECK(approx(asm_vec2_length_sq(a), 25.0f, 1e-6f), "vec2 length_sq");
    CHECK(approx(asm_vec2_length(a), 5.0f, 1e-6f), "vec2 length");
    asm_simd_vec2 n = asm_vec2_normalize(a);
    CHECK(approx(asm_vec2_length(n), 1.0f, 1e-5f), "vec2 normalize");
    CHECK(approx(asm_vec2_distance(a, b), sqrtf(8.0f), 1e-5f), "vec2 distance");
    asm_simd_vec2 l = asm_vec2_lerp(a, b, 0.5f);
    CHECK(approx(l.x, 2.0f, 1e-6f) && approx(l.y, 3.0f, 1e-6f), "vec2 lerp");
    asm_simd_vec2 perp = asm_vec2_perpendicular(a);
    CHECK(approx(perp.x, -4.0f, 1e-6f) && approx(perp.y, 3.0f, 1e-6f), "vec2 perp");
    CHECK(approx(asm_vec2_angle_between(a, a), 0.0f, 1e-5f), "vec2 angle self");
    asm_simd_vec2 r90 = asm_vec2_rotate(a, (float)(M_PI / 2.0));
    CHECK(approx(r90.x, -4.0f, 1e-4f) && approx(r90.y, 3.0f, 1e-4f), "vec2 rotate 90");
    CHECK(approx(asm_vec2_sum(a), 7.0f, 1e-6f), "vec2 sum");
}

static void test_vec3(void) {
    asm_simd_vec3 a = asm_vec3_load((asm_vec3){1.0f, 0.0f, 0.0f});
    asm_simd_vec3 b = asm_vec3_load((asm_vec3){0.0f, 1.0f, 0.0f});
    asm_simd_vec3 c = asm_vec3_cross(a, b);
    CHECK(near3(c, 0.0f, 0.0f, 1.0f, 1e-6f), "vec3 cross");
    CHECK(approx(asm_vec3_dot(a, b), 0.0f, 1e-6f), "vec3 dot");
    CHECK(approx(asm_vec3_dot(a, a), 1.0f, 1e-6f), "vec3 dot self");
    asm_simd_vec3 v = asm_vec3_load((asm_vec3){3.0f, 4.0f, 12.0f});
    CHECK(approx(asm_vec3_length(v), 13.0f, 1e-5f), "vec3 length");
    asm_simd_vec3 un = asm_vec3_normalize(v);
    CHECK(approx(asm_vec3_length(un), 1.0f, 1e-5f), "vec3 normalize");
    asm_simd_vec3 un_fast = asm_vec3_normalize_fast(v);
    CHECK(approx(asm_vec3_length(un_fast), 1.0f, 1e-3f), "vec3 normalize_fast");
    asm_simd_vec3 s = asm_vec3_load((asm_vec3){2.0f, 3.0f, 6.0f});
    asm_simd_vec3 pr = asm_vec3_project(s, v);
    asm_simd_vec3 pr_cross = asm_vec3_cross(pr, v);
    CHECK(near3(pr_cross, 0.0f, 0.0f, 0.0f, 1e-4f), "vec3 project parallel");
    asm_simd_vec3 rej = asm_vec3_reject(s, v);
    CHECK(approx(asm_vec3_dot(rej, v), 0.0f, 1e-4f), "vec3 reject orthogonal");
    /* perpendicular must be unit and orthogonal */
    asm_simd_vec3 pp = asm_vec3_perpendicular(v);
    CHECK(approx(asm_vec3_dot(pp, un), 0.0f, 1e-4f), "vec3 perpendicular ortho");
    CHECK(approx(asm_vec3_length(pp), 1.0f, 1e-4f), "vec3 perpendicular unit");
    /* reflection about a normal flips the normal component */
    asm_simd_vec3 i = asm_vec3_load((asm_vec3){1.0f, -1.0f, 0.0f});
    asm_simd_vec3 nrm = asm_vec3_load((asm_vec3){0.0f, 1.0f, 0.0f});
    asm_simd_vec3 refl = asm_vec3_reflect(i, nrm);
    CHECK(near3(refl, 1.0f, 1.0f, 0.0f, 1e-6f), "vec3 reflect");
    /* refract straight-on is unchanged direction */
    asm_simd_vec3 refr = asm_vec3_refract(asm_vec3_load((asm_vec3){0.0f, -1.0f, 0.0f}), nrm, 1.0f);
    CHECK(near3(refr, 0.0f, -1.0f, 0.0f, 1e-4f), "vec3 refract identity");
    CHECK(approx(asm_vec3_triple_product(a, b, c), 1.0f, 1e-6f), "vec3 triple product");
    asm_simd_vec3 tri = asm_vec3_load((asm_vec3){1.0f, 0.0f, 0.0f});
    asm_vec3 bar = asm_vec3_barycentric(a, b, c, tri);
    CHECK(approx(bar.x + bar.y + bar.z, 1.0f, 1e-5f), "vec3 barycentric sum");
    CHECK(approx(bar.x, 1.0f, 1e-5f) && approx(bar.y, 0.0f, 1e-5f) && approx(bar.z, 0.0f, 1e-5f), "vec3 barycentric corner");
    CHECK(approx(asm_vec3_angle_between(a, b), (float)(M_PI / 2.0), 1e-5f), "vec3 angle");
    CHECK(near3(asm_vec3_faceforward(a, asm_vec3_load((asm_vec3){-1, 0, 0})), 1.0f, 0.0f, 0.0f, 1e-6f), "vec3 faceforward");
    /* activation */
    asm_simd_vec3 act = asm_vec3_load((asm_vec3){-1.0f, 0.0f, 2.0f});
    CHECK(near3(asm_vec3_relu(act), 0.0f, 0.0f, 2.0f, 1e-6f), "vec3 relu");
    CHECK(approx(asm_vec3_sigmoid(act).x, 1.0f / (1.0f + expf(1.0f)), 1e-5f), "vec3 sigmoid");
    CHECK(approx(asm_vec3_tanh(act).z, tanhf(2.0f), 1e-5f), "vec3 tanh");
}

static void test_vec4(void) {
    asm_simd_vec4 a = asm_vec4_load((asm_vec4){1.0f, 2.0f, 3.0f, 4.0f});
    asm_simd_vec4 b = asm_vec4_load((asm_vec4){4.0f, 3.0f, 2.0f, 1.0f});
    CHECK(approx(asm_vec4_dot(a, b), 20.0f, 1e-6f), "vec4 dot");
    CHECK(approx(asm_vec4_length(a), sqrtf(30.0f), 1e-5f), "vec4 length");
    CHECK(approx(asm_vec4_sum(a), 10.0f, 1e-6f), "vec4 sum");
    asm_simd_vec4 n = asm_vec4_normalize(a);
    CHECK(approx(asm_vec4_length(n), 1.0f, 1e-5f), "vec4 normalize");
    asm_simd_vec4 sm = asm_vec4_softmax(a);
    CHECK(approx(sm.x + sm.y + sm.z + sm.w, 1.0f, 1e-5f), "vec4 softmax sum");
    asm_simd_vec4 rz = asm_vec4_rotate_z(a, (float)(M_PI / 2.0));
    CHECK(approx(rz.x, -2.0f, 1e-4f) && approx(rz.y, 1.0f, 1e-4f) && approx(rz.w, 4.0f, 1e-4f), "vec4 rotate_z");
}

/*------------------------------------------------------------------------------
 * Matrices
 *----------------------------------------------------------------------------*/
static int near_mat4(asm_mat4 a, asm_mat4 b, float eps) {
    for (int c = 0; c < 4; c++) for (int r = 0; r < 4; r++)
        if (!approx(a.m[c][r], b.m[c][r], eps)) return 0;
    return 1;
}

/* Independent references (Leibniz expansion and Rodrigues) so the port is
 * validated against something other than itself. */
static float ref_det3(asm_mat3 m) {
    float a = m.m[0][0], b = m.m[1][0], c = m.m[2][0];
    float d = m.m[0][1], e = m.m[1][1], f = m.m[2][1];
    float g = m.m[0][2], h = m.m[1][2], i = m.m[2][2];
    return a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g);
}
static float ref_det4(asm_mat4 m) {
    float det = 0.0f;
    for (int c = 0; c < 4; c++) {
        asm_mat3 sub;
        int cc = 0;
        for (int col = 0; col < 4; col++) {
            if (col == c) continue;
            int rr = 0;
            for (int row = 1; row < 4; row++) sub.m[cc][rr++] = m.m[col][row];
            cc++;
        }
        det += ((c & 1) ? -1.0f : 1.0f) * m.m[c][0] * ref_det3(sub);
    }
    return det;
}
static asm_simd_vec3 ref_rotate(asm_simd_vec3 v, asm_simd_vec3 axis, float angle) {
    float c = cosf(angle), s = sinf(angle);
    asm_simd_vec3 k = asm_vec3_normalize(axis);
    asm_simd_vec3 kxv = asm_vec3_cross(k, v);
    float kdv = asm_vec3_dot(k, v);
    asm_simd_vec3 a = asm_vec3_mul(v, c);
    asm_simd_vec3 b = asm_vec3_mul(kxv, s);
    asm_simd_vec3 d = asm_vec3_mul(k, kdv * (1.0f - c));
    return asm_vec3_add(asm_vec3_add(a, b), d);
}

static void test_mat3(void) {
    asm_mat3 I = asm_mat3_identity();
    asm_mat3 A = asm_mat3_new_column_major(1, 2, 3, 4, 5, 6, 7, 8, 9);
    /* A * I == A */
    asm_mat3 AI = asm_mat3_mul(A, I);
    for (int c = 0; c < 3; c++) for (int r = 0; r < 3; r++)
        CHECK(approx(AI.m[c][r], A.m[c][r], 1e-5f), "mat3 mul identity");
    asm_mat3 T = asm_mat3_transpose(A);
    CHECK(approx(T.m[0][1], A.m[1][0], 1e-6f) && approx(T.m[1][0], A.m[0][1], 1e-6f), "mat3 transpose");
    /* determinant of a known triangular matrix */
    asm_mat3 D = asm_mat3_new_column_major(2, 0, 0, 5, 3, 0, 7, 8, 4);
    CHECK(approx(asm_mat3_determinant(D), 24.0f, 1e-4f), "mat3 determinant");
    /* inverse identity for an invertible matrix */
    asm_mat3 B = asm_mat3_new_column_major(4, 3, 2, 1, 5, 7, 9, 6, 8);
    CHECK(approx(asm_mat3_determinant(B), ref_det3(B), 1e-3f), "mat3 det vs reference");
    asm_mat3 Binv = asm_mat3_inverse(B);
    asm_mat3 P = asm_mat3_mul(B, Binv);
    for (int c = 0; c < 3; c++) for (int r = 0; r < 3; r++)
        CHECK(approx(P.m[c][r], (c == r) ? 1.0f : 0.0f, 1e-4f), "mat3 inverse identity");
    /* matrix-vector product */
    asm_vec3 v = {1.0f, 1.0f, 1.0f};
    asm_vec3 r = asm_mat3_mul_vec3(A, v);
    CHECK(approx(r.x, 6.0f, 1e-5f) && approx(r.y, 15.0f, 1e-5f) && approx(r.z, 24.0f, 1e-5f), "mat3 mul_vec3");
}

static asm_mat4 ref_mat4_mul(asm_mat4 a, asm_mat4 b) {
    asm_mat4 r;
    for (int c = 0; c < 4; c++)
        for (int row = 0; row < 4; row++) {
            float s = 0.0f;
            for (int k = 0; k < 4; k++) s += a.m[k][row] * b.m[c][k];
            r.m[c][row] = s;
        }
    return r;
}

static void test_mat4(void) {
    asm_mat4 I = asm_mat4_identity();
    asm_mat4 R = asm_mat4_rotate_z((float)(M_PI / 2.0));
    asm_mat4 T = asm_mat4_translate((asm_vec3){10.0f, 20.0f, 30.0f});
    asm_mat4 S = asm_mat4_scale((asm_vec3){2.0f, 2.0f, 2.0f});
    /* product matches an independent scalar reference */
    CHECK(near_mat4(asm_mat4_mul(T, R), ref_mat4_mul(T, R), 1e-4f), "mat4 mul ref");
    CHECK(near_mat4(asm_mat4_mul(asm_mat4_mul(T, R), S), ref_mat4_mul(ref_mat4_mul(T, R), S), 1e-4f), "mat4 mul ref 2");
    /* translate then transform a point */
    asm_vec4 p = {0.0f, 0.0f, 0.0f, 1.0f};
    asm_vec4 tp = asm_mat4_mul_vec4(T, p);
    CHECK(near4(asm_vec4_load(tp), 10.0f, 20.0f, 30.0f, 1.0f, 1e-5f), "mat4 translate point");
    asm_vec3 td = asm_mat4_transform_direction(T, (asm_vec3){1.0f, 0.0f, 0.0f});
    CHECK(approx(td.x, 1.0f, 1e-5f) && approx(td.y, 0.0f, 1e-5f), "mat4 transform direction");
    /* inverse identity */
    asm_mat4 M = asm_mat4_mul(asm_mat4_mul(T, R), S);
    asm_mat4 Mi = asm_mat4_inverse(M);
    CHECK(near_mat4(asm_mat4_mul(M, Mi), I, 1e-3f), "mat4 inverse identity");
    CHECK(approx(asm_mat4_determinant(M), ref_det4(M), 1e-2f), "mat4 det vs reference");
    /* transpose */
    asm_mat4 Mt = asm_mat4_transpose(M);
    CHECK(approx(Mt.m[0][1], M.m[1][0], 1e-6f), "mat4 transpose");
    /* perspective / look_at are finite and sane */
    asm_mat4 P = asm_mat4_perspective(1.0f, 16.0f / 9.0f, 0.1f, 100.0f);
    CHECK(isfinite(P.m[0][0]) && fabsf(P.m[3][3]) < 1e-9f, "mat4 perspective");
    asm_mat4 V = asm_mat4_look_at(asm_vec3_load((asm_vec3){0, 0, 5}), asm_vec3_load((asm_vec3){0, 0, 0}), asm_vec3_load((asm_vec3){0, 1, 0}));
    CHECK(isfinite(V.m[0][0]), "mat4 look_at");
    asm_mat4 O = asm_mat4_ortho(-1, 1, -1, 1, 1, 10);
    CHECK(approx(O.m[0][0], 1.0f, 1e-6f), "mat4 ortho");
    /* unproject round-trip */
    asm_mat4 VP = asm_mat4_mul(P, V);
    asm_vec3 world = {0.5f, -0.25f, -3.0f};
    asm_vec4 clip = asm_mat4_mul_vec4(VP, (asm_vec4){world.x, world.y, world.z, 1.0f});
    asm_vec3 ndc = {clip.x / clip.w, clip.y / clip.w, clip.z / clip.w};
    asm_vec3 back = asm_mat4_unproject(asm_mat4_inverse(VP), ndc);
    CHECK(near3(asm_vec3_load(back), world.x, world.y, world.z, 1e-3f), "mat4 unproject round-trip");
}

/*------------------------------------------------------------------------------
 * Quaternions
 *----------------------------------------------------------------------------*/
static void test_quat(void) {
    asm_quat I = asm_quat_identity();
    (void)I;
    asm_vec3 axis = {0.0f, 0.0f, 1.0f};
    float ang = (float)(M_PI / 2.0);
    asm_quat q = asm_quat_from_axis_angle(axis, ang);
    CHECK(approx(asm_quat_length(q), 1.0f, 1e-5f), "quat length");
    asm_simd_vec3 v = asm_vec3_load((asm_vec3){1.0f, 0.0f, 0.0f});
    asm_simd_vec3 r = asm_quat_rotate_vec3(q, v);
    CHECK(near3(r, 0.0f, 1.0f, 0.0f, 1e-5f), "quat rotate 90z");
    asm_simd_vec3 rr = ref_rotate(v, asm_vec3_load(axis), ang);
    CHECK(near3(r, rr.x, rr.y, rr.z, 1e-4f), "quat vs Rodrigues");
    /* agrees with the equivalent matrix */
    asm_mat4 qm = asm_mat4_from_quat(q);
    asm_vec4 rm = asm_mat4_mul_vec4(qm, (asm_vec4){1.0f, 0.0f, 0.0f, 1.0f});
    CHECK(near3(asm_vec3_load((asm_vec3){rm.x, rm.y, rm.z}), r.x, r.y, r.z, 1e-5f), "quat vs matrix");
    /* compose two 90-degree rotations == 180 degrees */
    asm_quat q2 = asm_quat_mul(q, q);
    asm_simd_vec3 r2 = asm_quat_rotate_vec3(q2, v);
    CHECK(near3(r2, -1.0f, 0.0f, 0.0f, 1e-5f), "quat compose");
    /* slerp endpoints */
    asm_quat qb = asm_quat_from_axis_angle((asm_vec3){0, 1, 0}, (float)(M_PI / 3.0));
    asm_quat s0 = asm_quat_slerp(q, qb, 0.0f);
    CHECK(approx(s0.x, q.x, 1e-4f) && approx(s0.w, q.w, 1e-4f), "quat slerp t=0");
    asm_quat s1 = asm_quat_slerp(q, qb, 1.0f);
    CHECK(approx(asm_quat_dot(s1, qb), 1.0f, 1e-4f), "quat slerp t=1");
    /* from_mat4 round trip */
    asm_quat qrt = asm_quat_from_mat4(asm_mat4_from_quat(q));
    CHECK(fabsf(asm_quat_dot(qrt, q)) > 1.0f - 1e-4f, "quat from_mat4 round trip");
    /* euler -> quaternion produces a unit quaternion */
    asm_quat qe = asm_quat_from_euler(0.1f, 0.2f, 0.3f);
    CHECK(approx(asm_quat_length(qe), 1.0f, 1e-4f), "quat from_euler unit");
    /* conjugate inverts a rotation */
    asm_quat qc = asm_quat_conjugate(q);
    asm_quat id = asm_quat_mul(q, qc);
    CHECK(approx(fabsf(id.w), 1.0f, 1e-5f), "quat conjugate");
}

int main(void) {
    printf("== asmlib linalg test suite ==\n");
    test_vec2(); printf("   vec2    done\n");
    test_vec3(); printf("   vec3    done\n");
    test_vec4(); printf("   vec4    done\n");
    test_mat3(); printf("   mat3    done\n");
    test_mat4(); printf("   mat4    done\n");
    test_quat(); printf("   quat    done\n");
    printf("== %lu checks, %lu failures ==\n", checks, failures);
    return failures != 0;
}
