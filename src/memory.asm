;==============================================================================
; memory.asm - high-performance x86-64 memory primitives (System V AMD64 ABI)
;------------------------------------------------------------------------------
; Implements AVX2-accelerated replacements for the hot libc memory routines:
;
;   void *asm_memcpy (void *dst, const void *src, size_t n);
;   void *asm_memmove(void *dst, const void *src, size_t n);
;   void *asm_memset (void *dst, int c, size_t n);
;   void *asm_bzero  (void *dst, size_t n);
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
;==============================================================================
global asm_memcpy:function
asm_memcpy:
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
.4_7:
    mov     ecx, [rsi]                  ; load first 4 bytes
    mov     r8d, [rsi+rdx-4]            ; load last  4 bytes
    mov     [rdi], ecx                  ; store first 4 bytes
    mov     [rdi+rdx-4], r8d            ; store last  4 bytes
    ret
.8_15:
    mov     rcx, [rsi]                  ; load first 8 bytes
    mov     r8, [rsi+rdx-8]             ; load last  8 bytes
    mov     [rdi], rcx                  ; store first 8 bytes
    mov     [rdi+rdx-8], r8             ; store last  8 bytes
    ret
.16_31:
    vmovdqu xmm0, [rsi]                 ; load first 16 bytes
    vmovdqu xmm1, [rsi+rdx-16]          ; load last  16 bytes
    vmovdqu [rdi], xmm0                 ; store first 16 bytes
    vmovdqu [rdi+rdx-16], xmm1          ; store last  16 bytes
    ret
    ; ---- very large copies: non-temporal stores avoid read-for-ownership ---
.nt_copy:
    test    dil, 31                     ; is the destination 32-byte aligned?
    jnz     .erms_copy                  ; no: fall back to ERMS for this size
    mov     rcx, rdx                    ; rcx = n
    and     rcx, -128                   ; rcx = n rounded down to 128
    xor     r8d, r8d                    ; r8 = running offset
.nt_loop:
    vmovdqu ymm0, [rsi+r8]              ; load source block
    vmovdqu ymm1, [rsi+r8+32]
    vmovdqu ymm2, [rsi+r8+64]
    vmovdqu ymm3, [rsi+r8+96]
    vmovntdq [rdi+r8], ymm0             ; streaming store (no RFO)
    vmovntdq [rdi+r8+32], ymm1
    vmovntdq [rdi+r8+64], ymm2
    vmovntdq [rdi+r8+96], ymm3
    add     r8, 128                     ; advance
    cmp     r8, rcx                     ; all full blocks streamed?
    jb      .nt_loop                    ; no: keep going
    sfence                              ; order the non-temporal stores
    ; Overlapping final 128-byte block with ordinary stores covers the tail.
    vmovdqu ymm0, [rsi+rdx-128]
    vmovdqu ymm1, [rsi+rdx-96]
    vmovdqu ymm2, [rsi+rdx-64]
    vmovdqu ymm3, [rsi+rdx-32]
    vmovdqu [rdi+rdx-128], ymm0
    vmovdqu [rdi+rdx-96], ymm1
    vmovdqu [rdi+rdx-64], ymm2
    vmovdqu [rdi+rdx-32], ymm3
    vzeroupper
    ret
    ; ---- n in [96 KiB, 256 KiB): single rep movsb is fastest on this CPU ----
.erms_copy:
    cld                                 ; rep moves forward (DF clear)
    mov     rcx, rdx                    ; rcx = n
.erms_loop:
    rep     movsb                       ; dst=rdi, src=rsi, count=rcx
    ret
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
    vmovdqu [rdi+r8+32], ymm1
    vmovdqu [rdi+r8+64], ymm2
    vmovdqu [rdi+r8+96], ymm3
    vmovdqu [rdi+r8+128], ymm4
    vmovdqu [rdi+r8+160], ymm5
    vmovdqu [rdi+r8+192], ymm6
    vmovdqu [rdi+r8+224], ymm7
    add     r8, 256                     ; advance to the next block
    cmp     r8, rcx                     ; copied all full blocks?
    jb      .loop256                    ; no: keep going
    cmp     r8, rdx                     ; was n an exact multiple of 256?
    jae     .copy_done                  ; yes: no tail to duplicate
    ; The final 256 bytes are re-copied with an overlapping block. Because
    ; rcx >= n-255, the window [n-256, n) fully covers the [rcx, n) tail.
    vmovdqu ymm0, [rsi+rdx-256]
    vmovdqu ymm1, [rsi+rdx-224]
    vmovdqu ymm2, [rsi+rdx-192]
    vmovdqu ymm3, [rsi+rdx-160]
    vmovdqu ymm4, [rsi+rdx-128]
    vmovdqu ymm5, [rsi+rdx-96]
    vmovdqu ymm6, [rsi+rdx-64]
    vmovdqu ymm7, [rsi+rdx-32]
    vmovdqu [rdi+rdx-256], ymm0
    vmovdqu [rdi+rdx-224], ymm1
    vmovdqu [rdi+rdx-192], ymm2
    vmovdqu [rdi+rdx-160], ymm3
    vmovdqu [rdi+rdx-128], ymm4
    vmovdqu [rdi+rdx-96], ymm5
    vmovdqu [rdi+rdx-64], ymm6
    vmovdqu [rdi+rdx-32], ymm7
.copy_done:
    vzeroupper                          ; drop AVX state, avoid SSE transition hit
    ret
.129_255:
    vmovdqu ymm0, [rsi]                 ; first 128 bytes
    vmovdqu ymm1, [rsi+32]
    vmovdqu ymm2, [rsi+64]
    vmovdqu ymm3, [rsi+96]
    vmovdqu [rdi], ymm0
    vmovdqu [rdi+32], ymm1
    vmovdqu [rdi+64], ymm2
    vmovdqu [rdi+96], ymm3
    vmovdqu ymm0, [rsi+rdx-128]         ; last 128 bytes (overlapping)
    vmovdqu ymm1, [rsi+rdx-96]
    vmovdqu ymm2, [rsi+rdx-64]
    vmovdqu ymm3, [rsi+rdx-32]
    vmovdqu [rdi+rdx-128], ymm0
    vmovdqu [rdi+rdx-96], ymm1
    vmovdqu [rdi+rdx-64], ymm2
    vmovdqu [rdi+rdx-32], ymm3
    vzeroupper
    ret
.32_64:
    vmovdqu ymm0, [rsi]                 ; load first 32 bytes
    vmovdqu ymm1, [rsi+rdx-32]          ; load last  32 bytes
    vmovdqu [rdi], ymm0                 ; store first 32 bytes
    vmovdqu [rdi+rdx-32], ymm1          ; store last  32 bytes
    vzeroupper
    ret
.65_128:
    vmovdqu ymm0, [rsi]                 ; load bytes  +0  .. +31
    vmovdqu ymm1, [rsi+32]              ; load bytes +32  .. +63
    vmovdqu ymm2, [rsi+rdx-64]          ; load bytes n-64 .. n-33
    vmovdqu ymm3, [rsi+rdx-32]          ; load bytes n-32 .. n-1
    vmovdqu [rdi], ymm0                 ; store bytes  +0  .. +31
    vmovdqu [rdi+32], ymm1              ; store bytes +32  .. +63
    vmovdqu [rdi+rdx-64], ymm2          ; store bytes n-64 .. n-33
    vmovdqu [rdi+rdx-32], ymm3          ; store bytes n-32 .. n-1
    vzeroupper
    ret

;==============================================================================
; void *asm_memmove(void *dst, const void *src, size_t n)
;------------------------------------------------------------------------------
; Like memcpy but the buffers may overlap. Chooses the copy direction so that
; a byte is always read before it can be overwritten. Returns dst.
;==============================================================================
global asm_memmove:function
asm_memmove:
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
.back_loop:
    sub     r9, 32                      ; step one vector down
    vmovdqu ymm0, [rsi+r9]              ; load  [r9, r9+32)
    vmovdqu [rdi+r9], ymm0              ; store [r9, r9+32)
    cmp     r9, r8                      ; reached the bottom remainder?
    ja      .back_loop                  ; no: continue downward
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
    ret
.small_back:
    test    rdx, rdx                    ; n == 0?
    jz      .done                       ; yes: nothing to do
    mov     rcx, rdx                    ; rcx = n
.sb_loop:
    dec     rcx                         ; move to next lower byte
    movzx   r9d, byte [rsi+rcx]         ; load source byte
    mov     [rdi+rcx], r9b              ; store to destination
    test    rcx, rcx                    ; reached byte 0?
    jnz     .sb_loop                    ; no: continue
    ret
    ; ---- Overlapping with dst < src: copy strictly from low to high ------
.forward_overlap:
    cmp     rdx, 32                     ; n >= 32?
    jb      .fwd_bytes                  ; no: byte-wise forward copy
    mov     rcx, rdx                    ; rcx = n
    and     rcx, -32                    ; rcx = n rounded down to 32
    xor     r8d, r8d                    ; r8 = running offset
.fwd_loop:
    vmovdqu ymm0, [rsi+r8]              ; load  [r8, r8+32) from source
    vmovdqu [rdi+r8], ymm0              ; store [r8, r8+32) to dest
    add     r8, 32                      ; advance one vector
    cmp     r8, rcx                     ; all full vectors copied?
    jb      .fwd_loop                   ; no: keep going
    vzeroupper
    cmp     r8, rdx                     ; leftover bytes?
    jae     .done                       ; no: done
.fwd_tail:
    movzx   r9d, byte [rsi+r8]          ; load one source byte
    mov     [rdi+r8], r9b               ; store one destination byte
    inc     r8                          ; advance
    cmp     r8, rdx                     ; finished?
    jb      .fwd_tail                   ; no: keep going
    ret
.fwd_bytes:
    xor     r8d, r8d                    ; r8 = 0
    test    rdx, rdx                    ; n == 0?
    jz      .done                       ; yes: nothing to do
.fb_loop:
    movzx   r9d, byte [rsi+r8]          ; load one source byte
    mov     [rdi+r8], r9b               ; store one destination byte
    inc     r8                          ; advance
    cmp     r8, rdx                     ; finished?
    jb      .fb_loop                    ; no: keep going
.done:
    ret

;==============================================================================
; void *asm_memset(void *dst, int c, size_t n)
;------------------------------------------------------------------------------
; Fills n bytes at dst with the low byte of c. Returns dst.
;==============================================================================
global asm_memset:function
asm_memset:
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
.big_set:
    mov     rcx, rdx                    ; rcx = n
    and     rcx, -32                    ; rcx = n rounded down to 32
    xor     r8d, r8d                    ; r8 = running offset
.loop:
    vmovdqu [rdi+r8], ymm0              ; store 32 bytes at offset r8
    add     r8, 32                      ; advance
    cmp     r8, rcx                     ; all full blocks stored?
    jb      .loop                       ; no: keep going
    vmovdqu [rdi+rdx-32], ymm0          ; store the overlapping final 32 bytes
    vzeroupper
    ret
.32_64:
    vmovdqu [rdi], ymm0                 ; store first 32 bytes
    vmovdqu [rdi+rdx-32], ymm0          ; store last  32 bytes
    vzeroupper
    ret
    ; ---- large fills: enhanced REP STOSB (ERMS) is fastest on this CPU ----
.rep_set:
    mov     r8, rax                     ; r8 = dst (the return value)
    mov     rcx, rdx                    ; rcx = n
    movzx   eax, sil                    ; al = fill byte
    rep     stosb                       ; fill [dst, dst+n) with al
    mov     rax, r8                     ; restore the return value
    ret
.lt32:
    cmp     rdx, 16                     ; 16 <= n < 32?
    jb      .lt16                       ; no: try smaller widths
    vmovdqu [rdi], xmm0                 ; store first 16 bytes
    vmovdqu [rdi+rdx-16], xmm0          ; store last  16 bytes
    ret
.lt16:
    cmp     rdx, 8                      ; 8 <= n < 16?
    jb      .lt8                        ; no: try smaller widths
    movzx   ecx, sil                    ; ecx = fill byte
    mov     r9, 0x0101010101010101      ; byte-broadcast multiplier
    imul    r9, rcx                     ; r9 = byte repeated in all 8 bytes
    mov     [rdi], r9                   ; store first 8 bytes
    mov     [rdi+rdx-8], r9             ; store last  8 bytes
    ret
.lt8:
    cmp     rdx, 4                      ; 4 <= n < 8?
    jb      .lt4                        ; no: 1..3 bytes
    movzx   ecx, sil                    ; ecx = fill byte
    imul    ecx, ecx, 0x01010101        ; repeat byte into all 4 bytes
    mov     [rdi], ecx                  ; store first 4 bytes
    mov     [rdi+rdx-4], ecx            ; store last  4 bytes
    ret
.lt4:
    test    rdx, rdx                    ; n == 0?
    jz      .done                       ; yes: nothing to do
    movzx   ecx, sil                    ; ecx = fill byte
    mov     [rdi], cl                   ; store byte 0
    mov     [rdi+rdx-1], cl             ; store byte n-1
    cmp     rdx, 3                      ; exactly three bytes?
    jne     .done                       ; no: 1 or 2 are fully covered
    mov     [rdi+1], cl                 ; store the middle byte
.done:
    ret

;==============================================================================
; void *asm_bzero(void *dst, size_t n)
;------------------------------------------------------------------------------
; Zeroes n bytes at dst. Returns dst. Implemented on top of asm_memset.
;==============================================================================
global asm_bzero:function
asm_bzero:
    mov     rdx, rsi                    ; third arg (n) = old second arg
    xor     esi, esi                    ; fill byte = 0
    jmp     asm_memset                  ; tail-call the shared implementation

;==============================================================================
; int asm_memcmp(const void *a, const void *b, size_t n)
;------------------------------------------------------------------------------
; Compares the first n bytes. Returns <0, 0 or >0 using unsigned byte values.
;==============================================================================
global asm_memcmp:function
asm_memcmp:
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
    vmovdqu ymm2, [rdi+r8+32]
    vmovdqu ymm3, [rsi+r8+32]
    vmovdqu ymm4, [rdi+r8+64]
    vmovdqu ymm5, [rsi+r8+64]
    vmovdqu ymm6, [rdi+r8+96]
    vmovdqu ymm7, [rsi+r8+96]
    vmovdqu ymm8, [rdi+r8+128]
    vmovdqu ymm9, [rsi+r8+128]
    vmovdqu ymm10, [rdi+r8+160]
    vmovdqu ymm11, [rsi+r8+160]
    vmovdqu ymm12, [rdi+r8+192]
    vmovdqu ymm13, [rsi+r8+192]
    vmovdqu ymm14, [rdi+r8+224]
    vmovdqu ymm15, [rsi+r8+224]
    vpcmpeqb ymm0, ymm0, ymm1           ; equality masks per 32-byte block
    vpcmpeqb ymm2, ymm2, ymm3
    vpcmpeqb ymm4, ymm4, ymm5
    vpcmpeqb ymm6, ymm6, ymm7
    vpcmpeqb ymm8, ymm8, ymm9
    vpcmpeqb ymm10, ymm10, ymm11
    vpcmpeqb ymm12, ymm12, ymm13
    vpcmpeqb ymm14, ymm14, ymm15
    vpand   ymm0, ymm0, ymm2            ; fold eight masks into one tree
    vpand   ymm4, ymm4, ymm6
    vpand   ymm8, ymm8, ymm10
    vpand   ymm12, ymm12, ymm14
    vpand   ymm0, ymm0, ymm4
    vpand   ymm8, ymm8, ymm12
    vpand   ymm0, ymm0, ymm8
    vpmovmskb eax, ymm0                 ; one mask for the whole 256 bytes
    cmp     eax, -1                     ; every byte equal in all 256?
    jne     .diff256                    ; no: locate the first difference
    add     r8, 256                     ; advance a whole block
    cmp     r8, rcx
    jb      .loop256
.tail:
    cmp     r8, rdx                     ; remainder present?
    jae     .equal                      ; no: everything matched
    mov     r10, rdx                    ; r10 = bytes remaining
    sub     r10, r8
    cmp     r10, 32                     ; at least one full 32-byte block?
    jb      .small_tail                 ; no: use the small comparator
.tail32:
    vmovdqu ymm0, [rdi+r8]              ; compare one 32-byte block
    vmovdqu ymm1, [rsi+r8]
    vpcmpeqb ymm0, ymm0, ymm1
    vpmovmskb eax, ymm0
    cmp     eax, -1
    jne     .diff_one
    add     r8, 32                      ; advance
    mov     r10, rdx
    sub     r10, r8                     ; recompute the remainder
    cmp     r10, 32
    jae     .tail32
.small_tail:
    test    r10, r10                    ; nothing left?
    jz      .equal                      ; yes: everything matched
    add     rdi, r8                     ; point at the remaining bytes
    add     rsi, r8
    mov     rdx, r10                    ; count of remaining bytes (< 32)
    jmp     .lt32                       ; reuse the small-size comparator
.diff256:
    vmovdqu ymm0, [rdi+r8]              ; rescan the eight blocks one at a time
    vmovdqu ymm1, [rsi+r8]
    vpcmpeqb ymm0, ymm0, ymm1
    vpmovmskb eax, ymm0
    cmp     eax, -1
    jne     .d_emit
    add     r8, 32
    vmovdqu ymm0, [rdi+r8]              ; block 1
    vmovdqu ymm1, [rsi+r8]
    vpcmpeqb ymm0, ymm0, ymm1
    vpmovmskb eax, ymm0
    cmp     eax, -1
    jne     .d_emit
    add     r8, 32
    vmovdqu ymm0, [rdi+r8]              ; block 2
    vmovdqu ymm1, [rsi+r8]
    vpcmpeqb ymm0, ymm0, ymm1
    vpmovmskb eax, ymm0
    cmp     eax, -1
    jne     .d_emit
    add     r8, 32
    vmovdqu ymm0, [rdi+r8]              ; block 3
    vmovdqu ymm1, [rsi+r8]
    vpcmpeqb ymm0, ymm0, ymm1
    vpmovmskb eax, ymm0
    cmp     eax, -1
    jne     .d_emit
    add     r8, 32
    vmovdqu ymm0, [rdi+r8]              ; block 4
    vmovdqu ymm1, [rsi+r8]
    vpcmpeqb ymm0, ymm0, ymm1
    vpmovmskb eax, ymm0
    cmp     eax, -1
    jne     .d_emit
    add     r8, 32
    vmovdqu ymm0, [rdi+r8]              ; block 5
    vmovdqu ymm1, [rsi+r8]
    vpcmpeqb ymm0, ymm0, ymm1
    vpmovmskb eax, ymm0
    cmp     eax, -1
    jne     .d_emit
    add     r8, 32
    vmovdqu ymm0, [rdi+r8]              ; block 6
    vmovdqu ymm1, [rsi+r8]
    vpcmpeqb ymm0, ymm0, ymm1
    vpmovmskb eax, ymm0
    cmp     eax, -1
    jne     .d_emit
    add     r8, 32
    vmovdqu ymm0, [rdi+r8]              ; block 7
    vmovdqu ymm1, [rsi+r8]
    vpcmpeqb ymm0, ymm0, ymm1
    vpmovmskb eax, ymm0
.d_emit:
    not     eax                         ; 1 where bytes differ
    tzcnt   eax, eax                    ; index of first differing byte
    add     r8, rax
    movzx   eax, byte [rdi+r8]          ; unsigned comparison of the bytes
    movzx   ecx, byte [rsi+r8]
    sub     eax, ecx
    vzeroupper
    ret
.diff_one:
    not     eax
    tzcnt   eax, eax
    add     r8, rax
    movzx   eax, byte [rdi+r8]
    movzx   ecx, byte [rsi+r8]
    sub     eax, ecx
    vzeroupper
    ret
    ; ---- small sizes (0..31), with no reads beyond the requested range -----
.lt32:
    cmp     rdx, 16                     ; 16..31 bytes?
    jb      .lt16
    vmovdqu xmm0, [rdi]                 ; compare the first 16 bytes
    vmovdqu xmm1, [rsi]
    vpcmpeqb xmm0, xmm0, xmm1
    vpmovmskb eax, xmm0
    cmp     eax, 0xFFFF
    jne     .d16_first
    mov     r8, rdx                     ; compare the last 16 bytes
    sub     r8, 16
    vmovdqu xmm0, [rdi+r8]
    vmovdqu xmm1, [rsi+r8]
    vpcmpeqb xmm0, xmm0, xmm1
    vpmovmskb eax, xmm0
    cmp     eax, 0xFFFF
    je      .equal
    not     eax                         ; first difference within the tail
    tzcnt   eax, eax
    add     r8, rax
    jmp     .byte_cmp
.d16_first:
    not     eax                         ; first difference within the head
    tzcnt   eax, eax
    xor     r8d, r8d
    add     r8, rax
    jmp     .byte_cmp
.lt16:
    cmp     rdx, 8                      ; 8..15 bytes?
    jb      .lt8
    mov     rax, [rdi]                  ; compare the first 8 bytes
    mov     rcx, [rsi]
    cmp     rax, rcx
    jne     .q_first
    mov     r8, rdx                     ; compare the last 8 bytes
    sub     r8, 8
    mov     rax, [rdi+r8]
    mov     rcx, [rsi+r8]
    cmp     rax, rcx
    je      .equal
    xor     rax, rcx                    ; locate the first differing byte
    tzcnt   rax, rax
    shr     eax, 3
    add     r8, rax
    jmp     .byte_cmp
.q_first:
    xor     rax, rcx
    tzcnt   rax, rax
    shr     eax, 3
    xor     r8d, r8d
    add     r8, rax
    jmp     .byte_cmp
.lt8:
    cmp     rdx, 4                      ; 4..7 bytes?
    jb      .lt4
    mov     eax, [rdi]                  ; compare the first 4 bytes
    mov     ecx, [rsi]
    cmp     eax, ecx
    jne     .w_first
    mov     r8, rdx                     ; compare the last 4 bytes
    sub     r8, 4
    mov     eax, [rdi+r8]
    mov     ecx, [rsi+r8]
    cmp     eax, ecx
    je      .equal
    xor     eax, ecx                    ; locate the first differing byte
    tzcnt   eax, eax
    shr     eax, 3
    add     r8, rax
    jmp     .byte_cmp
.w_first:
    xor     eax, ecx
    tzcnt   eax, eax
    shr     eax, 3
    xor     r8d, r8d
    add     r8, rax
    jmp     .byte_cmp
.lt4:
    xor     r8d, r8d                    ; 0..3 bytes: plain byte loop
    test    rdx, rdx
    jz      .equal
.lt4_loop:
    movzx   eax, byte [rdi+r8]
    movzx   ecx, byte [rsi+r8]
    sub     eax, ecx
    jnz     .ret_plain
    inc     r8
    cmp     r8, rdx
    jb      .lt4_loop
    jmp     .equal
.byte_cmp:
    movzx   eax, byte [rdi+r8]          ; unsigned comparison of the bytes
    movzx   ecx, byte [rsi+r8]
    sub     eax, ecx
    vzeroupper
    ret
.ret_plain:
    ret
.equal:
    vzeroupper
    xor     eax, eax                    ; all compared bytes equal
    ret

;==============================================================================
; void *asm_memchr(const void *s, int c, size_t n)
;------------------------------------------------------------------------------
; Returns a pointer to the first byte equal to (unsigned char)c within the
; first n bytes, or NULL if there is none.
;==============================================================================
global asm_memchr:function
asm_memchr:
    test    rdx, rdx                    ; n == 0?
    jz      .notfound                   ; yes: cannot match
    vmovd   xmm0, esi                   ; move c into an xmm lane
    vpbroadcastb ymm0, xmm0             ; broadcast c across the vector
    xor     r8d, r8d                    ; r8 = running offset
    cmp     rdx, 32                     ; n >= 32?
    jb      .lt32                       ; no: vectorised small-size paths
    mov     rcx, rdx                    ; rcx = n
    sub     rcx, 32                     ; last offset that has 32 valid bytes
.loop:
    vmovdqu ymm1, [rdi+r8]              ; load 32 candidate bytes
    vpcmpeqb ymm1, ymm1, ymm0           ; compare against c
    vpmovmskb eax, ymm1                 ; match mask
    test    eax, eax                    ; any match?
    jnz     .found                      ; yes: report it
    add     r8, 32                      ; advance a full vector
    cmp     r8, rcx                     ; still a full vector left?
    jbe     .loop                       ; yes: keep going
.scalar:
    cmp     r8, rdx                     ; scanned everything?
    jae     .notfound                   ; yes: no match
    movzx   eax, byte [rdi+r8]          ; load candidate byte
    cmp     al, sil                     ; equal to c?
    je      .found_scalar               ; yes: return this address
    inc     r8                          ; advance one byte
    jmp     .scalar                     ; continue
.found:
    tzcnt   eax, eax                    ; index of first match in vector
    add     r8, rax                     ; absolute index
.found_scalar:
    lea     rax, [rdi+r8]               ; compute result pointer
    vzeroupper
    ret
    ; ---- small sizes (0..31): overlapping page-safe vector windows -------
.lt32:
    cmp     rdx, 16                     ; 16..31 bytes?
    jb      .lt16
    mov     eax, edi                    ; is a 16-byte load page safe?
    and     eax, PAGE_SIZE-1
    cmp     eax, PAGE_SIZE-16
    ja      .byte0                      ; no: byte scan instead
    vmovdqu xmm1, [rdi]                 ; first 16 bytes
    vpcmpeqb xmm1, xmm1, xmm0
    vpmovmskb eax, xmm1
    test    eax, eax
    jnz     .found_xmm
    mov     r8, rdx                     ; last 16 bytes
    sub     r8, 16
    mov     eax, edi
    add     eax, r8d
    and     eax, PAGE_SIZE-1
    cmp     eax, PAGE_SIZE-16
    ja      .scalar_from_r8
    vmovdqu xmm1, [rdi+r8]
    vpcmpeqb xmm1, xmm1, xmm0
    vpmovmskb eax, xmm1
    test    eax, eax
    jz      .notfound
    tzcnt   eax, eax
    add     r8, rax
    lea     rax, [rdi+r8]
    vzeroupper
    ret
.found_xmm:
    tzcnt   eax, eax                    ; first match within the window
    lea     rax, [rdi+rax]
    vzeroupper
    ret
.lt16:
    cmp     rdx, 8                      ; 8..15 bytes?
    jb      .lt8
    mov     eax, edi                    ; is an 8-byte load page safe?
    and     eax, PAGE_SIZE-1
    cmp     eax, PAGE_SIZE-8
    ja      .byte0
    vmovq   xmm1, [rdi]                 ; first 8 bytes
    vpcmpeqb xmm1, xmm1, xmm0
    vpmovmskb eax, xmm1
    and     eax, 0xFF                   ; only the low 8 lanes are valid
    test    eax, eax
    jnz     .found_xmm
    mov     r8, rdx                     ; last 8 bytes
    sub     r8, 8
    mov     eax, edi
    add     eax, r8d
    and     eax, PAGE_SIZE-1
    cmp     eax, PAGE_SIZE-8
    ja      .scalar_from_r8
    vmovq   xmm1, [rdi+r8]
    vpcmpeqb xmm1, xmm1, xmm0
    vpmovmskb eax, xmm1
    and     eax, 0xFF
    test    eax, eax
    jz      .notfound
    tzcnt   eax, eax
    add     r8, rax
    lea     rax, [rdi+r8]
    vzeroupper
    ret
.lt8:
    cmp     rdx, 4                      ; 4..7 bytes?
    jb      .byte0
    mov     eax, edi                    ; is a 4-byte load page safe?
    and     eax, PAGE_SIZE-1
    cmp     eax, PAGE_SIZE-4
    ja      .byte0
    vmovd   xmm1, [rdi]                 ; first 4 bytes
    vpcmpeqb xmm1, xmm1, xmm0
    vpmovmskb eax, xmm1
    and     eax, 0xF                    ; only the low 4 lanes are valid
    test    eax, eax
    jnz     .found_xmm
    mov     r8, rdx                     ; last 4 bytes
    sub     r8, 4
    mov     eax, edi
    add     eax, r8d
    and     eax, PAGE_SIZE-1
    cmp     eax, PAGE_SIZE-4
    ja      .scalar_from_r8
    vmovd   xmm1, [rdi+r8]
    vpcmpeqb xmm1, xmm1, xmm0
    vpmovmskb eax, xmm1
    and     eax, 0xF
    test    eax, eax
    jz      .notfound
    tzcnt   eax, eax
    add     r8, rax
    lea     rax, [rdi+r8]
    vzeroupper
    ret
.byte0:
    xor     r8d, r8d                    ; start the byte scan at offset 0
.scalar_from_r8:
    jmp     .scalar                     ; finish with the scalar loop
.notfound:
    vzeroupper
    xor     eax, eax                    ; return NULL
    ret

;==============================================================================
; void *asm_memrchr(const void *s, int c, size_t n)
;------------------------------------------------------------------------------
; Returns a pointer to the last byte equal to (unsigned char)c within the
; first n bytes, or NULL if there is none.
;==============================================================================
global asm_memrchr:function
asm_memrchr:
    test    rdx, rdx                    ; n == 0?
    jz      .notfound                   ; yes: cannot match
    vmovd   xmm0, esi                   ; move c into an xmm lane
    vpbroadcastb ymm0, xmm0             ; broadcast c across the vector
    cmp     rdx, 32                     ; n >= 32?
    jb      .scalar                     ; no: byte scan backwards
    mov     r8, rdx                     ; r8 = current top offset
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
.last:
    xor     r8d, r8d                    ; bottom block starts at 0
    vmovdqu ymm1, [rdi]                 ; load bytes [0,32)
    vpcmpeqb ymm1, ymm1, ymm0           ; compare against c
    vpmovmskb eax, ymm1                 ; match mask
    test    eax, eax                    ; any match?
    jz      .notfound                   ; no: nothing anywhere
.found:
    bsr     eax, eax                    ; bit index of the highest match
    add     r8, rax                     ; absolute index
    lea     rax, [rdi+r8]               ; compute result pointer
    vzeroupper
    ret
.scalar:
    mov     r8, rdx                     ; start just past the end
.sloop:
    dec     r8                          ; move to the previous byte
    movzx   eax, byte [rdi+r8]          ; load candidate byte
    cmp     al, sil                     ; equal to c?
    je      .found_scalar               ; yes: return this address
    test    r8, r8                      ; reached the first byte?
    jnz     .sloop                      ; no: continue backward
.notfound:
    xor     eax, eax                    ; return NULL
    ret
.found_scalar:
    lea     rax, [rdi+r8]               ; compute result pointer
    ret

GNU_STACK_NOTE                          ; mark stack non-executable
