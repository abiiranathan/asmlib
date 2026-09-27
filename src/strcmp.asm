;==============================================================================
; strcmp.asm - high-performance string comparison (System V AMD64 ABI)
;------------------------------------------------------------------------------
; Implements:
;   int asm_strcmp    (const char *a, const char *b);
;   int asm_strncmp   (const char *a, const char *b, size_t n);
;   int asm_strcasecmp (const char *a, const char *b);
;   int asm_strncasecmp(const char *a, const char *b, size_t n);
;
; strcmp/strncmp use SWAR (SIMD-within-a-register) processing of 64 bits at a
; time: a zero-byte detector finds NUL terminators without a byte loop, and
; tzcnt locates the first differing byte. Before every 8-byte read the routine
; checks that both pointers sit at least 8 bytes below a page boundary, so the
; widening load can never touch an unmapped page.
;
; strcasecmp/strncasecmp fold ASCII letters with a branchless sequence and
; then compare bytes; behaviour matches the C/POSIX locale.
;==============================================================================

BITS 64
default rel

%include "common.inc"

;==============================================================================
; ASM_FOLD_LOWER %1 - branchless ASCII lower-casing of a 32-bit register
;------------------------------------------------------------------------------
; Purpose: fold ASCII 'A'..'Z' to 'a'..'z' in place and leave every other
; byte unchanged. Used by the scalar paths of the case-insensitive compares.
;
; Parameters:
;   %1 = 32-bit general-purpose register to fold (read and rewritten in place)
;
; Registers / side effects:
;   Reads and rewrites %1, clobbers r8d as scratch, and leaves the flags set
;   by the final or. %1 must not be edx: the callers keep a byte budget in rdx
;   that must survive the fold.
;==============================================================================
%macro ASM_FOLD_LOWER 1
    lea     r8d, [%1 - 'A']             ; distance above 'A' (wraps if below)
    cmp     r8d, 'Z' - 'A'              ; within the uppercase range?
    setbe   r8b                         ; r8b = 1 if uppercase, else 0
    movzx   r8d, r8b                    ; r8d = 0 or 1
    shl     r8d, 5                      ; r8d = 0 or 32
    or      %1, r8d                     ; set the lower-case bit if uppercase
%endmacro

;==============================================================================
; ASM_FOLD_LOWER_YMM %1, %2, %3 - vector ASCII lower-casing of a ymm register
;------------------------------------------------------------------------------
; Purpose: fold ASCII 'A'..'Z' to 'a'..'z' across all 32 bytes of a vector in
; place and leave every other byte unchanged. Used by the case-insensitive
; vector loops.
;
; Parameters:
;   %1 = data ymm register to fold (read and rewritten in place)
;   %2 = scratch ymm register (holds c - 'A')
;   %3 = scratch ymm register (holds the 0x20 upper-case mask)
;
; Registers / side effects:
;   Rewrites %1/%2/%3 and reads the constants ymm14, ymm15 and ymm13, which
;   must already hold ymm14 = 'A' (0x41), ymm15 = 25 and ymm13 = 0x20. No GPR
;   is touched and no flags are modified. %1 must differ from %2 and %3.
;==============================================================================
%macro ASM_FOLD_LOWER_YMM 3
    vpsubb  %2, %1, ymm14               ; t = c - 'A' (wraps for c < 'A')
    vpminub %3, %2, ymm15               ; u = min(t, 25)
    vpcmpeqb %3, %3, %2                 ; 0xFF where t <= 25 (upper case)
    vpand   %3, %3, ymm13               ; mask = 0x20 where upper case
    vpor    %1, %1, %3                  ; set the lower-case bit
%endmacro

section .text

;==============================================================================
; int asm_strcmp(const char *a, const char *b)
;------------------------------------------------------------------------------
; Returns 0 if equal, otherwise the sign of the first differing byte pair.
; Bytes are compared in 32-byte AVX2 windows that are guaranteed to stay
; inside the current page; the tail near a page end is stepped bytewise.
;
; Parameters (System V AMD64 ABI):
;   rdi = a (const char *)     - first NUL-terminated string
;   rsi = b (const char *)     - second NUL-terminated string
; Returns:
;   eax = signed difference (unsigned a[i] - unsigned b[i]) of the first
;         differing byte pair, or 0 when the strings are equal
; Uses / clobbers:
;   Reads rdi/rsi; writes rax/rcx/rdx/r9 and ymm0-3, with ymm12 held as a
;   zero constant. All xmm/ymm are caller-saved; no callee-saved register
;   (rbx/rbp/r12-r15) is touched. Makes no calls.
;==============================================================================
global asm_strcmp:function
asm_strcmp:
    ; ---- prologue: zero constant for NUL detection -------------------
    vpxor   ymm12, ymm12, ymm12         ; ymm12 = zero (NUL detection)
    ; ---- page-window: min bytes from a and b to their page ends --------
.loop:
    ; ---- how many full vectors can both pointers still read in-page?
    mov     eax, edi                    ; eax = low 32 bits of a
    and     eax, PAGE_SIZE-1            ; eax = offset of the pointer within its page
    mov     ecx, PAGE_SIZE              ; ecx = size of one page in bytes
    sub     ecx, eax                    ; ecx = a's remaining page bytes
    mov     eax, esi                    ; eax = low 32 bits of b
    and     eax, PAGE_SIZE-1            ; eax = offset of the pointer within its page
    mov     r9d, PAGE_SIZE              ; r9d = size of one page in bytes
    sub     r9d, eax                    ; r9d = b's remaining page bytes
    cmp     ecx, r9d                    ; compare the two page windows
    cmova   ecx, r9d                    ; ecx = min of the two
    cmp     ecx, 32                     ; at least one full vector safe?
    jb      .byte                       ; < 32 safe bytes: scalar step
    shr     ecx, 5                      ; ecx = number of safe vectors
    ; ---- main 32-byte compare loop (page-safe window) ----------------
.inner:
    vmovdqu ymm0, [rdi]                 ; 32 bytes of a
    vmovdqu ymm1, [rsi]                 ; 32 bytes of b
    vpcmpeqb ymm2, ymm0, ymm1           ; per-byte equality
    vpmovmskb eax, ymm2                 ; equality mask, one bit per byte
    cmp     eax, -1                     ; all 32 bytes equal?
    jne     .diff                       ; no: locate the first difference
    vpcmpeqb ymm3, ymm0, ymm12          ; NUL bytes in a (and b)
    vpmovmskb r9d, ymm3                 ; NUL mask for this vector
    test    r9d, r9d                    ; any NUL byte present?
    jnz     .equal                      ; both strings end here
    add     rdi, 32                     ; advance a past this vector
    add     rsi, 32                     ; advance b past this vector
    dec     ecx                         ; one fewer safe vector
    jnz     .inner                      ; more safe vectors: keep comparing
    jmp     .loop                       ; recompute the page window
    ; ---- first mismatch: locate it, unless a NUL comes first --------
.diff:
    not     eax                         ; positions that differ
    tzcnt   eax, eax                    ; byte index of the first difference
    vpcmpeqb ymm3, ymm0, ymm12          ; NUL positions in a
    vpmovmskb ecx, ymm3                 ; NUL mask
    test    ecx, ecx                    ; any NUL in this vector?
    jz      .emit                       ; no NUL before the difference
    tzcnt   ecx, ecx                    ; index of the first set bit
    cmp     ecx, eax                    ; NUL earlier than the difference?
    jb      .equal                      ; yes: strings were equal
    ; ---- emit the scalar byte difference -----------------------------
.emit:
    movzx   ecx, byte [rdi+rax]         ; first differing bytes
    movzx   edx, byte [rsi+rax]         ; b's byte at the difference
    mov     eax, ecx                    ; eax = a's byte
    sub     eax, edx                    ; eax = a - b (signed result)
    vzeroupper                          ; drop AVX state
    ret                                 ; return eax
    ; ---- all compared bytes equal: return 0 -------------------------
.equal:
    vzeroupper                          ; drop AVX state
    xor     eax, eax                    ; eax = 0
    ret                                 ; return eax
    ; ---- bytewise step through a page-edge / sub-vector tail --------
.byte:
    movzx   eax, byte [rdi]             ; scalar step near a page end
    movzx   ecx, byte [rsi]             ; b's byte
    sub     eax, ecx                    ; eax = a - b
    jnz     .byte_ret                   ; differ: return the difference
    test    cl, cl                      ; both NUL?
    jz      .byte_eq                    ; yes: strings are equal
    inc     rdi                         ; advance a one byte
    inc     rsi                         ; advance b one byte
    jmp     .loop                       ; recheck the page window
    ; ---- both bytes were NUL: strings are equal ---------------------
.byte_eq:
    xor     eax, eax                    ; eax = 0
    ; ---- common scalar return ---------------------------------------
.byte_ret:
    vzeroupper                          ; drop AVX state
    ret                                 ; return eax

;==============================================================================
; int asm_strncmp(const char *a, const char *b, size_t n)
;------------------------------------------------------------------------------
; Compares at most n bytes. Returns 0 if the first n bytes are equal. The
; inner loop runs min(page-safe vectors, remaining vectors) at a time.
;
; Parameters (System V AMD64 ABI):
;   rdi = a (const char *)     - first string
;   rsi = b (const char *)     - second string
;   rdx = n (size_t)           - maximum number of bytes to compare
; Returns:
;   eax = signed difference (unsigned a[i] - unsigned b[i]) of the first
;         differing byte pair within n bytes, or 0 when equal
; Uses / clobbers:
;   Reads rdi/rsi/rdx; writes rax/rcx/rdx/r9/r10 and ymm0-3, with ymm12 held
;   as a zero constant. No callee-saved register (rbx/rbp/r12-r15) is
;   touched. Makes no calls.
;==============================================================================
global asm_strncmp:function
asm_strncmp:
    ; ---- prologue: zero constant for NUL detection -------------------
    vpxor   ymm12, ymm12, ymm12         ; ymm12 = zero (NUL detection)
    ; ---- page-window: min(page bytes, remaining budget) -------------
.loop:
    cmp     rdx, 32                     ; at least a full vector of budget?
    jb      .bytes                      ; no: scalar loop
    mov     eax, edi                    ; eax = low 32 bits of a
    and     eax, PAGE_SIZE-1            ; eax = offset of the pointer within its page
    mov     ecx, PAGE_SIZE              ; ecx = size of one page in bytes
    sub     ecx, eax                    ; a's page window
    mov     eax, esi                    ; eax = low 32 bits of b
    and     eax, PAGE_SIZE-1            ; eax = offset of the pointer within its page
    mov     r9d, PAGE_SIZE              ; r9d = size of one page in bytes
    sub     r9d, eax                    ; b's page window
    cmp     ecx, r9d                    ; compare the two page windows
    cmova   ecx, r9d                    ; ecx = min page window
    cmp     ecx, 32                     ; at least one full vector safe?
    jb      .bytes                      ; no: scalar loop
    mov     r9, rdx                     ; ctx = budget vectors
    shr     r9, 5                       ; r9 = budget vectors
    cmp     ecx, r9d                    ; compare the two page windows
    cmova   ecx, r9d                    ; ecx = min(page vectors, budget vectors)
    mov     r10d, ecx                   ; remember the count for the budget
    ; ---- main 32-byte compare loop (page-safe window) ----------------
.inner:
    vmovdqu ymm0, [rdi]                 ; load 32 bytes of a
    vmovdqu ymm1, [rsi]                 ; load 32 bytes of b
    vpcmpeqb ymm2, ymm0, ymm1           ; per-byte equality
    vpmovmskb eax, ymm2                 ; equality mask, one bit per byte
    cmp     eax, -1                     ; all 32 bytes equal?
    jne     .diff                       ; no: locate the first difference
    vpcmpeqb ymm3, ymm0, ymm12          ; NUL bytes in a
    vpmovmskb r9d, ymm3                 ; NUL mask for this vector
    test    r9d, r9d                    ; any NUL byte present?
    jnz     .equal                      ; NUL reached before the budget
    add     rdi, 32                     ; advance a past this vector
    add     rsi, 32                     ; advance b past this vector
    dec     ecx                         ; one fewer safe vector
    jnz     .inner                      ; more safe vectors: keep comparing
    shl     r10, 5                      ; bytes compared by the inner loop
    sub     rdx, r10                    ; consume the budget
    jnz     .loop                       ; nonzero: keep comparing
    jmp     .equal                      ; budget exhausted: equal
    ; ---- first mismatch: locate it, unless a NUL comes first --------
.diff:
    not     eax                         ; invert the mask: 1 where bytes differ
    tzcnt   eax, eax                    ; byte index of the first difference
    vpcmpeqb ymm3, ymm0, ymm12          ; NUL bytes in a
    vpmovmskb ecx, ymm3                 ; NUL mask
    test    ecx, ecx                    ; any NUL in this vector?
    jz      .emit                       ; no NUL before the difference
    tzcnt   ecx, ecx                    ; index of the first set bit
    cmp     ecx, eax                    ; NUL earlier than the difference?
    jb      .equal                      ; yes: strings were equal
    ; ---- emit the scalar byte difference -----------------------------
.emit:
    movzx   ecx, byte [rdi+rax]         ; first differing byte of a
    movzx   edx, byte [rsi+rax]         ; b's byte at the difference
    mov     eax, ecx                    ; eax = a's byte
    sub     eax, edx                    ; eax = a - b (signed result)
    vzeroupper                          ; drop AVX state
    ret                                 ; return eax
    ; ---- equal: return 0 --------------------------------------------
.equal:
    vzeroupper                          ; drop AVX state
    xor     eax, eax                    ; eax = 0
    ret                                 ; return eax
    ; ---- fewer than 32 budget bytes: scalar loop --------------------
.bytes:
    test    rdx, rdx                    ; no bytes left?
    jz      .equal                      ; yes: equal
    ; ---- bytewise budget loop ---------------------------------------
.byte_loop:
    movzx   eax, byte [rdi]             ; scalar step: a's byte
    movzx   ecx, byte [rsi]             ; b's byte
    sub     eax, ecx                    ; eax = a - b
    jnz     .byte_ret                   ; differ: return the difference
    test    cl, cl                      ; NUL byte?
    jz      .equal                      ; yes: equal
    inc     rdi                         ; advance a one byte
    inc     rsi                         ; advance b one byte
    dec     rdx                         ; consume one budget byte
    jnz     .byte_loop                  ; more budget: keep comparing
    jmp     .equal                      ; budget exhausted: equal
    ; ---- return the scalar difference -------------------------------
.byte_ret:
    ret                                 ; return eax

;==============================================================================
; int asm_strcasecmp(const char *a, const char *b)
;------------------------------------------------------------------------------
; Case-insensitive (C/POSIX locale) comparison of two NUL-terminated strings.
; Uses 32-byte AVX2 folding so long strings are handled 32 bytes per step.
;
; Parameters (System V AMD64 ABI):
;   rdi = a (const char *)     - first NUL-terminated string
;   rsi = b (const char *)     - second NUL-terminated string
; Returns:
;   eax = signed difference of the first differing byte pair after folding
;         ASCII 'A'..'Z' to lower case, or 0 when the strings are equal
; Uses / clobbers:
;   Reads rdi/rsi; writes rax/rcx/rdx/r8/r9 and ymm0-7, plus ymm12-15 (the
;   zero constant and the fold constants). No callee-saved register is
;   touched. Makes no calls.
;==============================================================================
global asm_strcasecmp:function
asm_strcasecmp:
    ; ---- prologue: broadcast the fold constants into ymm13-15 --------
    mov     eax, 0x41414141             ; 'A' broadcast constant
    vmovd   xmm14, eax                  ; xmm14 = 'A' constant
    vpbroadcastb ymm14, xmm14           ; ymm14 = 'A' in all 32 bytes
    mov     eax, 0x19191919             ; 25 broadcast constant
    vmovd   xmm15, eax                  ; xmm15 = 25 constant
    vpbroadcastb ymm15, xmm15           ; ymm15 = 25 in all 32 bytes
    mov     eax, 0x20202020             ; 0x20 broadcast constant
    vmovd   xmm13, eax                  ; xmm13 = 0x20 constant
    vpbroadcastb ymm13, xmm13           ; ymm13 = 0x20 in all 32 bytes
    vpxor   ymm12, ymm12, ymm12         ; zero constant
    ; ---- page-window: min bytes from a and b to their page ends --------
.loop:
    mov     eax, edi                    ; bytes from a to its page end
    and     eax, PAGE_SIZE-1            ; eax = offset of the pointer within its page
    mov     ecx, PAGE_SIZE              ; ecx = size of one page in bytes
    sub     ecx, eax                    ; ecx = bytes from a to its page end
    mov     eax, esi                    ; bytes from b to its page end
    and     eax, PAGE_SIZE-1            ; eax = offset of the pointer within its page
    mov     r9d, PAGE_SIZE              ; r9d = size of one page in bytes
    sub     r9d, eax                    ; r9d = bytes from b to its page end
    cmp     ecx, r9d                    ; ecx = min bytes safely readable
    cmova   ecx, r9d                    ; ecx = min of the two
    cmp     ecx, 32                     ; at least one full vector safe?
    jb      .byte                       ; fewer than 32 safe bytes: scalar step
    shr     ecx, 5                      ; number of safe 32-byte iterations
    ; ---- main 32-byte folded compare loop -----------------------------
.inner:
    vmovdqu ymm0, [rdi]                 ; load 32 bytes of a
    vmovdqu ymm1, [rsi]                 ; load 32 bytes of b
    ASM_FOLD_LOWER_YMM ymm0, ymm2, ymm3 ; lower-case a
    ASM_FOLD_LOWER_YMM ymm1, ymm4, ymm5 ; lower-case b
    vpcmpeqb ymm6, ymm0, ymm1           ; per-byte equality
    vpmovmskb eax, ymm6                 ; equality mask
    cmp     eax, -1                     ; all 32 folded bytes equal?
    jne     .diff                       ; no: locate the difference
    vpcmpeqb ymm7, ymm0, ymm12          ; NUL bytes in a (folded keeps NUL)
    vpmovmskb r9d, ymm7                 ; NUL mask
    test    r9d, r9d                    ; any NUL byte present?
    jnz     .equal                      ; both ended together
    add     rdi, 32                     ; advance
    add     rsi, 32                     ; advance b past this vector
    dec     ecx                         ; one fewer safe iteration
    jnz     .inner                      ; more safe vectors: keep comparing
    jmp     .loop                       ; recompute the page-safe window
    ; ---- first mismatch: locate it, unless a NUL comes first --------
.diff:
    not     eax                         ; positions that differ
    tzcnt   eax, eax                    ; first differing bit
    vpcmpeqb ymm7, ymm0, ymm12          ; is there a NUL before the difference?
    vpmovmskb ecx, ymm7                 ; NUL mask
    test    ecx, ecx                    ; any NUL in this vector?
    jz      .emit                       ; no NUL before the difference
    tzcnt   ecx, ecx                    ; index of the first set bit
    cmp     ecx, eax                    ; NUL earlier than the difference?
    jb      .equal                      ; NUL earlier: strings were equal
    ; ---- emit the scalar folded difference --------------------------
.emit:
    movzx   ecx, byte [rdi+rax]         ; folded scalar comparison
    movzx   edx, byte [rsi+rax]         ; b's byte at the difference
    ASM_FOLD_LOWER ecx                  ; lower-case ecx
    ASM_FOLD_LOWER edx                  ; lower-case edx
    mov     eax, ecx                    ; eax = a's byte
    sub     eax, edx                    ; eax = a - b (signed result)
    vzeroupper                          ; drop AVX state
    ret                                 ; return eax
    ; ---- equal: return 0 --------------------------------------------
.equal:
    vzeroupper                          ; drop AVX state
    xor     eax, eax                    ; eax = 0
    ret                                 ; return eax
    ; ---- bytewise step through a page-edge / sub-vector tail --------
.byte:
    movzx   eax, byte [rdi]             ; scalar step (page boundary / tail)
    movzx   ecx, byte [rsi]             ; b's byte
    ASM_FOLD_LOWER eax                  ; lower-case eax
    ASM_FOLD_LOWER ecx                  ; lower-case ecx
    sub     eax, ecx                    ; eax = a - b
    jnz     .byte_ret                   ; differ: return the difference
    test    ecx, ecx                    ; both folded to NUL?
    jz      .byte_eq                    ; yes: strings are equal
    inc     rdi                         ; advance a one byte
    inc     rsi                         ; advance b one byte
    jmp     .loop                       ; recheck the page window
    ; ---- both bytes were NUL: strings are equal ---------------------
.byte_eq:
    xor     eax, eax                    ; eax = 0
    ; ---- common scalar return ---------------------------------------
.byte_ret:
    vzeroupper                          ; drop AVX state
    ret                                 ; return eax

;==============================================================================
; int asm_strncasecmp(const char *a, const char *b, size_t n)
;------------------------------------------------------------------------------
; Case-insensitive comparison of at most n bytes, 32 bytes per vector step.
;
; Parameters (System V AMD64 ABI):
;   rdi = a (const char *)     - first string
;   rsi = b (const char *)     - second string
;   rdx = n (size_t)           - maximum number of bytes to compare
; Returns:
;   eax = signed difference of the first differing byte pair after folding
;         within n bytes, or 0 when the prefix is equal
; Uses / clobbers:
;   Reads rdi/rsi/rdx; writes rax/rcx/rdx/r8/r9/r10 and ymm0-7, plus
;   ymm12-15 (the zero and fold constants). No callee-saved register is
;   touched. Makes no calls.
;==============================================================================
global asm_strncasecmp:function
asm_strncasecmp:
    test    rdx, rdx                    ; n == 0?
    jz      .equal                      ; yes: treated as equal
    ; ---- prologue: broadcast the fold constants into ymm13-15 --------
    mov     eax, 0x41414141             ; 'A' broadcast constant
    vmovd   xmm14, eax                  ; xmm14 = 'A' constant
    vpbroadcastb ymm14, xmm14           ; ymm14 = 'A' in all 32 bytes
    mov     eax, 0x19191919             ; 25 broadcast constant
    vmovd   xmm15, eax                  ; xmm15 = 25 constant
    vpbroadcastb ymm15, xmm15           ; ymm15 = 25 in all 32 bytes
    mov     eax, 0x20202020             ; 0x20 broadcast constant
    vmovd   xmm13, eax                  ; xmm13 = 0x20 constant
    vpbroadcastb ymm13, xmm13           ; ymm13 = 0x20 in all 32 bytes
    vpxor   ymm12, ymm12, ymm12         ; zero constant
    ; ---- budget check, then page-window computation ------------------
.loop:
    cmp     rdx, 32                     ; at least 32 bytes of budget left?
    jb      .bytes_tight                ; no: finish with a scalar loop
    mov     eax, edi                    ; bytes from a to its page end
    and     eax, PAGE_SIZE-1            ; eax = offset of the pointer within its page
    mov     ecx, PAGE_SIZE              ; ecx = size of one page in bytes
    sub     ecx, eax                    ; ecx = bytes from a to its page end
    mov     eax, esi                    ; bytes from b to its page end
    and     eax, PAGE_SIZE-1            ; eax = offset of the pointer within its page
    mov     r9d, PAGE_SIZE              ; r9d = size of one page in bytes
    sub     r9d, eax                    ; r9d = bytes from b to its page end
    cmp     ecx, r9d                    ; ecx = min bytes safely readable
    cmova   ecx, r9d                    ; ecx = min of the two
    cmp     ecx, 32                     ; at least one full vector safe?
    jb      .page_step                  ; < 32 safe bytes: one scalar byte
    shr     ecx, 5                      ; safe 32-byte iterations
    mov     r9, rdx                     ; r9 = n
    shr     r9, 5                       ; budget iterations
    cmp     ecx, r9d                    ; ecx = min(page safe, budget)
    cmova   ecx, r9d                    ; ecx = min of the two
    mov     r10d, ecx                   ; remember how many we will run
    ; ---- main 32-byte folded compare loop -----------------------------
.inner:
    vmovdqu ymm0, [rdi]                 ; load 32 bytes of a
    vmovdqu ymm1, [rsi]                 ; load 32 bytes of b
    ASM_FOLD_LOWER_YMM ymm0, ymm2, ymm3 ; lower-case a
    ASM_FOLD_LOWER_YMM ymm1, ymm4, ymm5 ; lower-case b
    vpcmpeqb ymm6, ymm0, ymm1           ; per-byte equality
    vpmovmskb eax, ymm6                 ; equality mask
    cmp     eax, -1                     ; all 32 bytes equal?
    jne     .diff                       ; no: locate the first difference
    vpcmpeqb ymm7, ymm0, ymm12          ; NUL reached?
    vpmovmskb r9d, ymm7                 ; NUL mask
    test    r9d, r9d                    ; any NUL byte present?
    jnz     .equal                      ; NUL reached: equal
    add     rdi, 32                     ; advance a past this vector
    add     rsi, 32                     ; advance b past this vector
    dec     ecx                         ; one fewer safe vector
    jnz     .inner                      ; more safe vectors: keep comparing
    shl     r10, 5                      ; bytes consumed by the inner loop
    sub     rdx, r10                    ; consume the budget
    jnz     .loop                       ; nonzero: keep comparing
    jmp     .equal                      ; budget exhausted: equal
    ; ---- first mismatch: locate it, unless a NUL comes first --------
.diff:
    not     eax                         ; invert the mask: 1 where bytes differ
    tzcnt   eax, eax                    ; index of the first difference
    vpcmpeqb ymm7, ymm0, ymm12          ; NUL bytes in a
    vpmovmskb ecx, ymm7                 ; NUL mask
    test    ecx, ecx                    ; any NUL in this vector?
    jz      .emit                       ; no NUL before the difference
    tzcnt   ecx, ecx                    ; index of the first set bit
    cmp     ecx, eax                    ; NUL earlier than the difference?
    jb      .equal                      ; yes: strings were equal
    ; ---- emit the scalar folded difference --------------------------
.emit:
    movzx   ecx, byte [rdi+rax]         ; first differing byte of a
    movzx   edx, byte [rsi+rax]         ; b's byte at the difference
    ASM_FOLD_LOWER ecx                  ; lower-case ecx
    ASM_FOLD_LOWER edx                  ; lower-case edx
    mov     eax, ecx                    ; eax = a's byte
    sub     eax, edx                    ; eax = a - b (signed result)
    vzeroupper                          ; drop AVX state
    ret                                 ; return eax
    ; ---- page-edge tail: one folded scalar byte, then recheck -------
.page_step:
    movzx   eax, byte [rdi]             ; one scalar byte, then recheck pages
    movzx   ecx, byte [rsi]             ; b's byte
    ASM_FOLD_LOWER eax                  ; lower-case eax
    ASM_FOLD_LOWER ecx                  ; lower-case ecx
    sub     eax, ecx                    ; eax = a - b
    jnz     .byte_ret                   ; differ: return the difference
    test    ecx, ecx                    ; NUL reached?
    jz      .equal                      ; yes: equal
    inc     rdi                         ; advance a one byte
    inc     rsi                         ; advance b one byte
    dec     rdx                         ; consume one budget byte
    jnz     .loop                       ; nonzero: keep comparing
    jmp     .equal                      ; budget exhausted: equal
    ; ---- fewer than 32 budget bytes: scalar loop --------------------
.bytes_tight:
    test    rdx, rdx                    ; budget exhausted?
    jz      .equal                      ; yes: equal
    ; ---- bytewise budget loop ---------------------------------------
.byte_loop:
    movzx   eax, byte [rdi]             ; tight scalar loop for the last <32
    movzx   ecx, byte [rsi]             ; b's byte
    ASM_FOLD_LOWER eax                  ; lower-case eax
    ASM_FOLD_LOWER ecx                  ; lower-case ecx
    sub     eax, ecx                    ; eax = a - b
    jnz     .byte_ret                   ; differ: return the difference
    test    ecx, ecx                    ; NUL reached?
    jz      .equal                      ; yes: equal
    inc     rdi                         ; advance a one byte
    inc     rsi                         ; advance b one byte
    dec     rdx                         ; consume one budget byte
    jnz     .byte_loop                  ; more budget: keep comparing
    ; ---- equal: return 0 --------------------------------------------
.equal:
    vzeroupper                          ; drop AVX state
    xor     eax, eax                    ; eax = 0
    ret                                 ; return eax
    ; ---- return the scalar difference -------------------------------
.byte_ret:
    vzeroupper                          ; drop AVX state
    ret                                 ; return eax

GNU_STACK_NOTE
