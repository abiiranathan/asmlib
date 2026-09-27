;==============================================================================
; memory.asm - high-performance x86-64 memory primitives (System V AMD64 ABI)
;------------------------------------------------------------------------------
; Implements AVX2-accelerated replacements for the hot libc memory routines:
;
;   void *asm_memcpy (void *dst, const void *src, size_t n);
;   void *asm_mempcpy(void *dst, const void *src, size_t n);
;   void *asm_memccpy(void *dst, const void *src, int c, size_t n);
;   void *asm_memmove(void *dst, const void *src, size_t n);
;   void *asm_memset (void *dst, int c, size_t n);
;   void *asm_bzero  (void *dst, size_t n);
;   void  asm_explicit_bzero(void *dst, size_t n);
;   int   asm_memcmp (const void *a, const void *b, size_t n);
;   void *asm_memchr (const void *s, int c, size_t n);
;   void *asm_memrchr(const void *s, int c, size_t n);
;
; Register conventions on entry (System V):
;   rdi = first argument, rsi = second, rdx = third
;   rax = return value
;   rdi/rsi/rdx/rcx/r8..r11 are caller-saved (scratch)
;   rbx/rbp/r12..r15 are callee-saved (we do not touch them here)
;   all xmm/ymm registers are caller-saved
;
; Every read is either naturally sized and in-bounds, or a 32-byte aligned
; vector load, so no routine can fault by touching an unmapped page.
;==============================================================================

BITS 64
default rel                     ; RIP-relative addressing for all symbols

%include "common.inc"

section .text

;==============================================================================
; void *asm_memcpy(void *dst, const void *src, size_t n)
;------------------------------------------------------------------------------
; Copies exactly n bytes from src to dst. src and dst must not overlap.
; Returns dst. Small sizes are handled with overlapping scalar/SSE moves;
; large sizes use an unrolled 128-byte AVX2 loop.
;
; Parameters (System V AMD64 ABI):
;   rdi = dst (void *)         - destination buffer start
;   rsi = src (const void *)   - source buffer start
;   rdx = n   (size_t)         - number of bytes to copy
; Returns:
;   rax = dst (the original destination pointer)
; Uses / clobbers:
;   Reads rdi/rsi/rdx; writes rax/rcx/r8 and xmm0-1/ymm0-7. All xmm/ymm are
;   caller-saved; no callee-saved register (rbx/rbp/r12-r15) is touched.
;==============================================================================
global asm_memcpy:function
asm_memcpy:
    ; ---- save return value, then dispatch on the size class -------------
    mov     rax, rdi                    ; rax = dst (return value)
    cmp     rdx, 262144                 ; 256 KiB (L2-sized) or more?
    jae     .nt_copy                    ; yes: non-temporal stores win
    cmp     rdx, 98304                  ; 96 KiB..255 KiB?
    jae     .erms_copy                  ; yes: ERMS rep movsb is fastest
    cmp     rdx, 32                     ; n >= 32 bytes?
    jae     .ge32                       ; yes: enter vectorised path
    cmp     rdx, 16                     ; 16 <= n < 32?
    jae     .16_31                      ; yes: two overlapping 16-byte moves
    cmp     rdx, 8                      ; 8 <= n < 16?
    jae     .8_15                       ; yes: two overlapping 8-byte moves
    cmp     rdx, 4                      ; 4 <= n < 8?
    jae     .4_7                        ; yes: two overlapping 4-byte moves
    test    rdx, rdx                    ; n == 0?
    jz      .done                       ; yes: nothing to do
    ; ---- 1 <= n <= 3: first and last byte, plus the middle byte for n == 3
    movzx   ecx, byte [rsi]             ; load byte 0 of source
    movzx   r8d, byte [rsi+rdx-1]       ; load byte n-1 of source
    mov     [rdi], cl                   ; store byte 0
    mov     [rdi+rdx-1], r8b            ; store byte n-1
    cmp     rdx, 3                      ; exactly three bytes?
    jne     .done                       ; no: 1 or 2 bytes are fully covered
    movzx   ecx, byte [rsi+1]           ; load the middle byte
    mov     [rdi+1], cl                 ; store the middle byte
.done:
    ret                                 ; return dst
    ; ---- 4 <= n <= 7: two overlapping 4-byte moves ---------------------
.4_7:
    mov     ecx, [rsi]                  ; load first 4 bytes
    mov     r8d, [rsi+rdx-4]            ; load last  4 bytes
    mov     [rdi], ecx                  ; store first 4 bytes
    mov     [rdi+rdx-4], r8d            ; store last  4 bytes
    ret                                 ; return dst
    ; ---- 8 <= n <= 15: two overlapping 8-byte moves --------------------
.8_15:
    mov     rcx, [rsi]                  ; load first 8 bytes
    mov     r8, [rsi+rdx-8]             ; load last  8 bytes
    mov     [rdi], rcx                  ; store first 8 bytes
    mov     [rdi+rdx-8], r8             ; store last  8 bytes
    ret                                 ; return dst
    ; ---- 16 <= n <= 31: two overlapping 16-byte moves ------------------
.16_31:
    vmovdqu xmm0, [rsi]                 ; load first 16 bytes
    vmovdqu xmm1, [rsi+rdx-16]          ; load last  16 bytes
    vmovdqu [rdi], xmm0                 ; store first 16 bytes
    vmovdqu [rdi+rdx-16], xmm1          ; store last  16 bytes
    ret                                 ; return dst
    ; ---- very large copies: non-temporal stores avoid read-for-ownership ---
.nt_copy:
    test    dil, 31                     ; is the destination 32-byte aligned?
    jnz     .erms_copy                  ; no: fall back to ERMS for this size
    mov     rcx, rdx                    ; rcx = n
    and     rcx, -128                   ; rcx = n rounded down to 128
    xor     r8d, r8d                    ; r8 = running offset
    ; ---- stream 128 bytes per iteration with non-temporal stores -------
.nt_loop:
    vmovdqu ymm0, [rsi+r8]              ; load bytes   +0  ..  +31
    vmovdqu ymm1, [rsi+r8+32]           ; load bytes  +32  ..  +63
    vmovdqu ymm2, [rsi+r8+64]           ; load bytes  +64  ..  +95
    vmovdqu ymm3, [rsi+r8+96]           ; load bytes  +96  .. +127
    vmovntdq [rdi+r8], ymm0             ; streaming store (no RFO)
    vmovntdq [rdi+r8+32], ymm1          ; stream bytes  +32  ..  +63
    vmovntdq [rdi+r8+64], ymm2          ; stream bytes  +64  ..  +95
    vmovntdq [rdi+r8+96], ymm3          ; stream bytes  +96  .. +127
    add     r8, 128                     ; advance
    cmp     r8, rcx                     ; all full blocks streamed?
    jb      .nt_loop                    ; no: keep going
    sfence                              ; order the non-temporal stores
    ; ---- overlapping 128-byte tail fixup (ordinary stores) -------------
    ; Overlapping final 128-byte block with ordinary stores covers the tail.
    vmovdqu ymm0, [rsi+rdx-128]         ; load tail bytes n-128 .. n-97
    vmovdqu ymm1, [rsi+rdx-96]          ; load tail bytes n-96  .. n-65
    vmovdqu ymm2, [rsi+rdx-64]          ; load tail bytes n-64  .. n-33
    vmovdqu ymm3, [rsi+rdx-32]          ; load tail bytes n-32  .. n-1
    vmovdqu [rdi+rdx-128], ymm0         ; store tail bytes n-128 .. n-97
    vmovdqu [rdi+rdx-96], ymm1          ; store tail bytes n-96  .. n-65
    vmovdqu [rdi+rdx-64], ymm2          ; store tail bytes n-64  .. n-33
    vmovdqu [rdi+rdx-32], ymm3          ; store tail bytes n-32  .. n-1
    vzeroupper                          ; drop AVX state
    ret                                 ; return dst (rax)
    ; ---- n in [96 KiB, 256 KiB): single rep movsb is fastest on this CPU ----
.erms_copy:
    cld                                 ; rep moves forward (DF clear)
    mov     rcx, rdx                    ; rcx = n
.erms_loop:
    rep     movsb                       ; dst=rdi, src=rsi, count=rcx
    ret                                 ; return dst (rax)
    ; ---- n >= 32: vectorised copy path ---------------------------------
.ge32:
    cmp     rdx, 64                     ; 32 <= n <= 64?
    jbe     .32_64                      ; yes: two overlapping 32-byte moves
    cmp     rdx, 128                    ; 65 <= n <= 128?
    jbe     .65_128                     ; yes: four overlapping 32-byte moves
    ; ---- n > 128: copy whole 256-byte blocks, then an overlapping tail ----
    mov     rcx, rdx                    ; rcx = n
    and     rcx, -256                   ; rcx = n rounded down to 256
    test    rcx, rcx                    ; at least one full 256-byte block?
    jz      .129_255                    ; no: 129..255, use two 128-byte moves
    xor     r8d, r8d                    ; r8 = running offset, starts at 0
    ; ---- copy 256 bytes per iteration ----------------------------------
.loop256:
    vmovdqu ymm0, [rsi+r8]              ; load bytes  +0   .. +31
    vmovdqu ymm1, [rsi+r8+32]           ; load bytes +32   .. +63
    vmovdqu ymm2, [rsi+r8+64]           ; load bytes +64   .. +95
    vmovdqu ymm3, [rsi+r8+96]           ; load bytes +96   .. +127
    vmovdqu ymm4, [rsi+r8+128]          ; load bytes +128  .. +159
    vmovdqu ymm5, [rsi+r8+160]          ; load bytes +160  .. +191
    vmovdqu ymm6, [rsi+r8+192]          ; load bytes +192  .. +223
    vmovdqu ymm7, [rsi+r8+224]          ; load bytes +224  .. +255
    vmovdqu [rdi+r8], ymm0              ; store bytes  +0   .. +31
    vmovdqu [rdi+r8+32], ymm1           ; store bytes +32   .. +63
    vmovdqu [rdi+r8+64], ymm2           ; store bytes +64   .. +95
    vmovdqu [rdi+r8+96], ymm3           ; store bytes +96   .. +127
    vmovdqu [rdi+r8+128], ymm4          ; store bytes +128  .. +159
    vmovdqu [rdi+r8+160], ymm5          ; store bytes +160  .. +191
    vmovdqu [rdi+r8+192], ymm6          ; store bytes +192  .. +223
    vmovdqu [rdi+r8+224], ymm7          ; store bytes +224  .. +255
    add     r8, 256                     ; advance to the next block
    cmp     r8, rcx                     ; copied all full blocks?
    jb      .loop256                    ; no: keep going
    cmp     r8, rdx                     ; was n an exact multiple of 256?
    jae     .copy_done                  ; yes: no tail to duplicate
    ; ---- overlapping 256-byte tail fixup -------------------------------
    ; The final 256 bytes are re-copied with an overlapping block. Because
    ; rcx >= n-255, the window [n-256, n) fully covers the [rcx, n) tail.
    vmovdqu ymm0, [rsi+rdx-256]         ; load tail bytes n-256 .. n-225
    vmovdqu ymm1, [rsi+rdx-224]         ; load tail bytes n-224 .. n-193
    vmovdqu ymm2, [rsi+rdx-192]         ; load tail bytes n-192 .. n-161
    vmovdqu ymm3, [rsi+rdx-160]         ; load tail bytes n-160 .. n-129
    vmovdqu ymm4, [rsi+rdx-128]         ; load tail bytes n-128 .. n-97
    vmovdqu ymm5, [rsi+rdx-96]          ; load tail bytes n-96  .. n-65
    vmovdqu ymm6, [rsi+rdx-64]          ; load tail bytes n-64  .. n-33
    vmovdqu ymm7, [rsi+rdx-32]          ; load tail bytes n-32  .. n-1
    vmovdqu [rdi+rdx-256], ymm0         ; store tail bytes n-256 .. n-225
    vmovdqu [rdi+rdx-224], ymm1         ; store tail bytes n-224 .. n-193
    vmovdqu [rdi+rdx-192], ymm2         ; store tail bytes n-192 .. n-161
    vmovdqu [rdi+rdx-160], ymm3         ; store tail bytes n-160 .. n-129
    vmovdqu [rdi+rdx-128], ymm4         ; store tail bytes n-128 .. n-97
    vmovdqu [rdi+rdx-96], ymm5          ; store tail bytes n-96  .. n-65
    vmovdqu [rdi+rdx-64], ymm6          ; store tail bytes n-64  .. n-33
    vmovdqu [rdi+rdx-32], ymm7          ; store tail bytes n-32  .. n-1
    ; ---- common vector-copy exit ---------------------------------------
.copy_done:
    vzeroupper                          ; drop AVX state, avoid SSE transition hit
    ret                                 ; return dst (rax)
    ; ---- 129 <= n <= 255: first and last 128 bytes overlap -------------
.129_255:
    vmovdqu ymm0, [rsi]                 ; first 128 bytes
    vmovdqu ymm1, [rsi+32]              ; load bytes +32  .. +63
    vmovdqu ymm2, [rsi+64]              ; load bytes +64  .. +95
    vmovdqu ymm3, [rsi+96]              ; load bytes +96  .. +127
    vmovdqu [rdi], ymm0                 ; store bytes +0  .. +31
    vmovdqu [rdi+32], ymm1              ; store bytes +32 .. +63
    vmovdqu [rdi+64], ymm2              ; store bytes +64 .. +95
    vmovdqu [rdi+96], ymm3              ; store bytes +96 .. +127
    vmovdqu ymm0, [rsi+rdx-128]         ; last 128 bytes (overlapping)
    vmovdqu ymm1, [rsi+rdx-96]          ; load bytes n-96 .. n-65
    vmovdqu ymm2, [rsi+rdx-64]          ; load bytes n-64 .. n-33
    vmovdqu ymm3, [rsi+rdx-32]          ; load bytes n-32 .. n-1
    vmovdqu [rdi+rdx-128], ymm0         ; store bytes n-128 .. n-97
    vmovdqu [rdi+rdx-96], ymm1          ; store bytes n-96  .. n-65
    vmovdqu [rdi+rdx-64], ymm2          ; store bytes n-64  .. n-33
    vmovdqu [rdi+rdx-32], ymm3          ; store bytes n-32  .. n-1
    vzeroupper                          ; drop AVX state
    ret                                 ; return dst (rax)
    ; ---- 32 <= n <= 64: two overlapping 32-byte moves ------------------
.32_64:
    vmovdqu ymm0, [rsi]                 ; load first 32 bytes
    vmovdqu ymm1, [rsi+rdx-32]          ; load last  32 bytes
    vmovdqu [rdi], ymm0                 ; store first 32 bytes
    vmovdqu [rdi+rdx-32], ymm1          ; store last  32 bytes
    vzeroupper                          ; drop AVX state
    ret                                 ; return dst (rax)
    ; ---- 65 <= n <= 128: four overlapping 32-byte moves ---------------
.65_128:
    vmovdqu ymm0, [rsi]                 ; load bytes  +0  .. +31
    vmovdqu ymm1, [rsi+32]              ; load bytes +32  .. +63
    vmovdqu ymm2, [rsi+rdx-64]          ; load bytes n-64 .. n-33
    vmovdqu ymm3, [rsi+rdx-32]          ; load bytes n-32 .. n-1
    vmovdqu [rdi], ymm0                 ; store bytes  +0  .. +31
    vmovdqu [rdi+32], ymm1              ; store bytes +32  .. +63
    vmovdqu [rdi+rdx-64], ymm2          ; store bytes n-64 .. n-33
    vmovdqu [rdi+rdx-32], ymm3          ; store bytes n-32 .. n-1
    vzeroupper                          ; drop AVX state
    ret                                 ; return dst (rax)

;==============================================================================
; void *asm_mempcpy(void *dst, const void *src, size_t n)
;------------------------------------------------------------------------------
; Copies exactly n non-overlapping bytes from src to dst, like asm_memcpy, and
; returns dst + n (a pointer just past the last byte written).
;
; Parameters (System V AMD64 ABI):
;   rdi = dst (void *)         - destination buffer start
;   rsi = src (const void *)   - source buffer start
;   rdx = n   (size_t)         - number of bytes to copy
; Returns:
;   rax = dst + n (a pointer just past the copied region)
; Uses / clobbers:
;   Pushes and restores rbx (callee-saved); forwards rdi/rsi/rdx to
;   asm_memcpy, so it inherits that routine's clobbers of rax/rcx/r8 and
;   xmm0-1/ymm0-7. No other callee-saved register is touched.
;==============================================================================
global asm_mempcpy:function
asm_mempcpy:
    ; ---- remember dst + n across the copy ------------------------------
    push    rbx                         ; preserve callee-saved rbx
    mov     rbx, rdi                    ; rbx = dst
    add     rbx, rdx                    ; rbx = dst + n (the return value)
    call    asm_memcpy                  ; copy the bytes, rax = dst
    mov     rax, rbx                    ; return dst + n
    pop     rbx                         ; restore callee-saved rbx
    ret                                 ; return dst + n in rax

;==============================================================================
; void *asm_memccpy(void *dst, const void *src, int c, size_t n)
;------------------------------------------------------------------------------
; Copies bytes from src to dst, stopping after the first byte equal to
; (unsigned char)c. Returns a pointer just past that byte in dst, or NULL if
; none of the first n bytes equals c. Never reads or writes past the n-byte
; source/destination windows. Built on the bounded asm_memchr plus asm_memcpy.
;
; Parameters (System V AMD64 ABI):
;   rdi = dst (void *)         - destination buffer start
;   rsi = src (const void *)   - source buffer start
;   edx = c   (int)            - stop byte; only the low 8 bits are used
;   rcx = n   (size_t)         - maximum number of bytes to copy
; Returns:
;   rax = pointer to the byte just past the copy of the first c in dst,
;         or NULL when c does not occur in the first n source bytes
; Uses / clobbers:
;   Pushes and restores rbx/r12/r13 (callee-saved; three pushes keep rsp
;   16-byte aligned at every call); calls asm_memchr and asm_memcpy,
;   inheriting their clobbers. Result in rax.
;==============================================================================
global asm_memccpy:function
asm_memccpy:
    ; ---- prologue: preserve the arguments across the helper calls ------
    push    rbx                         ; preserve callee-saved rbx
    push    r12                         ; preserve callee-saved r12
    push    r13                         ; preserve callee-saved r13 (3 pushes align rsp)
    mov     rbx, rdi                    ; rbx = dst
    mov     r12, rsi                    ; r12 = src
    mov     r13, rcx                    ; r13 = n
    ; ---- locate the first c within the first n source bytes ------------
    mov     rdi, rsi                    ; arg0 = src
    mov     esi, edx                    ; arg1 = c
    mov     rdx, rcx                    ; arg2 = n
    call    asm_memchr                  ; rax = first match, or NULL
    test    rax, rax                    ; did we find c?
    jz      .not_found                  ; no: copy all n bytes, return NULL
    ; ---- copy through the matching byte ---------------------------------
    sub     rax, r12                    ; rax = index of the first c
    inc     rax                         ; rax = bytes to copy (index + 1)
    mov     r13, rax                    ; r13 = bytes to copy
    mov     rdi, rbx                    ; destination
    mov     rsi, r12                    ; source
    mov     rdx, r13                    ; count
    call    asm_memcpy                  ; copy src[0 .. index]
    lea     rax, [rbx+r13]              ; return dst + bytes copied
    jmp     .done                       ; common epilogue
    ; ---- c absent: copy the whole window and report no match -----------
.not_found:
    mov     rdi, rbx                    ; destination
    mov     rsi, r12                    ; source
    mov     rdx, r13                    ; count = n
    call    asm_memcpy                  ; copy all n bytes
    xor     eax, eax                    ; return NULL
    ; ---- epilogue: restore the saved registers -------------------------
.done:
    pop     r13                         ; restore r13
    pop     r12                         ; restore r12
    pop     rbx                         ; restore rbx
    ret                                 ; return rax

;==============================================================================
; void *asm_memmove(void *dst, const void *src, size_t n)
;------------------------------------------------------------------------------
; Like memcpy but the buffers may overlap. Chooses the copy direction so that
; a byte is always read before it can be overwritten. Returns dst.
;
; Parameters (System V AMD64 ABI):
;   rdi = dst (void *)         - destination buffer start
;   rsi = src (const void *)   - source buffer start
;   rdx = n   (size_t)         - number of bytes to move
; Returns:
;   rax = dst (the original destination pointer)
; Uses / clobbers:
;   Reads rdi/rsi/rdx; writes rax/rcx/r8/r9 and ymm0 (plus ymm0-7 when it
;   forwards to asm_memcpy). All xmm/ymm are caller-saved; no callee-saved
;   register (rbx/rbp/r12-r15) is touched.
;==============================================================================
global asm_memmove:function
asm_memmove:
    ; ---- dst == src shortcut and direction dispatch --------------------
    mov     rax, rdi                    ; rax = dst (return value)
    cmp     rdi, rsi                    ; compare the two pointers
    je      .done                       ; dst == src: nothing to do
    ja      .dst_above                  ; dst > src: may need backward copy
    ; ---- dst < src ------------------------------------------------------
    mov     rcx, rdi                    ; rcx = dst
    add     rcx, rdx                    ; rcx = dst + n
    cmp     rcx, rsi                    ; dst + n <= src (fully disjoint)?
    jbe     asm_memcpy                  ; yes: the fast memcpy path is safe
    jmp     .forward_overlap            ; no: overlap-safe forward copy
    ; ---- dst > src: maybe overlapping backward copy --------------------
.dst_above:
    mov     rcx, rsi                    ; rcx = src
    add     rcx, rdx                    ; rcx = src + n
    cmp     rdi, rcx                    ; dst >= src + n (fully disjoint)?
    jae     asm_memcpy                  ; yes: the fast memcpy path is safe
    ; ---- Overlapping with dst > src: copy strictly from high to low ------
    cmp     rdx, 32                     ; n >= 32?
    jb      .small_back                 ; no: byte-wise backward copy
    mov     r8, rdx                     ; r8 = n
    and     r8, 31                      ; r8 = n mod 32 (bottom remainder)
    mov     r9, rdx                     ; r9 = top offset = n
    ; ---- vectorised backward copy (32 bytes/iter) ----------------------
.back_loop:
    sub     r9, 32                      ; step one vector down
    vmovdqu ymm0, [rsi+r9]              ; load  [r9, r9+32)
    vmovdqu [rdi+r9], ymm0              ; store [r9, r9+32)
    cmp     r9, r8                      ; reached the bottom remainder?
    ja      .back_loop                  ; no: continue downward
    ; ---- remaining low bytes, one at a time ----------------------------
    ; The bottom r8 bytes (r8 < 32) are the lowest addresses, so they are the
    ; last to be written; the source there cannot have been touched yet.
    test    r8, r8                      ; any remainder?
    jz      .done                       ; no: done
    mov     rcx, r8                     ; rcx = remainder count
.back_bytes:
    dec     rcx                         ; move to next lower byte
    movzx   r9d, byte [rsi+rcx]         ; load source byte
    mov     [rdi+rcx], r9b              ; store to destination
    test    rcx, rcx                    ; reached byte 0?
    jnz     .back_bytes                 ; no: continue
    ret                                 ; return dst (rax)
    ; ---- n < 32: byte-wise backward copy -------------------------------
.small_back:
    test    rdx, rdx                    ; n == 0?
    jz      .done                       ; yes: nothing to do
    mov     rcx, rdx                    ; rcx = n
    ; ---- byte-wise backward loop ---------------------------------------
.sb_loop:
    dec     rcx                         ; move to next lower byte
    movzx   r9d, byte [rsi+rcx]         ; load source byte
    mov     [rdi+rcx], r9b              ; store to destination
    test    rcx, rcx                    ; reached byte 0?
    jnz     .sb_loop                    ; no: continue
    ret                                 ; return dst (rax)
    ; ---- Overlapping with dst < src: copy strictly from low to high ------
.forward_overlap:
    cmp     rdx, 32                     ; n >= 32?
    jb      .fwd_bytes                  ; no: byte-wise forward copy
    mov     rcx, rdx                    ; rcx = n
    and     rcx, -32                    ; rcx = n rounded down to 32
    xor     r8d, r8d                    ; r8 = running offset
    ; ---- vectorised forward copy (32 bytes/iter) -----------------------
.fwd_loop:
    vmovdqu ymm0, [rsi+r8]              ; load  [r8, r8+32) from source
    vmovdqu [rdi+r8], ymm0              ; store [r8, r8+32) to dest
    add     r8, 32                      ; advance one vector
    cmp     r8, rcx                     ; all full vectors copied?
    jb      .fwd_loop                   ; no: keep going
    vzeroupper                          ; drop AVX state
    cmp     r8, rdx                     ; leftover bytes?
    jae     .done                       ; no: done
    ; ---- forward byte tail after full vectors --------------------------
.fwd_tail:
    movzx   r9d, byte [rsi+r8]          ; load one source byte
    mov     [rdi+r8], r9b               ; store one destination byte
    inc     r8                          ; advance
    cmp     r8, rdx                     ; finished?
    jb      .fwd_tail                   ; no: keep going
    ret                                 ; return dst (rax)
    ; ---- n < 32: byte-wise forward copy --------------------------------
.fwd_bytes:
    xor     r8d, r8d                    ; r8 = 0
    test    rdx, rdx                    ; n == 0?
    jz      .done                       ; yes: nothing to do
    ; ---- byte-wise forward loop ----------------------------------------
.fb_loop:
    movzx   r9d, byte [rsi+r8]          ; load one source byte
    mov     [rdi+r8], r9b               ; store one destination byte
    inc     r8                          ; advance
    cmp     r8, rdx                     ; finished?
    jb      .fb_loop                    ; no: keep going
    ; ---- common return -------------------------------------------------
.done:
    ret                                 ; return dst (rax)

;==============================================================================
; void *asm_memset(void *dst, int c, size_t n)
;------------------------------------------------------------------------------
; Fills n bytes at dst with the low byte of c. Returns dst.
;
; Parameters (System V AMD64 ABI):
;   rdi = dst (void *)         - destination buffer start
;   esi = c   (int)            - fill value; only the low 8 bits are used
;   rdx = n   (size_t)         - number of bytes to fill
; Returns:
;   rax = dst (the original destination pointer)
; Uses / clobbers:
;   Reads rdi/rsi/rdx; writes rax/rcx/r8/r9 and xmm0/ymm0. All xmm/ymm are
;   caller-saved; no callee-saved register (rbx/rbp/r12-r15) is touched.
;==============================================================================
global asm_memset:function
asm_memset:
    ; ---- save return value, then dispatch on n -------------------------
    mov     rax, rdi                    ; rax = dst (return value)
    cmp     rdx, 4096                   ; large fill?
    jae     .rep_set                    ; yes: ERMS rep stosb wins on this CPU
    vmovd   xmm0, esi                   ; move the fill byte into an xmm lane
    vpbroadcastb ymm0, xmm0             ; broadcast it across all 32 ymm bytes
    cmp     rdx, 32                     ; n >= 32?
    jb      .lt32                       ; no: use the small-size paths
    cmp     rdx, 64                     ; 32 <= n <= 64?
    jbe     .32_64                      ; yes: two overlapping 32-byte stores
    ; ---- n > 64: store 32-byte blocks, then an overlapping final block
    ; ---- n > 64: store 32-byte blocks, then an overlapping final block ----
.big_set:
    mov     rcx, rdx                    ; rcx = n
    and     rcx, -32                    ; rcx = n rounded down to 32
    xor     r8d, r8d                    ; r8 = running offset
    ; ---- store 32 bytes per iteration ----------------------------------
.loop:
    vmovdqu [rdi+r8], ymm0              ; store 32 bytes at offset r8
    add     r8, 32                      ; advance
    cmp     r8, rcx                     ; all full blocks stored?
    jb      .loop                       ; no: keep going
    vmovdqu [rdi+rdx-32], ymm0          ; store the overlapping final 32 bytes
    vzeroupper                          ; drop AVX state
    ret                                 ; return dst (rax)
    ; ---- 32 <= n <= 64: two overlapping 32-byte stores -----------------
.32_64:
    vmovdqu [rdi], ymm0                 ; store first 32 bytes
    vmovdqu [rdi+rdx-32], ymm0          ; store last  32 bytes
    vzeroupper                          ; drop AVX state
    ret                                 ; return dst (rax)
    ; ---- large fills: enhanced REP STOSB (ERMS) is fastest on this CPU ----
.rep_set:
    mov     r8, rax                     ; r8 = dst (the return value)
    mov     rcx, rdx                    ; rcx = n
    movzx   eax, sil                    ; al = fill byte
    rep     stosb                       ; fill [dst, dst+n) with al
    mov     rax, r8                     ; restore the return value
    ret                                 ; return dst (rax)
    ; ---- n < 32: small-size dispatch -----------------------------------
.lt32:
    cmp     rdx, 16                     ; 16 <= n < 32?
    jb      .lt16                       ; no: try smaller widths
    vmovdqu [rdi], xmm0                 ; store first 16 bytes
    vmovdqu [rdi+rdx-16], xmm0          ; store last  16 bytes
    ret                                 ; return dst (rax)
    ; ---- 8 <= n < 16: two overlapping 8-byte stores --------------------
.lt16:
    cmp     rdx, 8                      ; 8 <= n < 16?
    jb      .lt8                        ; no: try smaller widths
    movzx   ecx, sil                    ; ecx = fill byte
    mov     r9, 0x0101010101010101      ; byte-broadcast multiplier
    imul    r9, rcx                     ; r9 = byte repeated in all 8 bytes
    mov     [rdi], r9                   ; store first 8 bytes
    mov     [rdi+rdx-8], r9             ; store last  8 bytes
    ret                                 ; return dst (rax)
    ; ---- 4 <= n < 8: two overlapping 4-byte stores ---------------------
.lt8:
    cmp     rdx, 4                      ; 4 <= n < 8?
    jb      .lt4                        ; no: 1..3 bytes
    movzx   ecx, sil                    ; ecx = fill byte
    imul    ecx, ecx, 0x01010101        ; repeat byte into all 4 bytes
    mov     [rdi], ecx                  ; store first 4 bytes
    mov     [rdi+rdx-4], ecx            ; store last  4 bytes
    ret                                 ; return dst (rax)
    ; ---- 1..3 bytes: first, last and (for 3) middle byte ----------------
.lt4:
    test    rdx, rdx                    ; n == 0?
    jz      .done                       ; yes: nothing to do
    movzx   ecx, sil                    ; ecx = fill byte
    mov     [rdi], cl                   ; store byte 0
    mov     [rdi+rdx-1], cl             ; store byte n-1
    cmp     rdx, 3                      ; exactly three bytes?
    jne     .done                       ; no: 1 or 2 are fully covered
    mov     [rdi+1], cl                 ; store the middle byte
    ; ---- common return -------------------------------------------------
.done:
    ret                                 ; return dst (rax)

;==============================================================================
; void *asm_bzero(void *dst, size_t n)
;------------------------------------------------------------------------------
; Zeroes n bytes at dst. Returns dst. Implemented on top of asm_memset.
;
; Parameters (System V AMD64 ABI):
;   rdi = dst (void *)         - destination buffer start
;   rsi = n   (size_t)         - number of bytes to zero
; Returns:
;   rax = dst (the original destination pointer)
; Uses / clobbers:
;   Reads rdi/rsi; rewrites rdx/rsi/rdi/rax and (via asm_memset) xmm0/ymm0.
;   All xmm/ymm are caller-saved; no callee-saved register is touched.
;==============================================================================
global asm_bzero:function
asm_bzero:
    ; ---- forward bzero to asm_memset with c == 0 -----------------------
    mov     rdx, rsi                    ; third arg (n) = old second arg
    xor     esi, esi                    ; fill byte = 0
    jmp     asm_memset                  ; tail-call the shared implementation

;==============================================================================
; void asm_explicit_bzero(void *dst, size_t n)
;------------------------------------------------------------------------------
; Zeroes n bytes at dst like asm_bzero, but the stores must not be elided.
; Because this is a real out-of-line function (not a macro and not inline),
; the call is an opaque memory clobber from the caller's point of view, so a
; compiler may not discard it as dead code. Implemented as a tail-call to
; asm_memset with c == 0.
;
; Parameters (System V AMD64 ABI):
;   rdi = dst (void *)         - destination buffer start
;   rsi = n   (size_t)         - number of bytes to zero
; Returns:
;   none
; Uses / clobbers:
;   Reads rdi/rsi; rewrites rdx/rsi and (via asm_memset) rax/rcx/r8/r9 and
;   xmm0/ymm0. All xmm/ymm are caller-saved; no callee-saved register is
;   touched.
;==============================================================================
global asm_explicit_bzero:function
asm_explicit_bzero:
    ; ---- forward to asm_memset with c == 0 -----------------------------
    mov     rdx, rsi                    ; third arg (n) = old second arg
    xor     esi, esi                    ; fill byte = 0
    jmp     asm_memset                  ; tail-call the shared implementation

;==============================================================================
; int asm_memcmp(const void *a, const void *b, size_t n)
;------------------------------------------------------------------------------
; Compares the first n bytes. Returns <0, 0 or >0 using unsigned byte values.
;
; Parameters (System V AMD64 ABI):
;   rdi = a (const void *)     - first buffer start
;   rsi = b (const void *)     - second buffer start
;   rdx = n (size_t)           - number of bytes to compare
; Returns:
;   rax = signed difference (a[i] - b[i]) at the first differing byte,
;         or 0 when the first n bytes are equal
; Uses / clobbers:
;   Reads rdi/rsi/rdx; writes rax/rcx/r8/r10 and ymm0-15/xmm0-1. All xmm/ymm
;   are caller-saved; no callee-saved register (rbx/rbp/r12-r15) is touched.
;==============================================================================
global asm_memcmp:function
asm_memcmp:
    ; ---- dispatch: n < 32 uses the scalar small paths ------------------
    cmp     rdx, 32                     ; small compare?
    jb      .lt32                       ; yes: dedicated small-size paths
    xor     r8d, r8d                    ; r8 = running offset
    mov     rcx, rdx                    ; rcx = n
    and     rcx, -256                   ; rcx = n rounded down to 256
    test    rcx, rcx                    ; at least one full 256-byte block?
    jz      .tail                       ; no: handle the tail
    ; ---- eight 32-byte vectors from each input per iteration (16 ymm) -----
.loop256:
    vmovdqu ymm0, [rdi+r8]              ; a[  0.. 31]
    vmovdqu ymm1, [rsi+r8]              ; b[  0.. 31]
    vmovdqu ymm2, [rdi+r8+32]           ; a[ 32.. 63]
    vmovdqu ymm3, [rsi+r8+32]           ; b[ 32.. 63]
    vmovdqu ymm4, [rdi+r8+64]           ; a[ 64.. 95]
    vmovdqu ymm5, [rsi+r8+64]           ; b[ 64.. 95]
    vmovdqu ymm6, [rdi+r8+96]           ; a[ 96..127]
    vmovdqu ymm7, [rsi+r8+96]           ; b[ 96..127]
    vmovdqu ymm8, [rdi+r8+128]          ; a[128..159]
    vmovdqu ymm9, [rsi+r8+128]          ; b[128..159]
    vmovdqu ymm10, [rdi+r8+160]         ; a[160..191]
    vmovdqu ymm11, [rsi+r8+160]         ; b[160..191]
    vmovdqu ymm12, [rdi+r8+192]         ; a[192..223]
    vmovdqu ymm13, [rsi+r8+192]         ; b[192..223]
    vmovdqu ymm14, [rdi+r8+224]         ; a[224..255]
    vmovdqu ymm15, [rsi+r8+224]         ; b[224..255]
    vpcmpeqb ymm0, ymm0, ymm1           ; equality masks per 32-byte block
    vpcmpeqb ymm2, ymm2, ymm3           ; compare block  +32 .. +63
    vpcmpeqb ymm4, ymm4, ymm5           ; compare block  +64 .. +95
    vpcmpeqb ymm6, ymm6, ymm7           ; compare block  +96 .. +127
    vpcmpeqb ymm8, ymm8, ymm9           ; compare block +128 .. +159
    vpcmpeqb ymm10, ymm10, ymm11        ; compare block +160 .. +191
    vpcmpeqb ymm12, ymm12, ymm13        ; compare block +192 .. +223
    vpcmpeqb ymm14, ymm14, ymm15        ; compare block +224 .. +255
    vpand   ymm0, ymm0, ymm2            ; fold eight masks into one tree
    vpand   ymm4, ymm4, ymm6            ; fold block 2+3 masks
    vpand   ymm8, ymm8, ymm10           ; fold block 4+5 masks
    vpand   ymm12, ymm12, ymm14         ; fold block 6+7 masks
    vpand   ymm0, ymm0, ymm4            ; fold pairs 0+1 and 2+3
    vpand   ymm8, ymm8, ymm12           ; fold pairs 4+5 and 6+7
    vpand   ymm0, ymm0, ymm8            ; final fold: all eight masks
    vpmovmskb eax, ymm0                 ; one mask for the whole 256 bytes
    cmp     eax, -1                     ; every byte equal in all 256?
    jne     .diff256                    ; no: locate the first difference
    add     r8, 256                     ; advance a whole block
    cmp     r8, rcx                     ; advanced past the last full block?
    jb      .loop256                    ; no: keep comparing
    ; ---- handle the sub-256-byte remainder -----------------------------
.tail:
    cmp     r8, rdx                     ; remainder present?
    jae     .equal                      ; no: everything matched
    mov     r10, rdx                    ; r10 = bytes remaining
    sub     r10, r8                     ; r10 = n - r8
    cmp     r10, 32                     ; at least one full 32-byte block?
    jb      .small_tail                 ; no: use the small comparator
    ; ---- compare one full 32-byte block at a time ----------------------
.tail32:
    vmovdqu ymm0, [rdi+r8]              ; compare one 32-byte block
    vmovdqu ymm1, [rsi+r8]              ; b[0..31] of this block
    vpcmpeqb ymm0, ymm0, ymm1           ; equality mask
    vpmovmskb eax, ymm0                 ; mask bits
    cmp     eax, -1                     ; all 32 bytes equal?
    jne     .diff_one                   ; no: locate the difference
    add     r8, 32                      ; advance
    mov     r10, rdx                    ; r10 = n
    sub     r10, r8                     ; recompute the remainder
    cmp     r10, 32                     ; another full block?
    jae     .tail32                     ; yes: compare it
    ; ---- fewer than 32 bytes left: reuse the small comparator ----------
.small_tail:
    test    r10, r10                    ; nothing left?
    jz      .equal                      ; yes: everything matched
    add     rdi, r8                     ; point at the remaining bytes
    add     rsi, r8                     ; advance source to the remainder
    mov     rdx, r10                    ; count of remaining bytes (< 32)
    jmp     .lt32                       ; reuse the small-size comparator
    ; ---- locate the differing byte within the 256-byte block -----------
.diff256:
    vmovdqu ymm0, [rdi+r8]              ; rescan the eight blocks one at a time
    vmovdqu ymm1, [rsi+r8]              ; b[0..31]
    vpcmpeqb ymm0, ymm0, ymm1           ; equality mask
    vpmovmskb eax, ymm0                 ; mask bits
    cmp     eax, -1                     ; all 32 bytes equal?
    jne     .d_emit                     ; no: emit this block's difference
    add     r8, 32                      ; advance to block 1
    vmovdqu ymm0, [rdi+r8]              ; block 1
    vmovdqu ymm1, [rsi+r8]              ; b of block 1
    vpcmpeqb ymm0, ymm0, ymm1           ; equality mask
    vpmovmskb eax, ymm0                 ; mask bits
    cmp     eax, -1                     ; all 32 equal?
    jne     .d_emit                     ; no: emit
    add     r8, 32                      ; advance to block 2
    vmovdqu ymm0, [rdi+r8]              ; block 2
    vmovdqu ymm1, [rsi+r8]              ; b of block 2
    vpcmpeqb ymm0, ymm0, ymm1           ; equality mask
    vpmovmskb eax, ymm0                 ; mask bits
    cmp     eax, -1                     ; all 32 equal?
    jne     .d_emit                     ; no: emit
    add     r8, 32                      ; advance to block 3
    vmovdqu ymm0, [rdi+r8]              ; block 3
    vmovdqu ymm1, [rsi+r8]              ; b of block 3
    vpcmpeqb ymm0, ymm0, ymm1           ; equality mask
    vpmovmskb eax, ymm0                 ; mask bits
    cmp     eax, -1                     ; all 32 equal?
    jne     .d_emit                     ; no: emit
    add     r8, 32                      ; advance to block 4
    vmovdqu ymm0, [rdi+r8]              ; block 4
    vmovdqu ymm1, [rsi+r8]              ; b of block 4
    vpcmpeqb ymm0, ymm0, ymm1           ; equality mask
    vpmovmskb eax, ymm0                 ; mask bits
    cmp     eax, -1                     ; all 32 equal?
    jne     .d_emit                     ; no: emit
    add     r8, 32                      ; advance to block 5
    vmovdqu ymm0, [rdi+r8]              ; block 5
    vmovdqu ymm1, [rsi+r8]              ; b of block 5
    vpcmpeqb ymm0, ymm0, ymm1           ; equality mask
    vpmovmskb eax, ymm0                 ; mask bits
    cmp     eax, -1                     ; all 32 equal?
    jne     .d_emit                     ; no: emit
    add     r8, 32                      ; advance to block 6
    vmovdqu ymm0, [rdi+r8]              ; block 6
    vmovdqu ymm1, [rsi+r8]              ; b of block 6
    vpcmpeqb ymm0, ymm0, ymm1           ; equality mask
    vpmovmskb eax, ymm0                 ; mask bits
    cmp     eax, -1                     ; all 32 equal?
    jne     .d_emit                     ; no: emit
    add     r8, 32                      ; advance to block 7
    vmovdqu ymm0, [rdi+r8]              ; block 7
    vmovdqu ymm1, [rsi+r8]              ; b of block 7
    vpcmpeqb ymm0, ymm0, ymm1           ; equality mask
    vpmovmskb eax, ymm0                 ; mask bits
    ; ---- compute the signed difference at r8 ---------------------------
.d_emit:
    not     eax                         ; 1 where bytes differ
    tzcnt   eax, eax                    ; index of first differing byte
    add     r8, rax                     ; r8 += index of first differing byte
    movzx   eax, byte [rdi+r8]          ; unsigned comparison of the bytes
    movzx   ecx, byte [rsi+r8]          ; b[...] as unsigned byte
    sub     eax, ecx                    ; eax = a - b (signed result)
    vzeroupper                          ; drop AVX state
    ret                                 ; return the byte difference
    ; ---- same, for a single 32-byte block difference -------------------
.diff_one:
    not     eax                         ; invert mask: 1 where bytes differ
    tzcnt   eax, eax                    ; index of first differing byte
    add     r8, rax                     ; r8 += that index
    movzx   eax, byte [rdi+r8]          ; a[...] as unsigned byte
    movzx   ecx, byte [rsi+r8]          ; b[...] as unsigned byte
    sub     eax, ecx                    ; eax = a - b (signed result)
    vzeroupper                          ; drop AVX state
    ret                                 ; return the byte difference
    ; ---- small sizes (0..31), with no reads beyond the requested range -----
.lt32:
    cmp     rdx, 16                     ; 16..31 bytes?
    jb      .lt16                       ; no: try the 8..15 path
    vmovdqu xmm0, [rdi]                 ; compare the first 16 bytes
    vmovdqu xmm1, [rsi]                 ; b[0..15]
    vpcmpeqb xmm0, xmm0, xmm1           ; equality mask
    vpmovmskb eax, xmm0                 ; mask of 16 bits
    cmp     eax, 0xFFFF                 ; all 16 bytes equal?
    jne     .d16_first                  ; no: first difference is in the head
    mov     r8, rdx                     ; compare the last 16 bytes
    sub     r8, 16                      ; r8 = n-16 (start of last 16)
    vmovdqu xmm0, [rdi+r8]              ; a of last 16 bytes
    vmovdqu xmm1, [rsi+r8]              ; b of last 16 bytes
    vpcmpeqb xmm0, xmm0, xmm1           ; equality mask
    vpmovmskb eax, xmm0                 ; mask of 16 bits
    cmp     eax, 0xFFFF                 ; all equal in the tail?
    je      .equal                      ; yes: whole range equal
    not     eax                         ; first difference within the tail
    tzcnt   eax, eax                    ; index of first differing byte
    add     r8, rax                     ; r8 += that byte index
    jmp     .byte_cmp                   ; compare the differing byte
.d16_first:
    not     eax                         ; first difference within the head
    tzcnt   eax, eax                    ; index of first differing byte
    xor     r8d, r8d                    ; r8 = 0
    add     r8, rax                     ; r8 = index in the head
    jmp     .byte_cmp                   ; compare the differing byte
    ; ---- 8..15 bytes: overlapping 8-byte compares ----------------------
.lt16:
    cmp     rdx, 8                      ; 8..15 bytes?
    jb      .lt8                        ; no: try the 4..7 path
    mov     rax, [rdi]                  ; compare the first 8 bytes
    mov     rcx, [rsi]                  ; b first 8 bytes
    cmp     rax, rcx                    ; first 8 bytes equal?
    jne     .q_first                    ; no: first difference is in the head
    mov     r8, rdx                     ; compare the last 8 bytes
    sub     r8, 8                       ; r8 = n-8 (start of last 8)
    mov     rax, [rdi+r8]               ; a of last 8 bytes
    mov     rcx, [rsi+r8]               ; b of last 8 bytes
    cmp     rax, rcx                    ; last 8 bytes equal?
    je      .equal                      ; yes: whole range equal
    xor     rax, rcx                    ; locate the first differing byte
    tzcnt   rax, rax                    ; index of lowest set bit
    shr     eax, 3                      ; convert bit index to byte index
    add     r8, rax                     ; r8 += that byte index
    jmp     .byte_cmp                   ; compare the differing byte
.q_first:
    xor     rax, rcx                    ; bits where the qwords differ
    tzcnt   rax, rax                    ; index of first differing bit
    shr     eax, 3                      ; convert to a byte index
    xor     r8d, r8d                    ; r8 = 0
    add     r8, rax                     ; r8 = index in the head
    jmp     .byte_cmp                   ; compare the differing byte
    ; ---- 4..7 bytes: overlapping 4-byte compares -----------------------
.lt8:
    cmp     rdx, 4                      ; 4..7 bytes?
    jb      .lt4                        ; no: the 0..3 byte loop
    mov     eax, [rdi]                  ; compare the first 4 bytes
    mov     ecx, [rsi]                  ; b first 4 bytes
    cmp     eax, ecx                    ; first 4 bytes equal?
    jne     .w_first                    ; no: first difference is in the head
    mov     r8, rdx                     ; compare the last 4 bytes
    sub     r8, 4                       ; r8 = n-4 (start of last 4)
    mov     eax, [rdi+r8]               ; a of last 4 bytes
    mov     ecx, [rsi+r8]               ; b of last 4 bytes
    cmp     eax, ecx                    ; last 4 bytes equal?
    je      .equal                      ; yes: whole range equal
    xor     eax, ecx                    ; locate the first differing byte
    tzcnt   eax, eax                    ; index of lowest set bit
    shr     eax, 3                      ; convert bit index to byte index
    add     r8, rax                     ; r8 += that byte index
    jmp     .byte_cmp                   ; compare the differing byte
.w_first:
    xor     eax, ecx                    ; bits where the dwords differ
    tzcnt   eax, eax                    ; index of first differing bit
    shr     eax, 3                      ; convert to a byte index
    xor     r8d, r8d                    ; r8 = 0
    add     r8, rax                     ; r8 = index in the head
    jmp     .byte_cmp                   ; compare the differing byte
    ; ---- 0..3 bytes: plain byte loop -----------------------------------
.lt4:
    xor     r8d, r8d                    ; 0..3 bytes: plain byte loop
    test    rdx, rdx                    ; n == 0?
    jz      .equal                      ; yes: equal
.lt4_loop:
    movzx   eax, byte [rdi+r8]          ; a[r8] as unsigned byte
    movzx   ecx, byte [rsi+r8]          ; b[r8] as unsigned byte
    sub     eax, ecx                    ; eax = a - b
    jnz     .ret_plain                  ; differ: return the difference
    inc     r8                          ; advance one byte
    cmp     r8, rdx                     ; reached n?
    jb      .lt4_loop                   ; no: keep comparing
    jmp     .equal                      ; yes: all equal
    ; ---- unsigned byte comparison at r8 --------------------------------
.byte_cmp:
    movzx   eax, byte [rdi+r8]          ; unsigned comparison of the bytes
    movzx   ecx, byte [rsi+r8]          ; b[r8] as unsigned byte
    sub     eax, ecx                    ; eax = a - b (signed result)
    vzeroupper                          ; drop AVX state
    ret                                 ; return the byte difference
.ret_plain:
    ret                                 ; return the byte difference
    ; ---- all bytes equal -----------------------------------------------
.equal:
    vzeroupper                          ; drop AVX state
    xor     eax, eax                    ; all compared bytes equal
    ret                                 ; return 0

;==============================================================================
; void *asm_memchr(const void *s, int c, size_t n)
;------------------------------------------------------------------------------
; Returns a pointer to the first byte equal to (unsigned char)c within the
; first n bytes, or NULL if there is none.
;
; Parameters (System V AMD64 ABI):
;   rdi = s (const void *)     - buffer start
;   esi = c (int)              - byte value to search for (low 8 bits)
;   rdx = n (size_t)           - number of bytes to scan
; Returns:
;   rax = pointer to the first matching byte, or NULL when none is found
; Uses / clobbers:
;   Reads rdi/rsi/rdx; writes rax/rcx/r8 and xmm0-1/ymm0-1. All xmm/ymm are
;   caller-saved; no callee-saved register (rbx/rbp/r12-r15) is touched.
;==============================================================================
global asm_memchr:function
asm_memchr:
    ; ---- dispatch on n and broadcast the search byte -------------------
    test    rdx, rdx                    ; n == 0?
    jz      .notfound                   ; yes: cannot match
    vmovd   xmm0, esi                   ; move c into an xmm lane
    vpbroadcastb ymm0, xmm0             ; broadcast c across the vector
    xor     r8d, r8d                    ; r8 = running offset
    cmp     rdx, 32                     ; n >= 32?
    jb      .lt32                       ; no: vectorised small-size paths
    mov     rcx, rdx                    ; rcx = n
    sub     rcx, 32                     ; last offset that has 32 valid bytes
    ; ---- scan full 32-byte vectors -------------------------------------
.loop:
    vmovdqu ymm1, [rdi+r8]              ; load 32 candidate bytes
    vpcmpeqb ymm1, ymm1, ymm0           ; compare against c
    vpmovmskb eax, ymm1                 ; match mask
    test    eax, eax                    ; any match?
    jnz     .found                      ; yes: report it
    add     r8, 32                      ; advance a full vector
    cmp     r8, rcx                     ; still a full vector left?
    jbe     .loop                       ; yes: keep going
    ; ---- scalar finish for the final partial vector --------------------
.scalar:
    cmp     r8, rdx                     ; scanned everything?
    jae     .notfound                   ; yes: no match
    movzx   eax, byte [rdi+r8]          ; load candidate byte
    cmp     al, sil                     ; equal to c?
    je      .found_scalar               ; yes: return this address
    inc     r8                          ; advance one byte
    jmp     .scalar                     ; continue
    ; ---- match found in a vector: compute the pointer ------------------
.found:
    tzcnt   eax, eax                    ; index of first match in vector
    add     r8, rax                     ; absolute index
.found_scalar:
    lea     rax, [rdi+r8]               ; compute result pointer
    vzeroupper                          ; drop AVX state
    ret                                 ; return the match pointer
    ; ---- small sizes (0..31): overlapping page-safe vector windows -------
.lt32:
    cmp     rdx, 16                     ; 16..31 bytes?
    jb      .lt16                       ; no: try the 8..15 path
    mov     eax, edi                    ; is a 16-byte load page safe?
    and     eax, PAGE_SIZE-1            ; low bits of the address
    cmp     eax, PAGE_SIZE-16           ; does the window fit in the page?
    ja      .byte0                      ; no: byte scan instead
    vmovdqu xmm1, [rdi]                 ; first 16 bytes
    vpcmpeqb xmm1, xmm1, xmm0           ; compare against c
    vpmovmskb eax, xmm1                 ; match mask
    test    eax, eax                    ; any match?
    jnz     .found_xmm                  ; yes: report the first match
    mov     r8, rdx                     ; last 16 bytes
    sub     r8, 16                      ; r8 = n-16 (start of last 16)
    mov     eax, edi                    ; low 32 bits of the address
    add     eax, r8d                    ; address of the last-16 window
    and     eax, PAGE_SIZE-1            ; offset within the page
    cmp     eax, PAGE_SIZE-16           ; does the window fit in the page?
    ja      .scalar_from_r8             ; no: finish with the byte scan
    vmovdqu xmm1, [rdi+r8]              ; last 16 bytes
    vpcmpeqb xmm1, xmm1, xmm0           ; compare against c
    vpmovmskb eax, xmm1                 ; match mask
    test    eax, eax                    ; any match?
    jz      .notfound                   ; no: no match anywhere
    tzcnt   eax, eax                    ; index of first match
    add     r8, rax                     ; absolute index
    lea     rax, [rdi+r8]               ; compute result pointer
    vzeroupper                          ; drop AVX state
    ret                                 ; return the match pointer
.found_xmm:
    tzcnt   eax, eax                    ; first match within the window
    lea     rax, [rdi+rax]              ; pointer to the match
    vzeroupper                          ; drop AVX state
    ret                                 ; return the match pointer
    ; ---- 8..15 bytes: page-safe 8-byte windows -------------------------
.lt16:
    cmp     rdx, 8                      ; 8..15 bytes?
    jb      .lt8                        ; no: try the 4..7 path
    mov     eax, edi                    ; is an 8-byte load page safe?
    and     eax, PAGE_SIZE-1            ; low bits of the address
    cmp     eax, PAGE_SIZE-8            ; does the window fit in the page?
    ja      .byte0                      ; no: byte scan instead
    vmovq   xmm1, [rdi]                 ; first 8 bytes
    vpcmpeqb xmm1, xmm1, xmm0           ; compare against c
    vpmovmskb eax, xmm1                 ; match mask
    and     eax, 0xFF                   ; only the low 8 lanes are valid
    test    eax, eax                    ; any match?
    jnz     .found_xmm                  ; yes: report the first match
    mov     r8, rdx                     ; last 8 bytes
    sub     r8, 8                       ; r8 = n-8 (start of last 8)
    mov     eax, edi                    ; low 32 bits of the address
    add     eax, r8d                    ; address of the last-8 window
    and     eax, PAGE_SIZE-1            ; offset within the page
    cmp     eax, PAGE_SIZE-8            ; does the window fit in the page?
    ja      .scalar_from_r8             ; no: finish with the byte scan
    vmovq   xmm1, [rdi+r8]              ; last 8 bytes
    vpcmpeqb xmm1, xmm1, xmm0           ; compare against c
    vpmovmskb eax, xmm1                 ; match mask
    and     eax, 0xFF                   ; only the low 8 lanes are valid
    test    eax, eax                    ; any match?
    jz      .notfound                   ; no: no match anywhere
    tzcnt   eax, eax                    ; index of first match
    add     r8, rax                     ; absolute index
    lea     rax, [rdi+r8]               ; compute result pointer
    vzeroupper                          ; drop AVX state
    ret                                 ; return the match pointer
    ; ---- 4..7 bytes: page-safe 4-byte windows --------------------------
.lt8:
    cmp     rdx, 4                      ; 4..7 bytes?
    jb      .byte0                      ; no: 1..3 bytes, byte scan
    mov     eax, edi                    ; is a 4-byte load page safe?
    and     eax, PAGE_SIZE-1            ; low bits of the address
    cmp     eax, PAGE_SIZE-4            ; does the window fit in the page?
    ja      .byte0                      ; no: byte scan instead
    vmovd   xmm1, [rdi]                 ; first 4 bytes
    vpcmpeqb xmm1, xmm1, xmm0           ; compare against c
    vpmovmskb eax, xmm1                 ; match mask
    and     eax, 0xF                    ; only the low 4 lanes are valid
    test    eax, eax                    ; any match?
    jnz     .found_xmm                  ; yes: report the first match
    mov     r8, rdx                     ; last 4 bytes
    sub     r8, 4                       ; r8 = n-4 (start of last 4)
    mov     eax, edi                    ; low 32 bits of the address
    add     eax, r8d                    ; address of the last-4 window
    and     eax, PAGE_SIZE-1            ; offset within the page
    cmp     eax, PAGE_SIZE-4            ; does the window fit in the page?
    ja      .scalar_from_r8             ; no: finish with the byte scan
    vmovd   xmm1, [rdi+r8]              ; last 4 bytes
    vpcmpeqb xmm1, xmm1, xmm0           ; compare against c
    vpmovmskb eax, xmm1                 ; match mask
    and     eax, 0xF                    ; only the low 4 lanes are valid
    test    eax, eax                    ; any match?
    jz      .notfound                   ; no: no match anywhere
    tzcnt   eax, eax                    ; index of first match
    add     r8, rax                     ; absolute index
    lea     rax, [rdi+r8]               ; compute result pointer
    vzeroupper                          ; drop AVX state
    ret                                 ; return the match pointer
    ; ---- byte scan from offset 0 ---------------------------------------
.byte0:
    xor     r8d, r8d                    ; start the byte scan at offset 0
.scalar_from_r8:
    jmp     .scalar                     ; finish with the scalar loop
    ; ---- no match: return NULL -----------------------------------------
.notfound:
    vzeroupper                          ; drop AVX state
    xor     eax, eax                    ; return NULL
    ret                                 ; return NULL

;==============================================================================
; void *asm_memrchr(const void *s, int c, size_t n)
;------------------------------------------------------------------------------
; Returns a pointer to the last byte equal to (unsigned char)c within the
; first n bytes, or NULL if there is none.
;
; Parameters (System V AMD64 ABI):
;   rdi = s (const void *)     - buffer start
;   esi = c (int)              - byte value to search for (low 8 bits)
;   rdx = n (size_t)           - number of bytes to scan
; Returns:
;   rax = pointer to the last matching byte, or NULL when none is found
; Uses / clobbers:
;   Reads rdi/rsi/rdx; writes rax/r8 and xmm0-1/ymm0-1. All xmm/ymm are
;   caller-saved; no callee-saved register (rbx/rbp/r12-r15) is touched.
;==============================================================================
global asm_memrchr:function
asm_memrchr:
    ; ---- dispatch on n and broadcast the search byte -------------------
    test    rdx, rdx                    ; n == 0?
    jz      .notfound                   ; yes: cannot match
    vmovd   xmm0, esi                   ; move c into an xmm lane
    vpbroadcastb ymm0, xmm0             ; broadcast c across the vector
    cmp     rdx, 32                     ; n >= 32?
    jb      .scalar                     ; no: byte scan backwards
    mov     r8, rdx                     ; r8 = current top offset
    ; ---- scan 32-byte blocks from high to low --------------------------
.block:
    cmp     r8, 32                      ; only the bottom block remains?
    jbe     .last                       ; yes: handle [0,32) once
    sub     r8, 32                      ; step one vector down
    vmovdqu ymm1, [rdi+r8]              ; load 32 candidate bytes
    vpcmpeqb ymm1, ymm1, ymm0           ; compare against c
    vpmovmskb eax, ymm1                 ; match mask
    test    eax, eax                    ; any match in this block?
    jnz     .found                      ; yes: it is the highest so far
    jmp     .block                      ; no: continue downward
    ; ---- final bottom block [0,32) -------------------------------------
.last:
    xor     r8d, r8d                    ; bottom block starts at 0
    vmovdqu ymm1, [rdi]                 ; load bytes [0,32)
    vpcmpeqb ymm1, ymm1, ymm0           ; compare against c
    vpmovmskb eax, ymm1                 ; match mask
    test    eax, eax                    ; any match?
    jz      .notfound                   ; no: nothing anywhere
    ; ---- match found: compute the pointer ------------------------------
.found:
    bsr     eax, eax                    ; bit index of the highest match
    add     r8, rax                     ; absolute index
    lea     rax, [rdi+r8]               ; compute result pointer
    vzeroupper                          ; drop AVX state
    ret                                 ; return the match pointer
    ; ---- n < 32: byte scan backwards -----------------------------------
.scalar:
    mov     r8, rdx                     ; start just past the end
    ; ---- byte-wise backward scan ---------------------------------------
.sloop:
    dec     r8                          ; move to the previous byte
    movzx   eax, byte [rdi+r8]          ; load candidate byte
    cmp     al, sil                     ; equal to c?
    je      .found_scalar               ; yes: return this address
    test    r8, r8                      ; reached the first byte?
    jnz     .sloop                      ; no: continue backward
    ; ---- no match: return NULL -----------------------------------------
.notfound:
    xor     eax, eax                    ; return NULL
    ret                                 ; return NULL
    ; ---- scalar match: compute the pointer -----------------------------
.found_scalar:
    lea     rax, [rdi+r8]               ; compute result pointer
    ret                                 ; return the match pointer

GNU_STACK_NOTE                          ; mark stack non-executable
