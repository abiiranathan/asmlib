/*==============================================================================
 * cpu.S - runtime CPU feature detection (AArch64)
 *------------------------------------------------------------------------------
 * SPDX-License-Identifier: MIT
 *
 * AArch64 port of src/cpu.asm. The public contract is unchanged from the
 * x86-64 build so a caller can use one header:
 *
 *   unsigned asm_cpu_features(void);   bitmask, see ASMLIB_CPU_* in asmlib.h
 *   int      asm_cpu_has_avx2(void);   1 if AVX2 + OS vector state are usable
 *
 * The ASMLIB_CPU_* bits are all x86 concepts (SSE2, AVX, AVX2, BMI1/BMI2,
 * ERMS, POPCNT, FMA); none of them has an AArch64 meaning, so the returned
 * mask is always 0. The routine still probes the standard AArch64 ID
 * registers with `mrs` so the file documents what an AArch64 feature query
 * would read, but no ASMLIB_CPU_* bit is set from it.
 *
 * asm_cpu_has_avx2() MUST report 0 on AArch64: there is no AVX2 here, and the
 * vectorised x86 routines it guards are simply not part of this port.
 *
 * AArch64 Linux makes the ID_AA64*_EL1 identification registers readable at
 * EL0, so the `mrs` reads below are safe in a normal user process.
 *============================================================================*/

#include "common_aarch64.inc"

    .text

/*==============================================================================
 * unsigned asm_cpu_features(void)
 *------------------------------------------------------------------------------
 * Returns the ASMLIB_CPU_* feature bitmap. Every defined bit is x86-only, so
 * on AArch64 the result is 0.
 *
 * Parameters (AAPCS64):
 *   none
 * Returns:
 *   w0 = 0 (no ASMLIB_CPU_* bit is meaningful on AArch64)
 * Uses / clobbers:
 *   writes w0; x9 and x10 are caller-saved scratch holding the ID register
 *   values while the (empty) mapping is evaluated
 *============================================================================*/
    .globl asm_cpu_features
    .type  asm_cpu_features, %function
    .p2align 2
asm_cpu_features:
    /* ---- read the AArch64 feature identification registers ---- */
    mrs     x9, ID_AA64ISAR0_EL1        /* x9  = ISA feature set (AdvSIMD, crc, ...) */
    mrs     x10, ID_AA64PFR0_EL1        /* x10 = processor features (FP, AdvSIMD, ...) */
    /* ---- no ASMLIB_CPU_* bit maps onto an AArch64 capability ---- */
    mov     w0, #0                      /* x86-only bitmap: always zero here     */
    ret                                 /* return 0                                */
    .size asm_cpu_features, .-asm_cpu_features

/*==============================================================================
 * int asm_cpu_has_avx2(void)
 *------------------------------------------------------------------------------
 * Convenience predicate. AVX2 does not exist on AArch64, so this is always 0.
 *
 * Parameters (AAPCS64):
 *   none
 * Returns:
 *   w0 = 0
 *============================================================================*/
    .globl asm_cpu_has_avx2
    .type  asm_cpu_has_avx2, %function
    .p2align 2
asm_cpu_has_avx2:
    /* ---- there is no AVX2 on AArch64: report unsupported ---- */
    mov     w0, #0                      /* predicate is always false             */
    ret                                 /* return 0                                */
    .size asm_cpu_has_avx2, .-asm_cpu_has_avx2

GNU_STACK_NOTE
