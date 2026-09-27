;==============================================================================
; cpu.asm - runtime CPU feature detection (System V AMD64 ABI)
;------------------------------------------------------------------------------
; The vectorised routines in this library require AVX2 and BMI1 (tzcnt). This
; module lets a caller verify support before invoking them, and exposes a few
; other feature bits that are useful when choosing an algorithm.
;
;   unsigned asm_cpu_features(void);   bitmask, see ASMLIB_CPU_* in asmlib.h
;   int      asm_cpu_has_avx2(void);   1 if AVX2 + OS vector state are usable
;==============================================================================

BITS 64
default rel

%include "common.inc"

; Feature bit assignments (must agree with include/asmlib.h).
%define FEAT_SSE2   (1 << 0)
%define FEAT_AVX    (1 << 1)
%define FEAT_AVX2   (1 << 2)
%define FEAT_BMI1   (1 << 3)
%define FEAT_BMI2   (1 << 4)
%define FEAT_ERMS   (1 << 5)
%define FEAT_POPCNT (1 << 6)
%define FEAT_FMA    (1 << 7)

section .text

;==============================================================================
; unsigned asm_cpu_features(void)
;------------------------------------------------------------------------------
; Returns a bitmask of the ASMLIB_CPU_* feature bits supported by this CPU
; and by the operating system (for the vector-state-dependent features).
;==============================================================================
global asm_cpu_features:function
asm_cpu_features:
    push    rbx                         ; cpuid clobbers rbx; preserve it
    xor     r10d, r10d                  ; r10d accumulates the result bits
    ; ---- CPUID leaf 0: maximum basic leaf
    xor     eax, eax
    cpuid
    cmp     eax, 1                      ; is leaf 1 available?
    jb      .done                       ; no: nothing else to probe
    ; ---- CPUID leaf 1: SSE2, AVX, OSXSAVE, POPCNT, FMA
    mov     eax, 1
    cpuid
    test    edx, 1 << 26                ; SSE2
    jz      .no_sse2
    or      r10d, FEAT_SSE2
.no_sse2:
    test    ecx, 1 << 23                ; POPCNT
    jz      .no_popcnt
    or      r10d, FEAT_POPCNT
.no_popcnt:
    test    ecx, 1 << 12                ; FMA
    jz      .no_fma
    or      r10d, FEAT_FMA
.no_fma:
    ; AVX requires the CPU bit, the OSXSAVE bit and OS support (XCR0).
    mov     r8d, ecx                    ; copy feature flags
    and     r8d, (1 << 27) | (1 << 28)  ; OSXSAVE and AVX
    cmp     r8d, (1 << 27) | (1 << 28)
    jne     .no_avx
    xor     ecx, ecx                    ; xgetbv with XCR0
    xgetbv                              ; edx:eax = XCR0
    and     eax, 0x6                    ; XMM and YMM state enabled?
    cmp     eax, 0x6
    jne     .no_avx
    or      r10d, FEAT_AVX              ; AVX is usable
.no_avx:
    ; ---- CPUID leaf 7 subleaf 0: AVX2, BMI1, BMI2, ERMS
    mov     eax, 7
    xor     ecx, ecx
    cpuid
    test    ebx, 1 << 5                 ; AVX2
    jz      .no_avx2
    or      r10d, FEAT_AVX2
.no_avx2:
    test    ebx, 1 << 3                 ; BMI1 (tzcnt)
    jz      .no_bmi1
    or      r10d, FEAT_BMI1
.no_bmi1:
    test    ebx, 1 << 8                 ; BMI2
    jz      .no_bmi2
    or      r10d, FEAT_BMI2
.no_bmi2:
    test    ebx, 1 << 9                 ; ERMS (enhanced REP MOVSB)
    jz      .done
    or      r10d, FEAT_ERMS
.done:
    mov     eax, r10d                   ; return the accumulated mask
    pop     rbx
    ret

;==============================================================================
; int asm_cpu_has_avx2(void)
;------------------------------------------------------------------------------
; Convenience predicate: 1 when AVX2 (and OS vector state) can be used.
;==============================================================================
global asm_cpu_has_avx2:function
asm_cpu_has_avx2:
    sub     rsp, 8                      ; align the stack for the call
    call    asm_cpu_features            ; rax = feature mask
    add     rsp, 8
    and     eax, FEAT_AVX2              ; isolate the AVX2 bit
    setne   al                          ; 1 if present
    movzx   eax, al
    ret

GNU_STACK_NOTE
