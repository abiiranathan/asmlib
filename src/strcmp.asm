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

; Branchless ASCII lower-casing of the 32-bit register given as the argument.
; Uses r8d as scratch (never edx, so a byte budget held in rdx survives).
%macro ASM_FOLD_LOWER 1
    lea     r8d, [%1 - 'A']             ; distance above 'A' (wraps if below)
    cmp     r8d, 'Z' - 'A'              ; within the uppercase range?
    setbe   r8b                         ; r8b = 1 if uppercase, else 0
    movzx   r8d, r8b                    ; r8d = 0 or 1
    shl     r8d, 5                      ; r8d = 0 or 32
    or      %1, r8d                     ; set the lower-case bit if uppercase
%endmacro

; Vector lower-casing of a 256-bit register for the case-insensitive compares.
; %1 = data (in/out); %2, %3 = scratch. Requires ymm14='A', ymm15=25, ymm13=0x20.
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
;==============================================================================
global asm_strcmp:function
asm_strcmp:
    mov     r10, 0x0101010101010101     ; SWAR "low bit" constant
    mov     r11, 0x8080808080808080     ; SWAR "high bit" constant
.qloop:
    ; ---- page-safety gate: both pointers must allow an 8-byte read
    mov     eax, edi                    ; eax = low 12 bits of a
    and     eax, PAGE_SIZE-1
    cmp     eax, PAGE_SIZE-8            ; would the read cross the page end?
    ja      .byte                       ; yes: fall back to a byte step
    mov     eax, esi                    ; eax = low 12 bits of b
    and     eax, PAGE_SIZE-1
    cmp     eax, PAGE_SIZE-8
    ja      .byte
    ; ---- compare 8 bytes at a time
    mov     rax, [rdi]                  ; load 8 bytes of a
    mov     rcx, [rsi]                  ; load 8 bytes of b
    cmp     rax, rcx                    ; identical chunk?
    jne     .diff                       ; no: locate the differing byte
    ; ---- equal chunk: is there a NUL byte (in both, since they are equal)?
    mov     rdx, rax                    ; copy chunk
    sub     rdx, r10                    ; x - 0x01..01
    not     rax                         ; ~x
    and     rdx, rax                    ; (x-1) & ~x
    and     rdx, r11                    ; mask the high bits
    test    rdx, rdx                    ; any zero byte?
    jnz     .equal                      ; yes: both strings end here
    add     rdi, 8                      ; advance to the next chunk
    add     rsi, 8
    jmp     .qloop
.diff:
    mov     rdx, rax                    ; copy a's chunk
    xor     rdx, rcx                    ; bit positions that differ
    tzcnt   rdx, rdx                    ; lowest differing bit
    ; ---- check for a NUL in a that occurs before the difference
    mov     r8, rax                     ; copy a's chunk
    sub     r8, r10
    not     rax
    and     r8, rax
    and     r8, r11                     ; zero-byte flags of a
    test    r8, r8
    jz      .emit                       ; no NUL before the difference
    tzcnt   r8, r8                      ; bit of the first NUL
    cmp     r8, rdx                     ; NUL earlier than the difference?
    jb      .equal                      ; yes: the strings ended equally
.emit:
    shr     rdx, 3                      ; convert bit index to byte index
    movzx   eax, byte [rdi+rdx]         ; differing byte of a
    movzx   ecx, byte [rsi+rdx]         ; differing byte of b
    sub     eax, ecx                    ; signed result
    ret
.equal:
    xor     eax, eax                    ; strings are equal
    ret
.byte:
    movzx   eax, byte [rdi]             ; load one byte of a
    movzx   ecx, byte [rsi]             ; load one byte of b
    sub     eax, ecx                    ; compare
    jnz     .ret                        ; differing: done
    test    cl, cl                      ; both NUL (they were equal)?
    jz      .equal                      ; yes: equal
    inc     rdi                         ; advance one byte
    inc     rsi
    jmp     .qloop                      ; retry the fast path
.ret:
    ret

;==============================================================================
; int asm_strncmp(const char *a, const char *b, size_t n)
;------------------------------------------------------------------------------
; Compares at most n bytes. Returns 0 if the first n bytes are equal.
;==============================================================================
global asm_strncmp:function
asm_strncmp:
    mov     r8, 0x0101010101010101      ; SWAR "low bit" constant
    mov     r9, 0x8080808080808080      ; SWAR "high bit" constant
.loop:
    cmp     rdx, 8                      ; at least 8 bytes left?
    jb      .bytes                      ; no: finish with a byte loop
    ; ---- page-safety gate for an 8-byte read from both pointers
    mov     r10d, edi
    and     r10d, PAGE_SIZE-1
    cmp     r10d, PAGE_SIZE-8
    ja      .bytes
    mov     r10d, esi
    and     r10d, PAGE_SIZE-1
    cmp     r10d, PAGE_SIZE-8
    ja      .bytes
    ; ---- compare one 8-byte chunk
    mov     rax, [rdi]                  ; chunk of a
    mov     rcx, [rsi]                  ; chunk of b
    cmp     rax, rcx
    jne     .diff                       ; differ: locate the byte
    ; ---- equal chunk: check for a NUL byte
    mov     r10, rax
    sub     r10, r8
    mov     r11, rax
    not     r11
    and     r10, r11
    and     r10, r9
    test    r10, r10
    jnz     .equal                      ; NUL reached before n bytes
    add     rdi, 8
    add     rsi, 8
    sub     rdx, 8
    jmp     .loop
.diff:
    mov     r10, rax                    ; copy a's chunk
    xor     r10, rcx                    ; differing bits
    tzcnt   r10, r10                    ; lowest differing bit
    ; ---- look for a NUL in a before that bit
    mov     r11, rax
    sub     r11, r8
    not     rax
    and     r11, rax
    and     r11, r9
    test    r11, r11
    jz      .emit
    tzcnt   r11, r11
    cmp     r11, r10                    ; NUL before the difference?
    jb      .equal
.emit:
    shr     r10, 3                      ; bit index -> byte index
    movzx   eax, byte [rdi+r10]
    movzx   ecx, byte [rsi+r10]
    sub     eax, ecx
    ret
.equal:
    xor     eax, eax
    ret
.bytes:
    test    rdx, rdx                    ; no bytes left?
    jz      .equal
.byte_loop:
    movzx   eax, byte [rdi]             ; load a byte of a
    movzx   ecx, byte [rsi]             ; load a byte of b
    sub     eax, ecx                    ; compare
    jnz     .ret                        ; differing: done
    test    cl, cl                      ; NUL reached?
    jz      .equal                      ; yes: equal so far
    inc     rdi
    inc     rsi
    dec     rdx                         ; one fewer byte allowed
    jnz     .byte_loop
    jmp     .equal
.ret:
    ret

;==============================================================================
; int asm_strcasecmp(const char *a, const char *b)
;------------------------------------------------------------------------------
; Case-insensitive (C/POSIX locale) comparison of two NUL-terminated strings.
; Uses 32-byte AVX2 folding so long strings are handled 32 bytes per step.
;==============================================================================
global asm_strcasecmp:function
asm_strcasecmp:
    mov     eax, 0x41414141             ; 'A' broadcast constant
    vmovd   xmm14, eax
    vpbroadcastb ymm14, xmm14
    mov     eax, 0x19191919             ; 25 broadcast constant
    vmovd   xmm15, eax
    vpbroadcastb ymm15, xmm15
    mov     eax, 0x20202020             ; 0x20 broadcast constant
    vmovd   xmm13, eax
    vpbroadcastb ymm13, xmm13
    vpxor   ymm12, ymm12, ymm12         ; zero constant
.loop:
    mov     eax, edi                    ; bytes from a to its page end
    and     eax, PAGE_SIZE-1
    mov     ecx, PAGE_SIZE
    sub     ecx, eax
    mov     eax, esi                    ; bytes from b to its page end
    and     eax, PAGE_SIZE-1
    mov     r9d, PAGE_SIZE
    sub     r9d, eax
    cmp     ecx, r9d                    ; ecx = min bytes safely readable
    cmova   ecx, r9d
    cmp     ecx, 32
    jb      .byte                       ; fewer than 32 safe bytes: scalar step
    shr     ecx, 5                      ; number of safe 32-byte iterations
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
    vpmovmskb r9d, ymm7
    test    r9d, r9d
    jnz     .equal                      ; both ended together
    add     rdi, 32                     ; advance
    add     rsi, 32
    dec     ecx                         ; one fewer safe iteration
    jnz     .inner
    jmp     .loop                       ; recompute the page-safe window
.diff:
    not     eax                         ; positions that differ
    tzcnt   eax, eax                    ; first differing bit
    vpcmpeqb ymm7, ymm0, ymm12          ; is there a NUL before the difference?
    vpmovmskb ecx, ymm7
    test    ecx, ecx
    jz      .emit
    tzcnt   ecx, ecx
    cmp     ecx, eax
    jb      .equal                      ; NUL earlier: strings were equal
.emit:
    movzx   ecx, byte [rdi+rax]         ; folded scalar comparison
    movzx   edx, byte [rsi+rax]
    ASM_FOLD_LOWER ecx
    ASM_FOLD_LOWER edx
    mov     eax, ecx
    sub     eax, edx
    vzeroupper
    ret
.equal:
    vzeroupper
    xor     eax, eax
    ret
.byte:
    movzx   eax, byte [rdi]             ; scalar step (page boundary / tail)
    movzx   ecx, byte [rsi]
    ASM_FOLD_LOWER eax
    ASM_FOLD_LOWER ecx
    sub     eax, ecx
    jnz     .byte_ret
    test    ecx, ecx                    ; both folded to NUL?
    jz      .byte_eq
    inc     rdi
    inc     rsi
    jmp     .loop
.byte_eq:
    xor     eax, eax
.byte_ret:
    vzeroupper
    ret

;==============================================================================
; int asm_strncasecmp(const char *a, const char *b, size_t n)
;------------------------------------------------------------------------------
; Case-insensitive comparison of at most n bytes, 32 bytes per vector step.
;==============================================================================
global asm_strncasecmp:function
asm_strncasecmp:
    test    rdx, rdx                    ; n == 0?
    jz      .equal                      ; yes: treated as equal
    mov     eax, 0x41414141             ; 'A' broadcast constant
    vmovd   xmm14, eax
    vpbroadcastb ymm14, xmm14
    mov     eax, 0x19191919             ; 25 broadcast constant
    vmovd   xmm15, eax
    vpbroadcastb ymm15, xmm15
    mov     eax, 0x20202020             ; 0x20 broadcast constant
    vmovd   xmm13, eax
    vpbroadcastb ymm13, xmm13
    vpxor   ymm12, ymm12, ymm12         ; zero constant
.loop:
    cmp     rdx, 32                     ; at least 32 bytes of budget left?
    jb      .bytes_tight                ; no: finish with a scalar loop
    mov     eax, edi                    ; bytes from a to its page end
    and     eax, PAGE_SIZE-1
    mov     ecx, PAGE_SIZE
    sub     ecx, eax
    mov     eax, esi                    ; bytes from b to its page end
    and     eax, PAGE_SIZE-1
    mov     r9d, PAGE_SIZE
    sub     r9d, eax
    cmp     ecx, r9d                    ; ecx = min bytes safely readable
    cmova   ecx, r9d
    cmp     ecx, 32
    jb      .page_step                  ; < 32 safe bytes: one scalar byte
    shr     ecx, 5                      ; safe 32-byte iterations
    mov     r9, rdx
    shr     r9, 5                       ; budget iterations
    cmp     ecx, r9d                    ; ecx = min(page safe, budget)
    cmova   ecx, r9d
    mov     r10d, ecx                   ; remember how many we will run
.inner:
    vmovdqu ymm0, [rdi]                 ; load 32 bytes of a
    vmovdqu ymm1, [rsi]                 ; load 32 bytes of b
    ASM_FOLD_LOWER_YMM ymm0, ymm2, ymm3
    ASM_FOLD_LOWER_YMM ymm1, ymm4, ymm5
    vpcmpeqb ymm6, ymm0, ymm1           ; per-byte equality
    vpmovmskb eax, ymm6
    cmp     eax, -1
    jne     .diff
    vpcmpeqb ymm7, ymm0, ymm12          ; NUL reached?
    vpmovmskb r9d, ymm7
    test    r9d, r9d
    jnz     .equal
    add     rdi, 32
    add     rsi, 32
    dec     ecx
    jnz     .inner
    shl     r10, 5                      ; bytes consumed by the inner loop
    sub     rdx, r10                    ; consume the budget
    jnz     .loop
    jmp     .equal
.diff:
    not     eax
    tzcnt   eax, eax
    vpcmpeqb ymm7, ymm0, ymm12
    vpmovmskb ecx, ymm7
    test    ecx, ecx
    jz      .emit
    tzcnt   ecx, ecx
    cmp     ecx, eax
    jb      .equal
.emit:
    movzx   ecx, byte [rdi+rax]
    movzx   edx, byte [rsi+rax]
    ASM_FOLD_LOWER ecx
    ASM_FOLD_LOWER edx
    mov     eax, ecx
    sub     eax, edx
    vzeroupper
    ret
.page_step:
    movzx   eax, byte [rdi]             ; one scalar byte, then recheck pages
    movzx   ecx, byte [rsi]
    ASM_FOLD_LOWER eax
    ASM_FOLD_LOWER ecx
    sub     eax, ecx
    jnz     .byte_ret
    test    ecx, ecx                    ; NUL reached?
    jz      .equal
    inc     rdi
    inc     rsi
    dec     rdx
    jnz     .loop
    jmp     .equal
.bytes_tight:
    test    rdx, rdx                    ; budget exhausted?
    jz      .equal
.byte_loop:
    movzx   eax, byte [rdi]             ; tight scalar loop for the last <32
    movzx   ecx, byte [rsi]
    ASM_FOLD_LOWER eax
    ASM_FOLD_LOWER ecx
    sub     eax, ecx
    jnz     .byte_ret
    test    ecx, ecx                    ; NUL reached?
    jz      .equal
    inc     rdi
    inc     rsi
    dec     rdx
    jnz     .byte_loop
.equal:
    vzeroupper
    xor     eax, eax
    ret
.byte_ret:
    vzeroupper
    ret

GNU_STACK_NOTE
