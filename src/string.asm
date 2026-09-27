;==============================================================================
; string.asm - high-performance x86-64 C string routines (System V AMD64 ABI)
;------------------------------------------------------------------------------
; Implements AVX2-accelerated replacements for the common string routines:
;
;   size_t asm_strlen (const char *s);
;   size_t asm_strnlen(const char *s, size_t maxlen);
;   char  *asm_strcpy (char *dst, const char *src);
;   char  *asm_stpcpy (char *dst, const char *src);
;   char  *asm_strncpy(char *dst, const char *src, size_t n);
;   char  *asm_strcat (char *dst, const char *src);
;   char  *asm_strncat(char *dst, const char *src, size_t n);
;
; All speculative vector reads are page safe: strlen-style scans align the
; pointer down to a 32-byte boundary first (never crossing a 4096-byte page),
; and bounded scans only read fully-contained blocks before finishing with a
; scalar loop.
;==============================================================================

BITS 64
default rel

%include "common.inc"

; Memory primitives defined in memory.asm and reused to build the string
; routines without duplicating the vectorised copy/fill code.
extern asm_memcpy
extern asm_memset

section .text

;==============================================================================
; size_t asm_strlen(const char *s)
;------------------------------------------------------------------------------
; Returns the number of bytes before the terminating NUL.
;==============================================================================
global asm_strlen:function
asm_strlen:
    mov     r8, rdi                     ; r8 = original string pointer
    and     rdi, -32                    ; align down: this block stays in-page
    vpxor   ymm0, ymm0, ymm0            ; ymm0 = all zero
    vmovdqa ymm1, [rdi]                 ; load the aligned 32-byte block
    vpcmpeqb ymm1, ymm1, ymm0           ; 0xFF where a NUL byte is present
    vpmovmskb eax, ymm1                 ; bitmask of NUL bytes
    mov     ecx, r8d                    ; ecx = low bits of the original pointer
    and     ecx, 31                     ; ecx = offset within the aligned block
    shr     eax, cl                     ; discard bytes before the string start
    test    eax, eax                    ; a NUL in the visible part?
    jnz     .first_found                ; yes: this is the shortest string
    add     rdi, 32                     ; move past the first partial block
.scan:
    mov     eax, edi                    ; can we safely read 256 bytes at once?
    and     eax, PAGE_SIZE-1
    cmp     eax, PAGE_SIZE-256          ; the whole block must stay in the page
    ja      .single32                   ; no: use page-safe single vectors
    ; ---- eight aligned blocks (256 bytes) per iteration ------------------
    ; The minimum of the raw bytes across all eight blocks is zero exactly
    ; where any block contains a NUL, so one vpcmpeqb detects them all.
.loop256:
    vmovdqa ymm1, [rdi]                 ; blocks [0,32) .. [224,256)
    vmovdqa ymm2, [rdi+32]
    vmovdqa ymm3, [rdi+64]
    vmovdqa ymm4, [rdi+96]
    vmovdqa ymm5, [rdi+128]
    vmovdqa ymm6, [rdi+160]
    vmovdqa ymm7, [rdi+192]
    vmovdqa ymm8, [rdi+224]
    vpminub ymm1, ymm1, ymm2            ; reduce 8 vectors into 1
    vpminub ymm3, ymm3, ymm4
    vpminub ymm5, ymm5, ymm6
    vpminub ymm7, ymm7, ymm8
    vpminub ymm1, ymm1, ymm3
    vpminub ymm5, ymm5, ymm7
    vpminub ymm1, ymm1, ymm5
    vpcmpeqb ymm1, ymm1, ymm0           ; zero in the min => NUL in the block
    vpmovmskb eax, ymm1                 ; one mask for the whole 256 bytes
    test    eax, eax                    ; any NUL in the whole 256 bytes?
    jnz     .found256                   ; yes: pinpoint it
    add     rdi, 256                    ; advance a whole block
    mov     eax, edi                    ; still safely inside one page?
    and     eax, PAGE_SIZE-1
    cmp     eax, PAGE_SIZE-256
    jbe     .loop256                    ; yes: keep using the wide loop
    ; else fall through to the page-safe single-vector loop
.single32:
    vmovdqa ymm1, [rdi]                 ; one 32-byte aligned block
    vpcmpeqb ymm1, ymm1, ymm0
    vpmovmskb eax, ymm1
    test    eax, eax
    jnz     .found32                    ; NUL in this block
    add     rdi, 32                     ; advance
    jmp     .scan                       ; maybe the wide loop is safe again
.found32:
    tzcnt   eax, eax                    ; offset of the NUL in this block
    add     rdi, rax                    ; absolute address of the NUL
    sub     rdi, r8                     ; distance from the original string
    mov     rax, rdi                    ; return the length
    vzeroupper
    ret
.first_found:
    tzcnt   eax, eax                    ; index of the first NUL = string length
    vzeroupper
    ret
.found256:
    vmovdqa ymm1, [rdi]                 ; rescan the eight blocks one by one
    vpcmpeqb ymm1, ymm1, ymm0
    vpmovmskb eax, ymm1
    test    eax, eax
    jnz     .at
    add     rdi, 32
    vmovdqa ymm1, [rdi]
    vpcmpeqb ymm1, ymm1, ymm0
    vpmovmskb eax, ymm1
    test    eax, eax
    jnz     .at
    add     rdi, 32
    vmovdqa ymm1, [rdi]
    vpcmpeqb ymm1, ymm1, ymm0
    vpmovmskb eax, ymm1
    test    eax, eax
    jnz     .at
    add     rdi, 32
    vmovdqa ymm1, [rdi]
    vpcmpeqb ymm1, ymm1, ymm0
    vpmovmskb eax, ymm1
    test    eax, eax
    jnz     .at
    add     rdi, 32
    vmovdqa ymm1, [rdi]
    vpcmpeqb ymm1, ymm1, ymm0
    vpmovmskb eax, ymm1
    test    eax, eax
    jnz     .at
    add     rdi, 32
    vmovdqa ymm1, [rdi]
    vpcmpeqb ymm1, ymm1, ymm0
    vpmovmskb eax, ymm1
    test    eax, eax
    jnz     .at
    add     rdi, 32
    vmovdqa ymm1, [rdi]
    vpcmpeqb ymm1, ymm1, ymm0
    vpmovmskb eax, ymm1
    test    eax, eax
    jnz     .at
    add     rdi, 32
    vmovdqa ymm1, [rdi]
    vpcmpeqb ymm1, ymm1, ymm0
    vpmovmskb eax, ymm1
.at:
    tzcnt   eax, eax                    ; offset of the NUL in the found block
    add     rdi, rax                    ; absolute address of the NUL
    sub     rdi, r8                     ; distance from the original string
    mov     rax, rdi                    ; return the length
    vzeroupper
    ret

;==============================================================================
; size_t asm_strnlen(const char *s, size_t maxlen)
;------------------------------------------------------------------------------
; Returns strnlen(s, maxlen): the number of bytes before the NUL, capped at
; maxlen. Never reads a byte at or beyond s + maxlen.
;==============================================================================
global asm_strnlen:function
asm_strnlen:
    xor     eax, eax                    ; rax = length counted so far
    test    rsi, rsi                    ; maxlen == 0?
    jz      .ret                        ; yes: length is 0
    mov     r8, rdi                     ; r8 = s
    lea     r9, [rdi+rsi]               ; r9 = end = s + maxlen
    and     rdi, -32                    ; rdi = aligned block base
    vpxor   ymm0, ymm0, ymm0            ; ymm0 = all zero
.block:
    lea     rcx, [rdi+32]               ; rcx = end of the current block
    cmp     rcx, r9                     ; does the whole block fit before end?
    ja      .tail                       ; no: finish with a scalar loop
    vmovdqa ymm1, [rdi]                 ; load 32 bytes
    vpcmpeqb ymm1, ymm1, ymm0           ; detect NULs
    vpmovmskb edx, ymm1                 ; bitmask
    cmp     rdi, r8                     ; is this the first (possibly partial)?
    jb      .first                      ; yes: mask off bytes before s
    test    edx, edx                    ; NUL present?
    jz      .advance                    ; no: skip the block
    tzcnt   edx, edx                    ; index of NUL within the block
    add     rax, rdx                    ; total length
    vzeroupper
    ret
.first:
    mov     ecx, r8d                    ; ecx = low bits of s
    and     ecx, 31                     ; offset within the aligned block
    shr     edx, cl                     ; keep only bytes at/after s
    test    edx, edx                    ; NUL in the visible part?
    jz      .advance_first              ; no: skip the rest of this block
    tzcnt   edx, edx                    ; index relative to s
    add     rax, rdx                    ; total length (rax is 0 here)
    vzeroupper
    ret
.advance_first:
    mov     rax, 32                     ; this block contributes...
    sub     rax, rcx                    ; ...32 - offset bytes from s
    add     rdi, 32                     ; advance to the next block
    jmp     .block
.advance:
    add     rax, 32                     ; a full block of non-NUL bytes
    add     rdi, 32
    jmp     .block
.tail:
    cmp     rdi, r8                     ; is the scalar start before s?
    jae     .tail_scan                  ; no: use it as is
    mov     rdi, r8                     ; yes: start exactly at s
.tail_scan:
    cmp     rdi, r9                     ; reached the end?
    jae     .done
.tail_loop:
    cmp     byte [rdi], 0               ; NUL here?
    je      .done                       ; yes: stop
    inc     rdi                         ; advance
    inc     rax                         ; count one more byte
    cmp     rdi, r9                     ; reached the end?
    jb      .tail_loop
.done:
    vzeroupper
.ret:
    ret

;==============================================================================
; char *asm_strcpy(char *dst, const char *src)
;------------------------------------------------------------------------------
; Copies src (including its NUL) to dst. Returns dst.
;==============================================================================
global asm_strcpy:function
asm_strcpy:
    push    rbx                         ; preserve callee-saved registers
    push    r12
    sub     rsp, 8                      ; realign the stack for calls
    mov     rbx, rdi                    ; rbx = dst
    mov     r12, rsi                    ; r12 = src
    mov     rdi, rsi                    ; first arg to strlen
    call    asm_strlen                  ; rax = string length
    lea     rdx, [rax+1]                ; include the terminating NUL
    mov     rdi, rbx                    ; destination
    mov     rsi, r12                    ; source
    call    asm_memcpy                  ; copy length + 1 bytes
    mov     rax, rbx                    ; return original dst
    add     rsp, 8
    pop     r12
    pop     rbx
    ret

;==============================================================================
; char *asm_stpcpy(char *dst, const char *src)
;------------------------------------------------------------------------------
; Copies src (including its NUL) to dst. Returns a pointer to the NUL that
; terminates the copied string (i.e. dst + strlen(src)).
;==============================================================================
global asm_stpcpy:function
asm_stpcpy:
    push    rbx                         ; preserve callee-saved registers
    push    r12
    push    r13
    mov     rbx, rdi                    ; rbx = dst
    mov     r12, rsi                    ; r12 = src
    mov     rdi, rsi                    ; first arg to strlen
    call    asm_strlen                  ; rax = string length
    mov     r13, rax                    ; keep the length
    lea     rdx, [rax+1]                ; include the terminating NUL
    mov     rdi, rbx                    ; destination
    mov     rsi, r12                    ; source
    call    asm_memcpy                  ; copy length + 1 bytes
    lea     rax, [rbx+r13]              ; return pointer to the new NUL
    pop     r13
    pop     r12
    pop     rbx
    ret

;==============================================================================
; char *asm_strncpy(char *dst, const char *src, size_t n)
;------------------------------------------------------------------------------
; Copies at most n bytes of src. If src is shorter than n, the remainder of
; dst is padded with NUL bytes. Returns dst.
;==============================================================================
global asm_strncpy:function
asm_strncpy:
    push    rbx                         ; preserve callee-saved registers
    push    r12
    push    r13
    push    r14
    sub     rsp, 8                      ; keep the stack 16-byte aligned
    mov     rbx, rdi                    ; rbx = dst
    mov     r12, rsi                    ; r12 = src
    mov     r13, rdx                    ; r13 = n
    mov     rdi, rsi                    ; first arg to strnlen
    mov     rsi, rdx                    ; second arg to strnlen
    call    asm_strnlen                 ; rax = min(strlen(src), n)
    mov     r14, rax                    ; r14 = copied length
    mov     rdi, rbx                    ; destination
    mov     rsi, r12                    ; source
    mov     rdx, r14                    ; count
    call    asm_memcpy                  ; copy the string bytes
    cmp     r14, r13                    ; did we copy everything asked for?
    jae     .done                       ; yes: no padding required
    lea     rdi, [rbx+r14]              ; start of the padding region
    xor     esi, esi                    ; fill with NUL
    mov     rdx, r13                    ; total requested
    sub     rdx, r14                    ; remaining bytes to zero
    call    asm_memset                  ; pad with NULs
.done:
    mov     rax, rbx                    ; return dst
    add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

;==============================================================================
; char *asm_strcat(char *dst, const char *src)
;------------------------------------------------------------------------------
; Appends src (including its NUL) to the end of dst. Returns dst.
;==============================================================================
global asm_strcat:function
asm_strcat:
    push    rbx                         ; preserve callee-saved registers
    push    r12
    sub     rsp, 8                      ; realign the stack for calls
    mov     rbx, rdi                    ; rbx = dst
    mov     r12, rsi                    ; r12 = src
    mov     rdi, rbx                    ; first arg to strlen
    call    asm_strlen                  ; rax = strlen(dst)
    lea     rdi, [rbx+rax]              ; destination = end of dst
    mov     rsi, r12                    ; source
    call    asm_strcpy                  ; append src (with NUL)
    mov     rax, rbx                    ; return dst
    add     rsp, 8
    pop     r12
    pop     rbx
    ret

;==============================================================================
; char *asm_strncat(char *dst, const char *src, size_t n)
;------------------------------------------------------------------------------
; Appends at most n bytes of src to dst and always NUL-terminates. Returns dst.
;==============================================================================
global asm_strncat:function
asm_strncat:
    push    rbx                         ; preserve callee-saved registers
    push    r12
    push    r13
    push    r14
    push    r15                         ; five pushes keep rsp 16-byte aligned
    mov     rbx, rdi                    ; rbx = dst
    mov     r12, rsi                    ; r12 = src
    mov     r13, rdx                    ; r13 = n
    mov     rdi, rbx                    ; first arg to strlen
    call    asm_strlen                  ; rax = strlen(dst)
    lea     r14, [rbx+rax]              ; r14 = append position
    mov     rdi, r12                    ; first arg to strnlen
    mov     rsi, r13                    ; second arg to strnlen
    call    asm_strnlen                 ; rax = min(strlen(src), n)
    mov     r15, rax                    ; r15 = number of bytes to append
    mov     rdi, r14                    ; destination
    mov     rsi, r12                    ; source
    mov     rdx, r15                    ; bytes to copy
    call    asm_memcpy                  ; append the bytes
    mov     byte [r14+r15], 0           ; terminate the result
    mov     rax, rbx                    ; return dst
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

GNU_STACK_NOTE
