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
;
; Parameters (System V AMD64 ABI):
;   none
; Returns:
;   rax = feature bitmask (ASMLIB_CPU_* bits)
; Uses / clobbers:
;   reads CPUID/XGETBV; writes rax, rcx, rdx, r8, r10; rbx is callee-saved and
;   is saved/restored with push/pop across the body
;==============================================================================
global asm_cpu_features:function        ; export the feature probe as a function
asm_cpu_features:
    ; ---- save callee-saved state and clear the result accumulator ----
    push    rbx                         ; cpuid clobbers rbx; preserve it
    xor     r10d, r10d                  ; r10d accumulates the result bits
    ; ---- CPUID leaf 0: maximum basic leaf
    xor     eax, eax                    ; eax = 0 (query the highest basic leaf)
    cpuid                               ; eax = max leaf; ebx/ecx/edx = vendor id
    cmp     eax, 1                      ; is leaf 1 available?
    jb      .done                       ; no: nothing else to probe
    ; ---- CPUID leaf 1: SSE2, AVX, OSXSAVE, POPCNT, FMA
    mov     eax, 1                      ; eax = 1 (select leaf 1: feature flags)
    cpuid                               ; edx/ecx = feature flag words
    test    edx, 1 << 26                ; test edx bit 26 (SSE2)
    jz      .no_sse2                    ; absent: skip the bit
    or      r10d, FEAT_SSE2             ; set the SSE2 bit
.no_sse2:
    test    ecx, 1 << 23                ; test ecx bit 23 (POPCNT)
    jz      .no_popcnt                  ; absent: skip the bit
    or      r10d, FEAT_POPCNT           ; set the POPCNT bit
.no_popcnt:
    test    ecx, 1 << 12                ; test ecx bit 12 (FMA)
    jz      .no_fma                     ; absent: skip the bit
    or      r10d, FEAT_FMA              ; set the FMA bit
.no_fma:
    ; AVX requires the CPU bit, the OSXSAVE bit and OS support (XCR0).
    mov     r8d, ecx                    ; copy feature flags
    and     r8d, (1 << 27) | (1 << 28)  ; keep OSXSAVE (27) and AVX (28) bits
    cmp     r8d, (1 << 27) | (1 << 28)  ; are both bits set?
    jne     .no_avx                     ; no: AVX not usable
    xor     ecx, ecx                    ; xgetbv with XCR0
    xgetbv                              ; edx:eax = XCR0
    and     eax, 0x6                    ; test XMM (bit 1) and YMM (bit 2) state
    cmp     eax, 0x6                    ; are both XMM and YMM state enabled?
    jne     .no_avx                     ; no: OS does not save the vector state
    or      r10d, FEAT_AVX              ; AVX is usable
.no_avx:
    ; ---- CPUID leaf 7 subleaf 0: AVX2, BMI1, BMI2, ERMS
    mov     eax, 7                      ; eax = 7 (extended-features leaf)
    xor     ecx, ecx                    ; ecx = 0 (subleaf 0)
    cpuid                               ; ebx/ecx/edx = extended feature flags
    test    ebx, 1 << 5                 ; test ebx bit 5 (AVX2)
    jz      .no_avx2                    ; absent: skip the bit
    or      r10d, FEAT_AVX2             ; set the AVX2 bit
.no_avx2:
    test    ebx, 1 << 3                 ; test ebx bit 3 (BMI1, tzcnt)
    jz      .no_bmi1                    ; absent: skip the bit
    or      r10d, FEAT_BMI1             ; set the BMI1 bit
.no_bmi1:
    test    ebx, 1 << 8                 ; test ebx bit 8 (BMI2)
    jz      .no_bmi2                    ; absent: skip the bit
    or      r10d, FEAT_BMI2             ; set the BMI2 bit
.no_bmi2:
    test    ebx, 1 << 9                 ; test ebx bit 9 (ERMS, enhanced REP MOVSB)
    jz      .done                       ; absent: skip the bit
    or      r10d, FEAT_ERMS             ; set the ERMS bit
.done:
    ; ---- publish the accumulated mask and restore callee-saved rbx ----
    mov     eax, r10d                   ; return the accumulated mask
    pop     rbx                         ; restore the callee-saved rbx
    ret                                 ; return eax

;==============================================================================
; int asm_cpu_has_avx2(void)
;------------------------------------------------------------------------------
; Convenience predicate: 1 when AVX2 (and OS vector state) can be used.
;
; Parameters (System V AMD64 ABI):
;   none
; Returns:
;   rax = 1 when the AVX2 bit is set, 0 otherwise (zero-extended)
; Uses / clobbers:
;   calls asm_cpu_features, which clobbers rax, rcx, rdx, r8, r10; rsp is
;   adjusted by 8 so the stack stays 16-byte aligned across the call
;==============================================================================
global asm_cpu_has_avx2:function        ; export the AVX2 predicate as a function
asm_cpu_has_avx2:
    ; ---- probe with a 16-byte-aligned stack (sub 8 cancels the call's push) ----
    sub     rsp, 8                      ; align the stack for the call
    call    asm_cpu_features            ; rax = feature mask
    add     rsp, 8                      ; drop the alignment slot
    ; ---- reduce the feature mask to a 0/1 boolean ----
    and     eax, FEAT_AVX2              ; isolate the AVX2 bit
    setne   al                          ; al = 1 if the bit is present
    movzx   eax, al                     ; zero-extend al into eax (0 or 1)
    ret                                 ; return the predicate in eax

;==============================================================================
; void asm_cpu_require_avx2(void)
;------------------------------------------------------------------------------
; Fails fast when the CPU cannot run the vectorised routines: if AVX2 and BMI1
; are not both usable, writes a short message to stderr and exits the process
; with status 2 (raw write(2) + exit_group(2), no libc). Returns normally when
; the CPU is supported. Call it once at startup for a clear error instead of a
; SIGILL deep inside a vector routine.
;
; Parameters (System V AMD64 ABI):
;   none
; Returns:
;   nothing (does not return when AVX2/BMI1 are missing)
; Uses / clobbers:
;   reads CPUID; clobbers rax, rcx, rdx, rdi, rsi, r8, r10, r11
;==============================================================================
global asm_cpu_require_avx2:function
asm_cpu_require_avx2:
    sub     rsp, 8                      ; align the stack for the call
    call    asm_cpu_features            ; rax = feature mask
    add     rsp, 8                      ; drop the alignment slot
    and     eax, FEAT_AVX2 | FEAT_BMI1  ; the two features the library needs
    cmp     eax, FEAT_AVX2 | FEAT_BMI1
    je      .ok                         ; both present -> return normally
    ; ---- write(2, msg, len) ----
    mov     eax, 1                      ; SYS_write
    mov     edi, 2                      ; fd = stderr
    lea     rsi, [rel L_cpu_msg]
    mov     edx, L_cpu_msg_len
    syscall
    ; ---- exit_group(2) ----
    mov     eax, 231                    ; SYS_exit_group
    mov     edi, 2                      ; status = 2
    syscall
    ud2                                 ; never reached
.ok:
    ret

section .rodata
L_cpu_msg: db "asmlib: this CPU lacks AVX2/BMI1; the vector routines cannot run.", 10
L_cpu_msg_len equ $ - L_cpu_msg

GNU_STACK_NOTE                          ; emit the non-executable .note.GNU-stack section
