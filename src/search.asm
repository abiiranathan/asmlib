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
;
; Parameters (System V AMD64 ABI):
;   rdi = s (const char *)     - NUL-terminated string to scan
;   esi = c (int)              - byte value to find; only the low 8 bits are used
; Returns:
;   rax = pointer to the first matching byte, or NULL when absent
; Uses / clobbers:
;   Reads rdi/rsi; writes rax/rcx/rdx/r8/r9 and ymm0-4. All xmm/ymm are
;   caller-saved; no callee-saved register is touched. Makes no calls.
;==============================================================================
global asm_strchr:function
asm_strchr:
    ; ---- prologue: broadcast the search byte and a zero vector ------
    vmovd   xmm0, esi                   ; move c into an xmm lane
    vpbroadcastb ymm0, xmm0             ; broadcast c across the vector
    vpxor   ymm2, ymm2, ymm2            ; ymm2 = all zero
    mov     ecx, edi                    ; ecx = s (for the offset)
    and     rdi, -32                    ; rdi = aligned block base (page safe)
    and     ecx, 31                     ; ecx = bytes before s in this block
    jz      .main                       ; s is aligned: straight to the scan
    ; ---- head block: bytes before s are masked off with a shift ----------
    vmovdqa ymm1, [rdi]                 ; aligned, page-safe load
    vpcmpeqb ymm3, ymm1, ymm0           ; bytes equal to c
    vpcmpeqb ymm4, ymm1, ymm2           ; NUL bytes
    vpmovmskb r8d, ymm3                 ; c mask (relative to the block)
    vpmovmskb r9d, ymm4                 ; NUL mask
    shr     r8d, cl                     ; drop bytes before s
    shr     r9d, cl                     ; r9d >>= offset (drop bytes before s)
    add     rdi, rcx                    ; rdi = s
    test    r8d, r8d                    ; any c match at/after s?
    jz      .head_no_c                  ; no: continue unless a NUL ends s
    test    r9d, r9d                    ; any NUL at/after s?
    jz      .head_hit                   ; no: the c match is valid
    tzcnt   r8d, r8d                    ; both present: whichever is earlier
    tzcnt   r9d, r9d                    ; wins (c == 0 lands here too)
    cmp     r8d, r9d                    ; c match earlier than the NUL?
    ja      .notfound                   ; NUL precedes c: c is absent
    add     rdi, r8                     ; result = s + position
    mov     rax, rdi                    ; rax = result pointer
    vzeroupper                          ; drop AVX state
    ret                                 ; return rax
.head_hit:
    tzcnt   r8d, r8d                    ; position of the first c at/after s
    add     rdi, r8                     ; result = s + position
    mov     rax, rdi                    ; rax = result pointer
    vzeroupper                          ; drop AVX state
    ret                                 ; return rax
.head_no_c:
    test    r9d, r9d                    ; NUL in the head (at/after s)?
    jnz     .notfound                   ; yes: c is absent
.head_tail:
    add     rdi, 32                     ; next block (base was s - offset)
    and     rdi, -32                    ; restore the aligned base
    ; ---- aligned main scan: 32-byte page-safe blocks ----------------
.main:
    vmovdqa ymm1, [rdi]                 ; aligned, page-safe load
    vpcmpeqb ymm3, ymm1, ymm0           ; bytes equal to c
    vpcmpeqb ymm4, ymm1, ymm2           ; NUL bytes
    vpmovmskb ecx, ymm3                 ; match mask for c
    vpmovmskb edx, ymm4                 ; match mask for NUL
    test    ecx, ecx                    ; any c match in this block?
    jnz     .candidate                  ; yes: compare positions
    test    edx, edx                    ; any NUL?
    jnz     .notfound                   ; NUL with no c: c is absent
    add     rdi, 32                     ; advance to the next block
    jmp     .main                       ; enter the aligned scan loop
    ; ---- first c candidate: compare with any NUL in the block ------
.candidate:
    tzcnt   r8d, ecx                    ; position of the first c match
    test    edx, edx                    ; is there a NUL in the block?
    jz      .found_c                    ; no: the c match is valid
    tzcnt   r9d, edx                    ; position of the first NUL
    cmp     r8d, r9d                    ; c at or before the NUL?
    jbe     .found_c                    ; yes: valid (c == 0 lands here too)
    jmp     .notfound                   ; NUL precedes c: c is absent
.found_c:
    add     rdi, r8                     ; combine base and offset
.found:
    mov     rax, rdi                    ; rax = result pointer
    vzeroupper                          ; drop AVX state
    ret                                 ; return rax
    ; ---- no occurrence: return NULL ---------------------------------
.notfound:
    xor     eax, eax                    ; return NULL
    vzeroupper                          ; drop AVX state
    ret                                 ; return rax

;==============================================================================
; char *asm_strrchr(const char *s, int c)
;------------------------------------------------------------------------------
; Returns a pointer to the last occurrence of (char)c in s, including the
; terminating NUL if c == 0, or NULL if the byte is not present.
;
; Parameters (System V AMD64 ABI):
;   rdi = s (const char *)     - NUL-terminated string to scan
;   rsi = c (int)              - byte value to find; only the low 8 bits are used
; Returns:
;   rax = pointer to the last matching byte, or NULL when absent
; Uses / clobbers:
;   Pushes and restores rbx/r12. Calls asm_strlen and asm_memrchr, which
;   clobber the caller-saved registers (and xmm/ymm as applicable). Returns
;   in rax and makes no other calls.
;==============================================================================
global asm_strrchr:function
asm_strrchr:
    ; ---- prologue: preserve callee-saved registers ------------------
    push    rbx                         ; preserve callee-saved registers
    push    r12                         ; preserve callee-saved r12
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
    ; ---- epilogue: restore the stack and callee-saved registers -----
    add     rsp, 8                      ; restore the stack alignment
    pop     r12                         ; restore callee-saved r12
    pop     rbx                         ; restore callee-saved rbx
    ret                                 ; return rax
    ; ---- c == 0: report the terminating NUL -------------------------
.nul_char:
    lea     rax, [rbx+rax]              ; pointer to the terminating NUL
    add     rsp, 8                      ; restore the stack alignment
    pop     r12                         ; restore callee-saved r12
    pop     rbx                         ; restore callee-saved rbx
    ret                                 ; return rax

;==============================================================================
; void *asm_memmem(const void *hay, size_t hlen,
;                  const void *needle, size_t nlen)
;------------------------------------------------------------------------------
; Finds the first occurrence of needle[0..nlen) inside hay[0..hlen).
; Returns the address or NULL. An empty needle returns hay.
;
; Parameters (System V AMD64 ABI):
;   rdi = hay    (const void *) - buffer to search
;   rsi = hlen   (size_t)       - number of bytes in hay
;   rdx = needle (const void *) - bytes to find
;   rcx = nlen   (size_t)       - number of bytes in needle
; Returns:
;   rax = pointer to the first match, or NULL when there is none
; Uses / clobbers:
;   Pushes and restores rbx/r12/r13/r14/r15. Uses ymm0-3; for a one-byte
;   needle it calls asm_memchr, otherwise it calls asm_memcmp. Those callees
;   clobber the caller-saved GPRs and ymm, so the needle vectors are refreshed
;   after each call.
;==============================================================================
global asm_memmem:function
asm_memmem:
    ; ---- prologue: length checks and callee-saved registers ----------
    test    rcx, rcx                    ; empty needle?
    jz      .ret_hay                    ; yes: match at the start
    cmp     rcx, rsi                    ; needle longer than haystack?
    ja      .ret_null                   ; yes: impossible
    push    rbx                         ; preserve callee-saved registers
    push    r12                         ; preserve callee-saved r12
    push    r13                         ; preserve callee-saved r13
    push    r14                         ; preserve callee-saved r14
    push    r15                         ; preserve callee-saved r15
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
    test    eax, eax                    ; any candidate start left? (sets ZF)
    jz      .last_byte                  ; none: still check the block's last byte
    ; ---- candidate start: bounds-check, then verify the needle -----
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
    mov     rsi, r12                    ; second arg to memcmp (needle)
    mov     rdx, r13                    ; third arg to memcmp (nlen)
    call    asm_memcmp                  ; verify the whole needle
    mov     edx, eax                    ; stash the comparison result
    mov     eax, [rsp]                  ; restore the candidate bitmask
    mov     r11, [rsp+8]                ; restore the candidate address
    add     rsp, 16                     ; release the scratch slots
    vmovd   xmm0, [r12]                 ; memcmp clobbered ymm0/ymm2: refresh
    vpbroadcastb ymm0, xmm0             ; ymm0 = needle[0] in every byte
    vmovd   xmm2, [r12+1]               ; load needle[1]
    vpbroadcastb ymm2, xmm2             ; ymm2 = needle[1] in every byte
    test    edx, edx                    ; needle[0..nlen) equal? (sets ZF)
    jz      .found                      ; full match
.next_candidate:
    blsr    eax, eax                    ; drop the candidate we just tested
    test    eax, eax                    ; more candidates left? (sets ZF)
    jnz     .candidate                  ; more candidates: keep testing
    ; ---- a start at the block's last byte spans into the next block -
.last_byte:
    lea     r11, [r14+31]               ; a start at the block's last byte...
    cmp     r11, r15                    ; ...only counts at/before the last start
    ja      .next_block                 ; beyond the last valid start: next block
    cmp     r11, rbx                    ; and not before the haystack
    jb      .next_block                 ; before the haystack: next block
    movzx   r10d, byte [r12]            ; scalar first-byte compare
    cmp     r10b, byte [r11]            ; first needle byte equal?
    jne     .next_block                 ; no: next block
    movzx   r10d, byte [r12+1]          ; scalar second-byte compare
    cmp     r10b, byte [r11+1]          ; second needle byte equal?
    jne     .next_block                 ; no: next block
    mov     rdi, r11                    ; verify the whole needle
    mov     rsi, r12                    ; second arg to memcmp (needle)
    mov     rdx, r13                    ; third arg to memcmp (nlen)
    call    asm_memcmp                  ; verify the whole needle
    test    eax, eax                    ; full needle matched? (sets ZF)
    jz      .found                      ; full match
    vmovd   xmm0, [r12]                 ; memcmp clobbered ymm0/ymm2: refresh
    vpbroadcastb ymm0, xmm0             ; ymm0 = needle[0] in every byte
    vmovd   xmm2, [r12+1]               ; load needle[1]
    vpbroadcastb ymm2, xmm2             ; ymm2 = needle[1] in every byte
    ; ---- advance to the next aligned block --------------------------
.next_block:
    add     r14, 32                     ; advance one aligned block
    jmp     .scan_block                 ; scan the next aligned block
    ; ---- one-byte needle: defer to asm_memchr -----------------------
.single:
    mov     rdx, rsi                    ; hlen (rsi is still the argument)
    movzx   esi, byte [r12]             ; search for the single byte
    mov     rdi, rbx                    ; first arg to memchr (hay)
    call    asm_memchr                  ; single-byte search
    jmp     .pop_ret                    ; unwrap the stack and return
.found:
    mov     rax, r11                    ; match address
    jmp     .pop_ret                    ; unwrap the stack and return
.notfound:
    xor     eax, eax                    ; no match
    ; ---- common epilogue: drop AVX state and restore registers ------
.pop_ret:
    vzeroupper                          ; drop AVX state
    pop     r15                         ; restore callee-saved r15
    pop     r14                         ; restore callee-saved r14
    pop     r13                         ; restore callee-saved r13
    pop     r12                         ; restore callee-saved r12
    pop     rbx                         ; restore callee-saved rbx
    ret                                 ; return rax
.ret_hay:
    mov     rax, rdi                    ; empty needle matches at hay
    ret                                 ; return rax
.ret_null:
    xor     eax, eax                    ; needle too long
    ret                                 ; return rax

;==============================================================================
; char *asm_strstr(const char *hay, const char *needle)
;------------------------------------------------------------------------------
; Finds the first occurrence of the NUL-terminated needle inside hay.
; Returns the address or NULL. An empty needle returns hay.
;
; Parameters (System V AMD64 ABI):
;   rdi = hay    (const char *) - NUL-terminated string to search
;   rsi = needle (const char *) - NUL-terminated substring to find
; Returns:
;   rax = pointer to the first match, or NULL when there is none
; Uses / clobbers:
;   Pushes and restores rbx/r12/r13. Calls asm_strlen twice and then
;   asm_memmem; for a one-character needle it tail-calls asm_strchr. Those
;   callees clobber the caller-saved registers (and xmm/ymm as applicable).
;==============================================================================
global asm_strstr:function
asm_strstr:
    ; ---- prologue: classify the needle by its first bytes -----------
    movzx   eax, byte [rsi]             ; needle[0]
    test    al, al                      ; empty needle?
    jz      .empty                      ; yes: match at hay
    movzx   ecx, byte [rsi+1]           ; needle[1]
    test    cl, cl                      ; one-character needle?
    jz      .one                        ; yes: strchr needs no strlen(hay)
    push    rbx                         ; preserve callee-saved registers
    push    r12                         ; preserve callee-saved r12
    push    r13                         ; preserve callee-saved r13
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
    ; ---- epilogue: restore callee-saved registers and return --------
    pop     r13                         ; restore callee-saved r13
    pop     r12                         ; restore callee-saved r12
    pop     rbx                         ; restore callee-saved rbx
    ret                                 ; return rax
    ; ---- empty needle matches at hay --------------------------------
.empty:
    mov     rax, rdi                    ; empty needle matches at hay
    ret                                 ; return rax
    ; ---- one-character needle: defer to asm_strchr ------------------
.one:
    movzx   esi, byte [rsi]             ; single byte: a plain strchr is optimal
    jmp     asm_strchr                  ; tail call (rdi is already hay)

;==============================================================================
; BUILD_ACCEPT_TABLE - build a 256-byte membership table on the stack
;------------------------------------------------------------------------------
; Purpose: zero a caller-provided 256-byte buffer and then set table[c] = 1
; for every byte c listed in the NUL-terminated accept string, so the span
; routines can test membership with a single indexed load.
;
; Parameters:
;   (none)
;
; Registers / side effects:
;   Reads rsi (the accept pointer) and rsp (the table base). Clobbers rax, rcx
;   and ymm0, and writes into [rsp, rsp+256). The table is only valid while
;   the caller keeps the stack allocation that holds it.
;==============================================================================
%macro BUILD_ACCEPT_TABLE 0
    vpxor   ymm0, ymm0, ymm0            ; zero the table with 32-byte stores
%assign off 0                           ; off = 0 (table offset)
%rep 8                                  ; eight 32-byte stores cover 256 bytes
    vmovdqu [rsp+off], ymm0             ; store 32 zero bytes at [rsp+off]
%assign off off+32                      ; advance the table offset
%endrep                                 ; end of the zero-fill loop
    mov     rcx, rsi                    ; rcx = accept pointer
%%build:
    movzx   eax, byte [rcx]             ; next accept byte
    test    al, al                      ; end of accept string?
    jz      %%done                      ; yes: table is complete
    mov     byte [rsp+rax], 1           ; mark byte as a member
    inc     rcx                         ; advance past this accept byte
    jmp     %%build                     ; process the next accept byte
%%done:
%endmacro

;==============================================================================
; size_t asm_strspn(const char *s, const char *accept)
;------------------------------------------------------------------------------
; Length of the initial segment of s made only of bytes from accept.
;
; Parameters (System V AMD64 ABI):
;   rdi = s      (const char *) - string to scan
;   rsi = accept (const char *) - set of accepted bytes
; Returns:
;   rax = length of the initial run of bytes that are in accept
; Uses / clobbers:
;   Pushes and restores rbx. Reserves a 256-byte stack table via
;   BUILD_ACCEPT_TABLE (clobbering rax/rcx/ymm0 and that scratch area).
;   Returns in rax and makes no other calls.
;==============================================================================
global asm_strspn:function
asm_strspn:
    ; ---- prologue: allocate and build the membership table ----------
    push    rbx                         ; preserve callee-saved register
    sub     rsp, 256                    ; scratch membership table
    BUILD_ACCEPT_TABLE                  ; fill [rsp, rsp+256)
    mov     rax, rdi                    ; rax = scan pointer
    xor     edx, edx                    ; rdx = count
    ; ---- table-driven scan of s -------------------------------------
.scan:
    movzx   ecx, byte [rax]             ; next source byte
    test    cl, cl                      ; NUL?
    jz      .done                       ; yes: end of segment
    cmp     byte [rsp+rcx], 0           ; byte a member of accept?
    je      .done                       ; no: stop
    inc     rax                         ; advance
    inc     rdx                         ; count a byte
    jmp     .scan                       ; continue scanning
    ; ---- end of segment: return the count ---------------------------
.done:
    mov     rax, rdx                    ; return the length
    vzeroupper                          ; drop AVX state
    add     rsp, 256                    ; release the membership table
    pop     rbx                         ; restore callee-saved rbx
    ret                                 ; return rax

;==============================================================================
; size_t asm_strcspn(const char *s, const char *accept)
;------------------------------------------------------------------------------
; Length of the initial segment of s made only of bytes NOT in accept.
;
; Parameters (System V AMD64 ABI):
;   rdi = s      (const char *) - string to scan
;   rsi = accept (const char *) - set of rejected bytes
; Returns:
;   rax = length of the initial run of bytes that are not in accept
; Uses / clobbers:
;   Pushes and restores rbx. Reserves a 256-byte stack table via
;   BUILD_ACCEPT_TABLE (clobbering rax/rcx/ymm0 and that scratch area).
;   Returns in rax and makes no other calls.
;==============================================================================
global asm_strcspn:function
asm_strcspn:
    ; ---- prologue: allocate and build the membership table ----------
    push    rbx                         ; preserve callee-saved register
    sub     rsp, 256                    ; scratch membership table
    BUILD_ACCEPT_TABLE                  ; fill [rsp, rsp+256)
    mov     rax, rdi                    ; rax = scan pointer
    xor     edx, edx                    ; rdx = count
    ; ---- table-driven scan of s -------------------------------------
.scan:
    movzx   ecx, byte [rax]             ; next source byte
    test    cl, cl                      ; NUL?
    jz      .done                       ; yes: end of segment
    cmp     byte [rsp+rcx], 0           ; byte a member of accept?
    jne     .done                       ; yes: stop
    inc     rax                         ; advance
    inc     rdx                         ; count a byte
    jmp     .scan                       ; continue scanning
    ; ---- end of segment: return the count ---------------------------
.done:
    mov     rax, rdx                    ; return the length
    vzeroupper                          ; drop AVX state
    add     rsp, 256                    ; release the membership table
    pop     rbx                         ; restore callee-saved rbx
    ret                                 ; return rax

;==============================================================================
; char *asm_strpbrk(const char *s, const char *accept)
;------------------------------------------------------------------------------
; Returns a pointer to the first byte of s that also occurs in accept, or
; NULL if there is none.
;
; Parameters (System V AMD64 ABI):
;   rdi = s      (const char *) - string to scan
;   rsi = accept (const char *) - set of bytes to look for
; Returns:
;   rax = pointer to the first matching byte, or NULL when there is none
; Uses / clobbers:
;   Pushes and restores rbx. Reserves a 256-byte stack table via
;   BUILD_ACCEPT_TABLE (clobbering rax/rcx/ymm0 and that scratch area).
;   Returns in rax and makes no other calls.
;==============================================================================
global asm_strpbrk:function
asm_strpbrk:
    ; ---- prologue: allocate and build the membership table ----------
    push    rbx                         ; preserve callee-saved register
    sub     rsp, 256                    ; scratch membership table
    BUILD_ACCEPT_TABLE                  ; fill [rsp, rsp+256)
    mov     rax, rdi                    ; rax = scan pointer
    ; ---- table-driven scan of s -------------------------------------
.scan:
    movzx   ecx, byte [rax]             ; next source byte
    test    cl, cl                      ; NUL?
    jz      .notfound                   ; yes: no byte from accept found
    cmp     byte [rsp+rcx], 0           ; byte a member of accept?
    jne     .found                      ; yes: report this address
    inc     rax                         ; advance
    jmp     .scan                       ; continue scanning
    ; ---- membership hit: return this address ------------------------
.found:
    vzeroupper                          ; drop AVX state
    add     rsp, 256                    ; release the membership table
    pop     rbx                         ; restore callee-saved rbx
    ret                                 ; return rax
    ; ---- no hit: return NULL ----------------------------------------
.notfound:
    xor     eax, eax                    ; return NULL
    vzeroupper                          ; drop AVX state
    add     rsp, 256                    ; release the membership table
    pop     rbx                         ; restore callee-saved rbx
    ret                                 ; return rax

GNU_STACK_NOTE
