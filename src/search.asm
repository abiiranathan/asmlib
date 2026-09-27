;==============================================================================
; search.asm - high-performance string/number searching (System V AMD64 ABI)
;------------------------------------------------------------------------------
; Implements:
;   char  *asm_strchr (const char *s, int c);
;   char  *asm_strrchr(const char *s, int c);
;   char  *asm_strstr (const char *hay, const char *needle);
;   void  *asm_memmem (const void *hay, size_t hlen,
;                      const void *needle, size_t nlen);
;   size_t asm_strspn (const char *s, const char *accept);
;   size_t asm_strcspn(const char *s, const char *accept);
;   char  *asm_strpbrk(const char *s, const char *accept);
;
; strchr performs a single AVX2 pass that simultaneously searches for the
; target byte and for the terminating NUL, and honours whichever comes first.
; The accept-set routines build a 256-byte membership table on the stack so
; scanning is a single linear pass.
;==============================================================================

BITS 64
default rel

%include "common.inc"

extern asm_strlen
extern asm_memchr
extern asm_memrchr
extern asm_memcmp

section .text

;==============================================================================
; char *asm_strchr(const char *s, int c)
;------------------------------------------------------------------------------
; Returns a pointer to the first occurrence of (char)c in s, including the
; terminating NUL if c == 0, or NULL if the byte is not present.
;==============================================================================
global asm_strchr:function
asm_strchr:
    vmovd   xmm0, esi                   ; move c into an xmm lane
    vpbroadcastb ymm0, xmm0             ; broadcast c across the vector
    vpxor   ymm2, ymm2, ymm2            ; ymm2 = all zero
    mov     rax, rdi                    ; rax = current pointer
    ; ---- reach a 32-byte aligned address with a short scalar prologue
.align:
    test    al, 31                      ; already 32-byte aligned?
    jz      .aligned                    ; yes: use aligned vector loads
    movzx   ecx, byte [rax]             ; load one byte
    cmp     cl, sil                     ; equal to c?
    je      .found                      ; yes: report it
    test    cl, cl                      ; NUL (end of string)?
    jz      .notfound                   ; yes: c is absent
    inc     rax                         ; advance one byte
    jmp     .align
.aligned:
    vmovdqa ymm1, [rax]                 ; aligned, page-safe load
    vpcmpeqb ymm3, ymm1, ymm0           ; bytes equal to c
    vpcmpeqb ymm4, ymm1, ymm2           ; NUL bytes
    vpmovmskb ecx, ymm3                 ; match mask for c
    vpmovmskb edx, ymm4                 ; match mask for NUL
    test    ecx, ecx                    ; any c match in this block?
    jnz     .candidate                  ; yes: compare positions
    test    edx, edx                    ; any NUL?
    jnz     .notfound                   ; NUL with no c: c is absent
    add     rax, 32                     ; advance to the next block
    jmp     .aligned
.candidate:
    tzcnt   r8d, ecx                    ; position of the first c match
    test    edx, edx                    ; is there a NUL in the block?
    jz      .found_c                    ; no: the c match is valid
    tzcnt   r9d, edx                    ; position of the first NUL
    cmp     r8d, r9d                    ; c at or before the NUL?
    jbe     .found_c                    ; yes: valid (c == 0 lands here too)
    jmp     .notfound                   ; NUL precedes c: c is absent
.found_c:
    add     rax, r8                     ; combine base and offset
.found:
    vzeroupper
    ret
.notfound:
    xor     eax, eax                    ; return NULL
    vzeroupper
    ret

;==============================================================================
; char *asm_strrchr(const char *s, int c)
;------------------------------------------------------------------------------
; Returns a pointer to the last occurrence of (char)c in s, including the
; terminating NUL if c == 0, or NULL if the byte is not present.
;==============================================================================
global asm_strrchr:function
asm_strrchr:
    push    rbx                         ; preserve callee-saved registers
    push    r12
    sub     rsp, 8                      ; realign the stack for calls
    mov     rbx, rdi                    ; rbx = s
    mov     r12d, esi                   ; r12d = c
    call    asm_strlen                  ; rax = strlen(s)
    test    r12b, r12b                  ; searching for the NUL itself?
    jz      .nul_char                   ; yes: return pointer to the NUL
    mov     rdi, rbx                    ; first arg to memrchr
    mov     esi, r12d                   ; second arg to memrchr
    mov     rdx, rax                    ; search within the string body
    call    asm_memrchr                 ; returns pointer or NULL
    add     rsp, 8
    pop     r12
    pop     rbx
    ret
.nul_char:
    lea     rax, [rbx+rax]              ; pointer to the terminating NUL
    add     rsp, 8
    pop     r12
    pop     rbx
    ret

;==============================================================================
; void *asm_memmem(const void *hay, size_t hlen,
;                  const void *needle, size_t nlen)
;------------------------------------------------------------------------------
; Finds the first occurrence of needle[0..nlen) inside hay[0..hlen).
; Returns the address or NULL. An empty needle returns hay.
;==============================================================================
global asm_memmem:function
asm_memmem:
    test    rcx, rcx                    ; empty needle?
    jz      .ret_hay                    ; yes: match at the start
    cmp     rcx, rsi                    ; needle longer than haystack?
    ja      .ret_null                   ; yes: impossible
    push    rbx                         ; preserve callee-saved registers
    push    r12
    push    r13
    push    r14
    push    r15
    mov     rbx, rdi                    ; rbx = hay
    mov     r12, rdx                    ; r12 = needle
    mov     r13, rcx                    ; r13 = nlen
    lea     r15, [rdi+rsi]              ; r15 = hay + hlen
    sub     r15, rcx                    ; r15 = address of the last valid start
    cmp     r13, 1                      ; single-byte needle?
    je      .single                     ; yes: a plain memchr is optimal
    vmovd   xmm0, [r12]                 ; load the first needle byte
    vpbroadcastb ymm0, xmm0             ; broadcast byte 0 across the vector
    vmovd   xmm2, [r12+1]               ; load the second needle byte
    vpbroadcastb ymm2, xmm2             ; broadcast byte 1 across the vector
    mov     r14, rdi                    ; r14 = scan pointer
    and     r14, -32                    ; align down: aligned loads are page safe
    ; ---- scan aligned 32-byte blocks; the first two needle bytes are -----
    ; ---- matched with two vector compares so only real candidates  ------
    ; ---- reach the (rare) full memcmp.                            ------
.scan_block:
    cmp     r14, r15                    ; any possible start left?
    ja      .notfound                   ; no: no match
    vmovdqa ymm1, [r14]                 ; aligned, page-safe load
    vmovdqa ymm3, ymm1                  ; keep a copy for the second compare
    vpcmpeqb ymm1, ymm1, ymm0           ; bytes equal to needle[0]
    vpcmpeqb ymm3, ymm3, ymm2           ; bytes equal to needle[1]
    vpmovmskb eax, ymm1                 ; first-byte mask
    vpmovmskb ecx, ymm3                 ; second-byte mask
    shr     ecx, 1                      ; align second-byte mask to starts
    and     eax, ecx                    ; starts matching both bytes (0..30)
    test    eax, eax
    jz      .last_byte                  ; none: still check the block's last byte
.candidate:
    tzcnt   ecx, eax                    ; first candidate within the block
    lea     r11, [r14+rcx]              ; its address
    cmp     r11, rbx                    ; before the haystack (first block)?
    jb      .next_candidate             ; yes: ignore it
    cmp     r11, r15                    ; a legal start address?
    ja      .notfound                   ; no: nothing later can be valid
    sub     rsp, 16                     ; preserve state across the call
    mov     [rsp], eax                  ; remaining candidate bitmask
    mov     [rsp+8], r11                ; candidate address
    mov     rdi, r11                    ; verify the whole needle
    mov     rsi, r12
    mov     rdx, r13
    call    asm_memcmp
    mov     edx, eax                    ; stash the comparison result
    mov     eax, [rsp]                  ; restore the candidate bitmask
    mov     r11, [rsp+8]                ; restore the candidate address
    add     rsp, 16
    vmovd   xmm0, [r12]                 ; memcmp clobbered ymm0/ymm2: refresh
    vpbroadcastb ymm0, xmm0
    vmovd   xmm2, [r12+1]
    vpbroadcastb ymm2, xmm2
    test    edx, edx
    jz      .found                      ; full match
.next_candidate:
    blsr    eax, eax                    ; drop the candidate we just tested
    test    eax, eax
    jnz     .candidate
.last_byte:
    lea     r11, [r14+31]               ; a start at the block's last byte...
    cmp     r11, r15                    ; ...only counts at/before the last start
    ja      .next_block
    cmp     r11, rbx                    ; and not before the haystack
    jb      .next_block
    movzx   r10d, byte [r12]            ; scalar first-byte compare
    cmp     r10b, byte [r11]
    jne     .next_block
    movzx   r10d, byte [r12+1]          ; scalar second-byte compare
    cmp     r10b, byte [r11+1]
    jne     .next_block
    mov     rdi, r11                    ; verify the whole needle
    mov     rsi, r12
    mov     rdx, r13
    call    asm_memcmp
    test    eax, eax
    jz      .found                      ; full match
    vmovd   xmm0, [r12]                 ; memcmp clobbered ymm0/ymm2: refresh
    vpbroadcastb ymm0, xmm0
    vmovd   xmm2, [r12+1]
    vpbroadcastb ymm2, xmm2
.next_block:
    add     r14, 32                     ; advance one aligned block
    jmp     .scan_block
.single:
    mov     rdx, rsi                    ; hlen (rsi is still the argument)
    movzx   esi, byte [r12]             ; search for the single byte
    mov     rdi, rbx
    call    asm_memchr
    jmp     .pop_ret
.found:
    mov     rax, r11                    ; match address
    jmp     .pop_ret
.notfound:
    xor     eax, eax                    ; no match
.pop_ret:
    vzeroupper
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret
.ret_hay:
    mov     rax, rdi                    ; empty needle matches at hay
    ret
.ret_null:
    xor     eax, eax                    ; needle too long
    ret

;==============================================================================
; char *asm_strstr(const char *hay, const char *needle)
;------------------------------------------------------------------------------
; Finds the first occurrence of the NUL-terminated needle inside hay.
; Returns the address or NULL. An empty needle returns hay.
;==============================================================================
global asm_strstr:function
asm_strstr:
    push    rbx                         ; preserve callee-saved registers
    push    r12
    push    r13
    mov     rbx, rdi                    ; rbx = hay
    mov     r12, rsi                    ; r12 = needle
    call    asm_strlen                  ; rax = strlen(hay)
    mov     r13, rax                    ; r13 = hlen
    mov     rdi, r12                    ; first arg to strlen
    call    asm_strlen                  ; rax = strlen(needle)
    mov     rcx, rax                    ; nlen
    mov     rdi, rbx                    ; first arg to memmem
    mov     rsi, r13                    ; hlen
    mov     rdx, r12                    ; needle
    call    asm_memmem                  ; rax = result
    pop     r13
    pop     r12
    pop     rbx
    ret

;==============================================================================
; Internal helper: build the 256-byte membership table used by the span
; routines. On entry rsi points at the accept string and rsp points at the
; 256-byte table. Clobbers rax, rcx and ymm0.
;==============================================================================
%macro BUILD_ACCEPT_TABLE 0
    vpxor   ymm0, ymm0, ymm0            ; zero the table with 32-byte stores
%assign off 0
%rep 8
    vmovdqu [rsp+off], ymm0
%assign off off+32
%endrep
    mov     rcx, rsi                    ; rcx = accept pointer
%%build:
    movzx   eax, byte [rcx]             ; next accept byte
    test    al, al                      ; end of accept string?
    jz      %%done                      ; yes: table is complete
    mov     byte [rsp+rax], 1           ; mark byte as a member
    inc     rcx
    jmp     %%build
%%done:
%endmacro

;==============================================================================
; size_t asm_strspn(const char *s, const char *accept)
;------------------------------------------------------------------------------
; Length of the initial segment of s made only of bytes from accept.
;==============================================================================
global asm_strspn:function
asm_strspn:
    push    rbx                         ; preserve callee-saved register
    sub     rsp, 256                    ; scratch membership table
    BUILD_ACCEPT_TABLE                  ; fill [rsp, rsp+256)
    mov     rax, rdi                    ; rax = scan pointer
    xor     edx, edx                    ; rdx = count
.scan:
    movzx   ecx, byte [rax]             ; next source byte
    test    cl, cl                      ; NUL?
    jz      .done                       ; yes: end of segment
    cmp     byte [rsp+rcx], 0           ; byte a member of accept?
    je      .done                       ; no: stop
    inc     rax                         ; advance
    inc     rdx                         ; count a byte
    jmp     .scan
.done:
    mov     rax, rdx                    ; return the length
    vzeroupper
    add     rsp, 256
    pop     rbx
    ret

;==============================================================================
; size_t asm_strcspn(const char *s, const char *accept)
;------------------------------------------------------------------------------
; Length of the initial segment of s made only of bytes NOT in accept.
;==============================================================================
global asm_strcspn:function
asm_strcspn:
    push    rbx                         ; preserve callee-saved register
    sub     rsp, 256                    ; scratch membership table
    BUILD_ACCEPT_TABLE                  ; fill [rsp, rsp+256)
    mov     rax, rdi                    ; rax = scan pointer
    xor     edx, edx                    ; rdx = count
.scan:
    movzx   ecx, byte [rax]             ; next source byte
    test    cl, cl                      ; NUL?
    jz      .done                       ; yes: end of segment
    cmp     byte [rsp+rcx], 0           ; byte a member of accept?
    jne     .done                       ; yes: stop
    inc     rax                         ; advance
    inc     rdx                         ; count a byte
    jmp     .scan
.done:
    mov     rax, rdx                    ; return the length
    vzeroupper
    add     rsp, 256
    pop     rbx
    ret

;==============================================================================
; char *asm_strpbrk(const char *s, const char *accept)
;------------------------------------------------------------------------------
; Returns a pointer to the first byte of s that also occurs in accept, or
; NULL if there is none.
;==============================================================================
global asm_strpbrk:function
asm_strpbrk:
    push    rbx                         ; preserve callee-saved register
    sub     rsp, 256                    ; scratch membership table
    BUILD_ACCEPT_TABLE                  ; fill [rsp, rsp+256)
    mov     rax, rdi                    ; rax = scan pointer
.scan:
    movzx   ecx, byte [rax]             ; next source byte
    test    cl, cl                      ; NUL?
    jz      .notfound                   ; yes: no byte from accept found
    cmp     byte [rsp+rcx], 0           ; byte a member of accept?
    jne     .found                      ; yes: report this address
    inc     rax                         ; advance
    jmp     .scan
.found:
    vzeroupper
    add     rsp, 256
    pop     rbx
    ret
.notfound:
    xor     eax, eax                    ; return NULL
    vzeroupper
    add     rsp, 256
    pop     rbx
    ret

GNU_STACK_NOTE
