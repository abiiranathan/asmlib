;==============================================================================
; string.asm - high-performance x86-64 C string routines (System V AMD64 ABI)
;------------------------------------------------------------------------------
; Implements AVX2-accelerated replacements for the common string routines:
;
;   size_t asm_strlen (const char *s);
;   size_t asm_strnlen(const char *s, size_t maxlen);
;   char  *asm_strncpy(char *dst, const char *src, size_t n);
;   char  *asm_stpncpy(char *dst, const char *src, size_t n);
;   char  *asm_strncat(char *dst, const char *src, size_t n);
;   size_t asm_strlcpy(char *dst, const char *src, size_t size);
;   size_t asm_strlcat(char *dst, const char *src, size_t size);
;
; All speculative vector reads are page safe: strlen-style scans align the
; pointer down to a 32-byte boundary first (never crossing a 4096-byte page),
; and bounded scans only read fully-contained blocks before finishing with a
; scalar loop.
;==============================================================================

BITS 64                                 ; assemble 64-bit code
default rel                             ; RIP-relative addressing by default

%include "common.inc"                   ; PAGE_SIZE, YMM_BYTES and GNU_STACK_NOTE

; Memory primitives defined in memory.asm and reused to build the string
; routines without duplicating the vectorised copy/fill code.
extern asm_memcpy                       ; copy primitive from memory.asm
extern asm_memset                       ; fill primitive from memory.asm

section .text                           ; code section

;==============================================================================
; size_t asm_strlen(const char *s)
;------------------------------------------------------------------------------
; Returns the number of bytes before the terminating NUL.
;
; Parameters (System V AMD64 ABI):
;   rdi = s (const char *)  - NUL-terminated string to measure
; Returns:
;   rax = number of bytes before the terminating NUL
; Uses / clobbers:
;   reads rdi, rcx, r8; writes rax, rcx, rdi, r8 and ymm0-ymm8; clobbers
;   the flags; touches no callee-saved register and calls no function.
;==============================================================================
global asm_strlen:function              ; export asm_strlen as a function symbol
asm_strlen:
    ; ---- align-down head block: inspect the first aligned 32 bytes ----
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
    ; ---- advance past the first (possibly partial) block ----
    add     rdi, 32                     ; move past the first partial block
.scan:
    ; ---- page-safety check: only read 256 bytes that stay in one page ----
    mov     eax, edi                    ; can we safely read 256 bytes at once?
    and     eax, PAGE_SIZE-1            ; mask off the low 12 bits: byte offset within the page
    cmp     eax, PAGE_SIZE-256          ; the whole block must stay in the page
    ja      .single32                   ; no: use page-safe single vectors
    ; ---- eight aligned blocks (256 bytes) per iteration ------------------
    ; The minimum of the raw bytes across all eight blocks is zero exactly
    ; where any block contains a NUL, so one vpcmpeqb detects them all.
.loop256:
    vmovdqa ymm1, [rdi]                 ; blocks [0,32) .. [224,256)
    vmovdqa ymm2, [rdi+32]              ; load block [32,64)
    vmovdqa ymm3, [rdi+64]              ; load block [64,96)
    vmovdqa ymm4, [rdi+96]              ; load block [96,128)
    vmovdqa ymm5, [rdi+128]             ; load block [128,160)
    vmovdqa ymm6, [rdi+160]             ; load block [160,192)
    vmovdqa ymm7, [rdi+192]             ; load block [192,224)
    vmovdqa ymm8, [rdi+224]             ; load block [224,256)
    vpminub ymm1, ymm1, ymm2            ; reduce 8 vectors into 1
    vpminub ymm3, ymm3, ymm4            ; min blocks 2 and 3
    vpminub ymm5, ymm5, ymm6            ; min blocks 4 and 5
    vpminub ymm7, ymm7, ymm8            ; min blocks 6 and 7
    vpminub ymm1, ymm1, ymm3            ; min the low four blocks
    vpminub ymm5, ymm5, ymm7            ; min the high four blocks
    vpminub ymm1, ymm1, ymm5            ; min all eight blocks: NUL anywhere => zero here
    vpcmpeqb ymm1, ymm1, ymm0           ; zero in the min => NUL in the block
    vpmovmskb eax, ymm1                 ; one mask for the whole 256 bytes
    test    eax, eax                    ; any NUL in the whole 256 bytes?
    jnz     .found256                   ; yes: pinpoint it
    add     rdi, 256                    ; advance a whole block
    mov     eax, edi                    ; still safely inside one page?
    and     eax, PAGE_SIZE-1            ; mask off the low 12 bits
    cmp     eax, PAGE_SIZE-256          ; still at least 256 bytes before the page boundary?
    jbe     .loop256                    ; yes: keep using the wide loop
    ; else fall through to the page-safe single-vector loop
    ; ---- single-vector fallback: one page-safe 32-byte block at a time ----
.single32:
    vmovdqa ymm1, [rdi]                 ; one 32-byte aligned block
    vpcmpeqb ymm1, ymm1, ymm0           ; 0xFF where a NUL byte is present
    vpmovmskb eax, ymm1                 ; bitmask of NUL bytes
    test    eax, eax                    ; any NUL in this block?
    jnz     .found32                    ; NUL in this block
    add     rdi, 32                     ; advance
    jmp     .scan                       ; maybe the wide loop is safe again
.found32:
    tzcnt   eax, eax                    ; offset of the NUL in this block
    add     rdi, rax                    ; absolute address of the NUL
    sub     rdi, r8                     ; distance from the original string
    mov     rax, rdi                    ; return the length
    vzeroupper                          ; clear the upper YMM state
    ret                                 ; return the length in rax
.first_found:
    tzcnt   eax, eax                    ; index of the first NUL = string length
    vzeroupper                          ; clear the upper YMM state
    ret                                 ; return the length in rax
    ; ---- pinpoint the NUL among the eight cached blocks ----
.found256:
    vmovdqa ymm1, [rdi]                 ; rescan the eight blocks one by one
    vpcmpeqb ymm1, ymm1, ymm0           ; detect NULs in block 1
    vpmovmskb eax, ymm1                 ; bitmask for block 1
    test    eax, eax                    ; NUL in block 1?
    jnz     .at                         ; yes: pinpoint it
    add     rdi, 32                     ; advance to block 2
    vmovdqa ymm1, [rdi]                 ; load block 2
    vpcmpeqb ymm1, ymm1, ymm0           ; detect NULs in block 2
    vpmovmskb eax, ymm1                 ; bitmask for block 2
    test    eax, eax                    ; NUL in block 2?
    jnz     .at                         ; yes: pinpoint it
    add     rdi, 32                     ; advance to block 3
    vmovdqa ymm1, [rdi]                 ; load block 3
    vpcmpeqb ymm1, ymm1, ymm0           ; detect NULs in block 3
    vpmovmskb eax, ymm1                 ; bitmask for block 3
    test    eax, eax                    ; NUL in block 3?
    jnz     .at                         ; yes: pinpoint it
    add     rdi, 32                     ; advance to block 4
    vmovdqa ymm1, [rdi]                 ; load block 4
    vpcmpeqb ymm1, ymm1, ymm0           ; detect NULs in block 4
    vpmovmskb eax, ymm1                 ; bitmask for block 4
    test    eax, eax                    ; NUL in block 4?
    jnz     .at                         ; yes: pinpoint it
    add     rdi, 32                     ; advance to block 5
    vmovdqa ymm1, [rdi]                 ; load block 5
    vpcmpeqb ymm1, ymm1, ymm0           ; detect NULs in block 5
    vpmovmskb eax, ymm1                 ; bitmask for block 5
    test    eax, eax                    ; NUL in block 5?
    jnz     .at                         ; yes: pinpoint it
    add     rdi, 32                     ; advance to block 6
    vmovdqa ymm1, [rdi]                 ; load block 6
    vpcmpeqb ymm1, ymm1, ymm0           ; detect NULs in block 6
    vpmovmskb eax, ymm1                 ; bitmask for block 6
    test    eax, eax                    ; NUL in block 6?
    jnz     .at                         ; yes: pinpoint it
    add     rdi, 32                     ; advance to block 7
    vmovdqa ymm1, [rdi]                 ; load block 7
    vpcmpeqb ymm1, ymm1, ymm0           ; detect NULs in block 7
    vpmovmskb eax, ymm1                 ; bitmask for block 7
    test    eax, eax                    ; NUL in block 7?
    jnz     .at                         ; yes: pinpoint it
    add     rdi, 32                     ; advance to block 8
    vmovdqa ymm1, [rdi]                 ; load block 8
    vpcmpeqb ymm1, ymm1, ymm0           ; detect NULs in block 8
    vpmovmskb eax, ymm1                 ; bitmask for block 8; fall through to .at
.at:
    tzcnt   eax, eax                    ; offset of the NUL in the found block
    add     rdi, rax                    ; absolute address of the NUL
    sub     rdi, r8                     ; distance from the original string
    mov     rax, rdi                    ; return the length
    vzeroupper                          ; clear the upper YMM state
    ret                                 ; return the length in rax

;==============================================================================
; size_t asm_strnlen(const char *s, size_t maxlen)
;------------------------------------------------------------------------------
; Returns strnlen(s, maxlen): the number of bytes before the NUL, capped at
; maxlen. Never reads a byte at or beyond s + maxlen.
;
; Parameters (System V AMD64 ABI):
;   rdi = s      (const char *)  - string to measure
;   rsi = maxlen (size_t)        - maximum number of bytes to examine
; Returns:
;   rax = min(strlen(s), maxlen)
; Uses / clobbers:
;   reads rdi, rsi, r8, r9; writes rax, rcx, rdx, rdi, r8, r9 and
;   ymm0-ymm1; clobbers the flags; touches no callee-saved register and
;   calls no function.
;==============================================================================
global asm_strnlen:function             ; export asm_strnlen as a function symbol
asm_strnlen:
    ; ---- set up bounds and clear the accumulator ----
    xor     eax, eax                    ; rax = length counted so far
    test    rsi, rsi                    ; maxlen == 0?
    jz      .ret                        ; yes: length is 0
    mov     r8, rdi                     ; r8 = s
    lea     r9, [rdi+rsi]               ; r9 = end = s + maxlen
    and     rdi, -32                    ; rdi = aligned block base
    vpxor   ymm0, ymm0, ymm0            ; ymm0 = all zero
    ; ---- 32-byte block loop: only blocks fully inside [s, end) ----
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
    vzeroupper                          ; clear the upper YMM state
    ret                                 ; return the length in rax
    ; ---- first block: mask off the bytes before s ----
.first:
    mov     ecx, r8d                    ; ecx = low bits of s
    and     ecx, 31                     ; offset within the aligned block
    shr     edx, cl                     ; keep only bytes at/after s
    test    edx, edx                    ; NUL in the visible part?
    jz      .advance_first              ; no: skip the rest of this block
    tzcnt   edx, edx                    ; index relative to s
    add     rax, rdx                    ; total length (rax is 0 here)
    vzeroupper                          ; clear the upper YMM state
    ret                                 ; return the length in rax
    ; ---- skip the remainder of the first block ----
.advance_first:
    mov     rax, 32                     ; this block contributes...
    sub     rax, rcx                    ; ...32 - offset bytes from s
    add     rdi, 32                     ; advance to the next block
    jmp     .block                      ; continue with the next block
    ; ---- full in-bounds block with no NUL: count all 32 bytes ----
.advance:
    add     rax, 32                     ; a full block of non-NUL bytes
    add     rdi, 32                     ; advance to the next block
    jmp     .block                      ; continue with the next block
    ; ---- scalar tail: final partial block, bounded by end ----
.tail:
    cmp     rdi, r8                     ; is the scalar start before s?
    jae     .tail_scan                  ; no: use it as is
    mov     rdi, r8                     ; yes: start exactly at s
.tail_scan:
    cmp     rdi, r9                     ; reached the end?
    jae     .done                       ; yes: stop without reading past end
    ; ---- scalar byte loop ----
.tail_loop:
    cmp     byte [rdi], 0               ; NUL here?
    je      .done                       ; yes: stop
    inc     rdi                         ; advance
    inc     rax                         ; count one more byte
    cmp     rdi, r9                     ; reached the end?
    jb      .tail_loop                  ; no: keep scanning
.done:
    vzeroupper                          ; clear the upper YMM state
.ret:
    ret                                 ; return the length in rax

;==============================================================================
; char *asm_strncpy(char *dst, const char *src, size_t n)
;------------------------------------------------------------------------------
; Copies at most n bytes of src. If src is shorter than n, the remainder of
; dst is padded with NUL bytes. Returns dst.
;
; Parameters (System V AMD64 ABI):
;   rdi = dst (char *)        - destination buffer
;   rsi = src (const char *)  - source string
;   rdx = n   (size_t)        - maximum number of bytes to write
; Returns:
;   rax = dst
; Uses / clobbers:
;   pushes and restores rbx, r12, r13 and r14 (callee-saved) and reserves
;   8 bytes to keep rsp 16-byte aligned; calls asm_strnlen, asm_memcpy
;   and asm_memset; result in rax.
;==============================================================================
global asm_strncpy:function             ; export asm_strncpy as a function symbol
asm_strncpy:
    ; ---- prologue: preserve callee-saved registers, align the stack ----
    push    rbx                         ; preserve callee-saved registers
    push    r12                         ; save r12 (callee-saved)
    push    r13                         ; save r13 (callee-saved)
    push    r14                         ; save r14 (callee-saved)
    sub     rsp, 8                      ; keep the stack 16-byte aligned
    mov     rbx, rdi                    ; rbx = dst
    mov     r12, rsi                    ; r12 = src
    mov     r13, rdx                    ; r13 = n
    ; ---- call sequence: bounded length, copy, then NUL-pad the remainder ----
    mov     rdi, rsi                    ; first arg to strnlen
    mov     rsi, rdx                    ; second arg to strnlen
    call    asm_strnlen                 ; rax = min(strlen(src), n)
    mov     r14, rax                    ; r14 = copied length
    mov     rdi, rbx                    ; destination
    mov     rsi, r12                    ; source
    mov     rdx, r14                    ; count
    call    asm_memcpy                  ; copy the string bytes
    ; ---- NUL-pad the tail when src was shorter than n ----
    cmp     r14, r13                    ; did we copy everything asked for?
    jae     .done                       ; yes: no padding required
    lea     rdi, [rbx+r14]              ; start of the padding region
    xor     esi, esi                    ; fill with NUL
    mov     rdx, r13                    ; total requested
    sub     rdx, r14                    ; remaining bytes to zero
    call    asm_memset                  ; pad with NULs
.done:
    mov     rax, rbx                    ; return dst
    ; ---- epilogue: restore the saved registers and return dst ----
    add     rsp, 8                      ; undo the stack alignment adjustment
    pop     r14                         ; restore r14
    pop     r13                         ; restore r13
    pop     r12                         ; restore r12
    pop     rbx                         ; restore rbx
    ret                                 ; return rax = dst

;==============================================================================
; char *asm_stpncpy(char *dst, const char *src, size_t n)
;------------------------------------------------------------------------------
; POSIX stpncpy: copies at most n bytes of src. If src is shorter than n the
; rest of the n-byte region is NUL-padded. Returns a pointer to the NUL that
; terminates dst when src fitted (strlen(src) < n), otherwise dst + n.
;
; Parameters (System V AMD64 ABI):
;   rdi = dst (char *)        - destination buffer
;   rsi = src (const char *)  - source string
;   rdx = n   (size_t)        - size of the destination region
; Returns:
;   rax = dst + strlen(src) when strlen(src) < n (the written NUL),
;         else dst + n
; Uses / clobbers:
;   Pushes and restores rbx/r12/r13/r14 (callee-saved) and reserves 8 bytes
;   to keep rsp 16-byte aligned at every call; calls asm_strnlen, asm_memcpy
;   and asm_memset; result in rax.
;==============================================================================
global asm_stpncpy:function             ; export asm_stpncpy as a function symbol
asm_stpncpy:
    ; ---- prologue: preserve callee-saved registers, align the stack ----
    push    rbx                         ; preserve callee-saved registers
    push    r12                         ; save r12 (callee-saved)
    push    r13                         ; save r13 (callee-saved)
    push    r14                         ; save r14 (callee-saved)
    sub     rsp, 8                      ; keep the stack 16-byte aligned
    mov     rbx, rdi                    ; rbx = dst
    mov     r12, rsi                    ; r12 = src
    mov     r13, rdx                    ; r13 = n
    ; ---- copy the bounded string, then pad the remainder ---------------
    mov     rdi, rsi                    ; first arg to strnlen
    mov     rsi, rdx                    ; second arg to strnlen
    call    asm_strnlen                 ; rax = min(strlen(src), n)
    mov     r14, rax                    ; r14 = copied length
    mov     rdi, rbx                    ; destination
    mov     rsi, r12                    ; source
    mov     rdx, r14                    ; count
    call    asm_memcpy                  ; copy the string bytes
    cmp     r14, r13                    ; did src fill the whole region?
    jae     .full                       ; yes: no terminating NUL was written
    ; ---- src shorter than n: NUL-pad the tail, return the NUL ----------
    lea     rdi, [rbx+r14]              ; start of the padding region
    xor     esi, esi                    ; fill with NUL
    mov     rdx, r13                    ; total requested
    sub     rdx, r14                    ; remaining bytes to zero
    call    asm_memset                  ; pad with NULs
    lea     rax, [rbx+r14]              ; return the terminating NUL
    jmp     .done                       ; common epilogue
    ; ---- src filled the region: return just past it --------------------
.full:
    lea     rax, [rbx+r13]              ; return dst + n
    ; ---- epilogue: restore the saved registers and return --------------
.done:
    add     rsp, 8                      ; undo the stack alignment adjustment
    pop     r14                         ; restore r14
    pop     r13                         ; restore r13
    pop     r12                         ; restore r12
    pop     rbx                         ; restore rbx
    ret                                 ; return rax

;==============================================================================
; char *asm_strncat(char *dst, const char *src, size_t n)
;------------------------------------------------------------------------------
; Appends at most n bytes of src to dst and always NUL-terminates. Returns dst.
;
; Parameters (System V AMD64 ABI):
;   rdi = dst (char *)        - NUL-terminated destination string
;   rsi = src (const char *)  - string to append
;   rdx = n   (size_t)        - maximum number of bytes to append
; Returns:
;   rax = dst
; Uses / clobbers:
;   pushes and restores rbx, r12, r13, r14 and r15 (callee-saved; five
;   pushes keep rsp 16-byte aligned); calls asm_strlen, asm_strnlen and
;   asm_memcpy; result in rax.
;==============================================================================
global asm_strncat:function             ; export asm_strncat as a function symbol
asm_strncat:
    ; ---- prologue: preserve callee-saved registers ----
    push    rbx                         ; preserve callee-saved registers
    push    r12                         ; save r12 (callee-saved)
    push    r13                         ; save r13 (callee-saved)
    push    r14                         ; save r14 (callee-saved)
    push    r15                         ; five pushes keep rsp 16-byte aligned
    mov     rbx, rdi                    ; rbx = dst
    mov     r12, rsi                    ; r12 = src
    mov     r13, rdx                    ; r13 = n
    ; ---- call sequence: dst end, bounded src length, copy, terminate ----
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
    ; ---- epilogue: restore the saved registers and return dst ----
    pop     r15                         ; restore r15
    pop     r14                         ; restore r14
    pop     r13                         ; restore r13
    pop     r12                         ; restore r12
    pop     rbx                         ; restore rbx
    ret                                 ; return rax = dst

;==============================================================================
; size_t asm_strlcpy(char *dst, const char *src, size_t size)
;------------------------------------------------------------------------------
; BSD strlcpy: copies at most size-1 bytes of src, always NUL-terminates when
; size > 0, and returns strlen(src). Never reads or writes past dst[size-1].
;
; Parameters (System V AMD64 ABI):
;   rdi = dst  (char *)       - destination buffer
;   rsi = src  (const char *) - source string
;   rdx = size (size_t)       - total size of the destination buffer
; Returns:
;   rax = strlen(src)
; Uses / clobbers:
;   Pushes and restores rbx/r12/r13/r14 (callee-saved) and reserves 8 bytes
;   to keep rsp 16-byte aligned at every call; calls asm_strlen and
;   asm_memcpy; result in rax.
;==============================================================================
global asm_strlcpy:function             ; export asm_strlcpy as a function symbol
asm_strlcpy:
    ; ---- prologue: preserve callee-saved registers, align the stack ----
    push    rbx                         ; preserve callee-saved registers
    push    r12                         ; save r12 (callee-saved)
    push    r13                         ; save r13 (callee-saved)
    push    r14                         ; save r14 (callee-saved)
    sub     rsp, 8                      ; keep the stack 16-byte aligned
    mov     rbx, rdi                    ; rbx = dst
    mov     r12, rsi                    ; r12 = src
    mov     r13, rdx                    ; r13 = size
    ; ---- measure src, then copy min(strlen, size-1) and terminate ------
    mov     rdi, rsi                    ; first arg to strlen
    call    asm_strlen                  ; rax = strlen(src)
    mov     r14, rax                    ; r14 = strlen(src) (the return value)
    test    r13, r13                    ; size == 0?
    jz      .done                       ; yes: write nothing, just return length
    mov     rdx, r13                    ; rdx = size
    dec     rdx                         ; rdx = size - 1 (maximum copy)
    cmp     r14, rdx                    ; strlen(src) < size - 1?
    jb      .use_len                    ; yes: copy the whole string
    ; ---- truncate: copy size-1 bytes (rdx already holds size-1) --------
    mov     r13, rdx                    ; r13 = bytes to copy
    jmp     .copy                       ; go copy
.use_len:
    mov     r13, r14                    ; r13 = bytes to copy = strlen(src)
.copy:
    mov     rdi, rbx                    ; destination
    mov     rsi, r12                    ; source
    mov     rdx, r13                    ; count
    call    asm_memcpy                  ; copy the bytes
    mov     byte [rbx+r13], 0           ; NUL-terminate at dst[copy]
    ; ---- return strlen(src) --------------------------------------------
.done:
    mov     rax, r14                    ; return strlen(src)
    add     rsp, 8                      ; undo the stack alignment adjustment
    pop     r14                         ; restore r14
    pop     r13                         ; restore r13
    pop     r12                         ; restore r12
    pop     rbx                         ; restore rbx
    ret                                 ; return rax

;==============================================================================
; size_t asm_strlcat(char *dst, const char *src, size_t size)
;------------------------------------------------------------------------------
; BSD strlcat: appends at most size - strlen(dst) - 1 bytes of src, always
; NUL-terminates, and returns min(size, strlen(dst)) + strlen(src). When no
; NUL exists within the first size bytes of dst it writes nothing and returns
; size + strlen(src). Never writes past dst[size-1].
;
; Parameters (System V AMD64 ABI):
;   rdi = dst  (char *)       - NUL-terminated destination string
;   rsi = src  (const char *) - string to append
;   rdx = size (size_t)       - total size of the destination buffer
; Returns:
;   rax = min(size, strlen(dst)) + strlen(src)
; Uses / clobbers:
;   Pushes and restores rbx/r12/r13/r14/r15 (callee-saved; five pushes keep
;   rsp 16-byte aligned); calls asm_strnlen, asm_strlen and asm_memcpy;
;   result in rax.
;==============================================================================
global asm_strlcat:function             ; export asm_strlcat as a function symbol
asm_strlcat:
    ; ---- prologue: preserve callee-saved registers ----
    push    rbx                         ; preserve callee-saved registers
    push    r12                         ; save r12 (callee-saved)
    push    r13                         ; save r13 (callee-saved)
    push    r14                         ; save r14 (callee-saved)
    push    r15                         ; five pushes keep rsp 16-byte aligned
    mov     rbx, rdi                    ; rbx = dst
    mov     r12, rsi                    ; r12 = src
    mov     r13, rdx                    ; r13 = size
    ; ---- bounded dst length, then full src length ----------------------
    mov     rdi, rbx                    ; first arg to strnlen
    mov     rsi, r13                    ; second arg to strnlen (size)
    call    asm_strnlen                 ; rax = min(strlen(dst), size)
    mov     r14, rax                    ; r14 = bounded dst length
    mov     rdi, r12                    ; first arg to strlen
    call    asm_strlen                  ; rax = strlen(src)
    mov     r15, rax                    ; r15 = strlen(src)
    ; ---- if dst has no NUL within size, write nothing ------------------
    cmp     r14, r13                    ; bounded length reached size?
    jae     .done                       ; yes: no terminating NUL, no write
    ; ---- append min(strlen(src), size - dlen - 1) and terminate --------
    mov     rdx, r13                    ; rdx = size
    sub     rdx, r14                    ; rdx = size - dlen
    dec     rdx                         ; rdx = size - dlen - 1 (room)
    cmp     r15, rdx                    ; strlen(src) < room?
    jb      .use_len                    ; yes: append the whole string
    ; ---- truncate: append only the room bytes --------------------------
    mov     r13, rdx                    ; r13 = bytes to append
    jmp     .copy                       ; go append
.use_len:
    mov     r13, r15                    ; r13 = bytes to append = strlen(src)
.copy:
    mov     rdi, rbx                    ; destination
    add     rdi, r14                    ; start at dst + dlen
    mov     rsi, r12                    ; source
    mov     rdx, r13                    ; count
    call    asm_memcpy                  ; append the bytes
    lea     rdx, [r14+r13]              ; rdx = dlen + appended length
    mov     byte [rbx+rdx], 0           ; NUL-terminate after the appended bytes
    ; ---- return dlen + strlen(src) -------------------------------------
.done:
    lea     rax, [r14+r15]              ; return dlen + strlen(src)
    pop     r15                         ; restore r15
    pop     r14                         ; restore r14
    pop     r13                         ; restore r13
    pop     r12                         ; restore r12
    pop     rbx                         ; restore rbx
    ret                                 ; return rax

GNU_STACK_NOTE                          ; mark the stack non-executable
