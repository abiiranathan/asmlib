/*==============================================================================
 * common_aarch64.inc - shared definitions for the AArch64 port
 *------------------------------------------------------------------------------
 * SPDX-License-Identifier: MIT
 *
 * Assembled with the GNU assembler (aarch64-linux-gnu-gcc -c, .S files) or
 * clang's integrated assembler, so this uses GAS syntax and the C preprocessor
 * (.S, not .s). It mirrors src/common.inc for the x86-64 NASM build.
 *
 * AArch64 ABI (AAPCS64 / Linux):
 *   - arguments in x0..x7, further args on the stack; return value in x0.
 *   - x0..x18 and x30 (lr) are caller-saved; x19..x29 are callee-saved.
 *   - the stack must stay 16-byte aligned.
 *   - v0..v7 are argument/return registers; all v8..v31 are caller-saved
 *     except the low 64 bits of v8..v15, so we avoid them for state.
 *   - Linux syscalls: number in x8, args in x0..x5, `svc #0`; x0 = result
 *     (-errno in [-4095, -1] on error).
 *============================================================================*/

#ifndef ASMLIB_COMMON_AARCH64_INC
#define ASMLIB_COMMON_AARCH64_INC

/* Number of bytes in a hardware page: used to keep speculative vector reads
 * inside one page (a 16-byte aligned load cannot straddle a 4096-byte page
 * because 4096 is a multiple of 16). */
#define PAGE_SIZE 4096

/* Convenience: size of one NEON vector register (128-bit) in bytes. */
#define V_BYTES 16

/* Linux aarch64 syscall numbers. */
#define SYS_mmap   222
#define SYS_munmap 215
#define SYS_write  64                /* write(fd, buf, count)             */
#define PROT_RW    3                 /* PROT_READ | PROT_WRITE            */
#define MAP_ANON_PRIV 0x22           /* MAP_PRIVATE | MAP_ANONYMOUS       */
#define ERR_LIMIT  (-4095)           /* [-4095,-1] encodes -errno         */

/* Mark the stack non-executable (GNU-stack note) so the linker does not emit
 * an executable stack for our objects. Mirrors GNU_STACK_NOTE in common.inc. */
#define GNU_STACK_NOTE                                                  \
    .section .note.GNU-stack, "", %progbits

#endif /* ASMLIB_COMMON_AARCH64_INC */
