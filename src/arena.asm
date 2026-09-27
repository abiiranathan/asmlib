;==============================================================================
; arena.asm - a chunked, resettable linear (bump) arena allocator
;------------------------------------------------------------------------------
; A robust arena allocator for high-throughput temporary allocations:
;
;   int   asm_arena_init      (asm_arena *a, void *buf, size_t size);
;   int   asm_arena_init_grow (asm_arena *a, void *(*alloc)(size_t,void*),
;                              void (*free)(void*,void*), void *ctx,
;                              size_t chunk_size);
;   void *asm_arena_alloc       (asm_arena *a, size_t size);
;   void *asm_arena_alloc_aligned(asm_arena *a, size_t size, size_t align);
;   void *asm_arena_calloc      (asm_arena *a, size_t count, size_t size);
;   void *asm_arena_realloc     (asm_arena *a, void *ptr, size_t old, size_t nw);
;   void  asm_arena_mark        (const asm_arena *a, asm_mark *m);
;   int   asm_arena_release     (asm_arena *a, const asm_mark *m);
;   void  asm_arena_reset       (asm_arena *a);
;   void  asm_arena_destroy     (asm_arena *a);
;   size_t asm_arena_used       (const asm_arena *a);
;   size_t asm_arena_remaining  (const asm_arena *a);
;   size_t asm_arena_capacity   (const asm_arena *a);
;
; Design
; ------
; * Allocations are handed out by bumping a pointer (a few instructions).
; * Memory is carved from a chain of chunks. A fixed arena uses one
;   user-supplied buffer; a growable arena obtains further chunks from a
;   caller-provided backing allocator (e.g. malloc), so it stays usable in
;   freestanding code where no allocator exists.
; * Every allocation is at least 16-byte aligned; alloc_aligned supports any
;   power-of-two alignment.
; * reset() keeps the first chunk and releases all later chunks in one step.
; * mark()/release() give scoped rollback: release frees the chunks newer than
;   the mark and restores the bump pointer.
; * Exhaustion returns NULL; it never overruns the backing store.
;
; This allocator is single-threaded, like the arenas it replaces.
;==============================================================================

BITS 64
default rel

%include "common.inc"

extern asm_memset
extern asm_memcpy
extern asm_sys_alloc
extern asm_sys_free

; ---- asm_arena field offsets (must match include/asmlib.h) ------------------
%define A_PTR       0                   ; unsigned char *ptr
%define A_END       8                   ; unsigned char *end
%define A_CUR       16                  ; chunk *cur
%define A_FIRST     24                  ; chunk *first
%define A_ALLOC     32                  ; void *(*alloc)(size_t, void *)
%define A_FREE      40                  ; void (*free)(void *, void *)
%define A_CTX       48                  ; void *ctx
%define A_CHUNK     56                  ; size_t chunk
%define A_TOTAL     64                  ; size_t total
%define A_USED      72                  ; size_t used
%define A_PEAK      80                  ; size_t peak
%define A_SIZE      88

; ---- chunk header offsets ---------------------------------------------------
%define C_RAW       0                   ; void *raw (free target)
%define C_NEXT      8                   ; chunk *next (older)
%define C_CAP       16                  ; size_t cap (usable bytes)
%define C_BSIZE     24                  ; size_t bsize (backing bytes)
%define C_DATA      32                  ; unsigned char *data
%define C_HDR       48                   ; header size / alignment base

section .text

;==============================================================================
; int asm_arena_init(asm_arena *a, void *buf, size_t size)
;------------------------------------------------------------------------------
; Fixed arena over caller memory. The first 64 bytes of buf hold the chunk
; header and alignment padding. Returns 0 on success, -1 on bad arguments.
;==============================================================================
global asm_arena_init:function
asm_arena_init:
    test    rdi, rdi                    ; a == NULL?
    jz      .bad
    test    rsi, rsi                    ; buf == NULL?
    jz      .bad
    cmp     rdx, 64                     ; enough room for header + capacity?
    jb      .bad
    lea     rax, [rsi+C_HDR]            ; data = align_up(buf + 48, 16)
    add     rax, 15
    and     rax, -16
    lea     rcx, [rsi+rdx]              ; end = buf + size
    cmp     rax, rcx
    jae     .bad                        ; no capacity left
    ; ---- write the chunk header at buf ----
    mov     [rsi+C_RAW], rsi            ; raw = buf (never freed)
    mov     qword [rsi+C_NEXT], 0
    mov     r8, rcx
    sub     r8, rax                     ; cap
    mov     [rsi+C_CAP], r8
    mov     [rsi+C_BSIZE], rdx          ; bsize = size
    mov     [rsi+C_DATA], rax
    ; ---- initialise the arena ----
    mov     [rdi+A_PTR], rax
    mov     [rdi+A_END], rcx
    mov     [rdi+A_CUR], rsi
    mov     [rdi+A_FIRST], rsi
    mov     qword [rdi+A_ALLOC], 0
    mov     qword [rdi+A_FREE], 0
    mov     qword [rdi+A_CTX], 0
    mov     qword [rdi+A_CHUNK], 0
    mov     [rdi+A_TOTAL], r8
    mov     qword [rdi+A_USED], 0
    mov     qword [rdi+A_PEAK], 0
    xor     eax, eax
    ret
.bad:
    mov     eax, -1
    ret

;==============================================================================
; int asm_arena_init_grow(asm_arena *a, alloc, free, ctx, chunk_size)
;------------------------------------------------------------------------------
; Growable arena. alloc(size, ctx) must return at least 16-byte aligned memory
; or NULL; free(ptr, ctx) releases it (may be NULL if memory never needs to be
; returned, e.g. a bump region for the process lifetime).
;==============================================================================
global asm_arena_init_grow:function
asm_arena_init_grow:
    test    rdi, rdi                    ; a == NULL?
    jz      .bad
    test    rsi, rsi                    ; alloc == NULL?
    jz      .bad
    mov     [rdi+A_ALLOC], rsi
    mov     [rdi+A_FREE], rdx
    mov     [rdi+A_CTX], rcx
    mov     r9, 4096                    ; default chunk is at least 4 KiB
    cmp     r8, r9
    cmovb   r8, r9
    mov     [rdi+A_CHUNK], r8
    mov     qword [rdi+A_PTR], 0
    mov     qword [rdi+A_END], 0
    mov     qword [rdi+A_CUR], 0
    mov     qword [rdi+A_FIRST], 0
    mov     qword [rdi+A_TOTAL], 0
    mov     qword [rdi+A_USED], 0
    mov     qword [rdi+A_PEAK], 0
    xor     eax, eax
    ret
.bad:
    mov     eax, -1
    ret

;==============================================================================
; int asm_arena_init_mmap(asm_arena *a, size_t chunk_size)
;------------------------------------------------------------------------------
; Growable arena whose chunks come straight from the kernel via anonymous
; mmap. No libc, no caller-supplied allocator. Requires Linux x86-64.
;==============================================================================
global asm_arena_init_mmap:function
asm_arena_init_mmap:
    mov     r8, rsi                     ; chunk_size
    xor     ecx, ecx                    ; ctx = NULL
    lea     rsi, [rel asm_sys_alloc]    ; alloc callback
    lea     rdx, [rel asm_sys_free]     ; free callback
    jmp     asm_arena_init_grow

;==============================================================================
; internal: L_arena_grow(asm_arena *a, size_t need, size_t align) -> chunk data
;------------------------------------------------------------------------------
; Obtains a new chunk from the backing allocator, links it as the current
; chunk and returns its (align-aligned) data pointer, or NULL.
;==============================================================================
L_arena_grow:
    push    rbx                         ; preserve callee-saved registers
    push    r12
    push    r13
    push    r14
    push    r15
    mov     rbx, rdi                    ; rbx = a
    mov     r12, rsi                    ; r12 = need
    mov     r13, rdx                    ; r13 = align
    mov     r14, [rbx+A_CHUNK]          ; r14 = chunk_size
    cmp     r12, r14
    cmova   r14, r12                    ; r14 = max(chunk_size, need)
    lea     r15, [r14+C_HDR]            ; r15 = chunk_size + header + align
    add     r15, r13
    jc      .fail                       ; size overflow
    mov     rdi, r15                    ; alloc(total_size, ctx)
    mov     rsi, [rbx+A_CTX]
    mov     rax, [rbx+A_ALLOC]
    test    rax, rax
    jz      .fail
    call    rax                         ; rax = raw (or NULL)
    test    rax, rax
    jz      .fail
    mov     r14, rax                    ; r14 = raw
    lea     rcx, [r14+C_HDR]            ; data = align_up(raw + 48, align)
    lea     r10, [r13-1]
    add     rcx, r10
    not     r10
    and     rcx, r10
    lea     rdx, [r14+r15]              ; end = raw + total_size
    mov     r8, rdx
    sub     r8, rcx                     ; cap = end - data
    mov     [r14+C_RAW], r14            ; fill the chunk header
    mov     rax, [rbx+A_CUR]
    mov     [r14+C_NEXT], rax
    mov     [r14+C_CAP], r8
    mov     [r14+C_BSIZE], r15
    mov     [r14+C_DATA], rcx
    mov     [rbx+A_CUR], r14            ; make it current
    mov     [rbx+A_PTR], rcx
    mov     [rbx+A_END], rdx
    add     [rbx+A_TOTAL], r8
    cmp     qword [rbx+A_FIRST], 0      ; remember the first chunk
    jne     .have_first
    mov     [rbx+A_FIRST], r14
.have_first:
    mov     rax, rcx                    ; return the data pointer
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret
.fail:
    xor     eax, eax
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

;==============================================================================
; void *asm_arena_alloc(asm_arena *a, size_t size)
;------------------------------------------------------------------------------
; Returns a 16-byte aligned block of at least size bytes, or NULL.
;==============================================================================
global asm_arena_alloc:function
asm_arena_alloc:
    push    rbx                         ; preserve callee-saved registers
    push    r12
    push    r13
    test    rdi, rdi                    ; a == NULL?
    jz      .fail
    mov     rbx, rdi                    ; rbx = a
    mov     r12, rsi                    ; r12 = size
    mov     rax, r12
    add     rax, 15                     ; round up to 16
    jc      .fail
    and     rax, -16
    mov     r12, rax                    ; r12 = aligned size
    mov     rcx, [rbx+A_PTR]            ; rcx = bump pointer
    test    rcx, rcx
    jz      .grow
    lea     rdx, [rcx+r12]              ; rdx = end of new block
    jc      .fail
    cmp     rdx, [rbx+A_END]            ; fits in the current chunk?
    ja      .grow
    mov     [rbx+A_PTR], rdx            ; commit
    mov     rax, rcx
    add     [rbx+A_USED], r12           ; stats
    mov     r8, [rbx+A_USED]
    cmp     r8, [rbx+A_PEAK]
    jbe     .done
    mov     [rbx+A_PEAK], r8
.done:
    pop     r13
    pop     r12
    pop     rbx
    ret
.grow:
    cmp     qword [rbx+A_ALLOC], 0      ; can we grow?
    je      .fail
    mov     rdi, rbx
    mov     rsi, r12
    mov     edx, 16
    call    L_arena_grow
    test    rax, rax
    jz      .fail
    mov     rcx, [rbx+A_PTR]            ; new chunk: bump from its start
    lea     rdx, [rcx+r12]
    cmp     rdx, [rbx+A_END]
    ja      .fail                       ; cannot happen (cap >= need)
    mov     [rbx+A_PTR], rdx
    mov     rax, rcx
    add     [rbx+A_USED], r12
    mov     r8, [rbx+A_USED]
    cmp     r8, [rbx+A_PEAK]
    jbe     .done
    mov     [rbx+A_PEAK], r8
    jmp     .done
.fail:
    xor     eax, eax
    pop     r13
    pop     r12
    pop     rbx
    ret

;==============================================================================
; void *asm_arena_alloc_aligned(asm_arena *a, size_t size, size_t align)
;------------------------------------------------------------------------------
; Like asm_arena_alloc but the result is aligned to `align` (a power of two;
; values below 16 are treated as 16).
;==============================================================================
global asm_arena_alloc_aligned:function
asm_arena_alloc_aligned:
    test    rdi, rdi                    ; a == NULL?
    jz      .bad
    test    rdx, rdx                    ; align == 0?
    jz      .bad
    mov     rax, rdx
    dec     rax
    test    rdx, rax                    ; align a power of two?
    jnz     .bad
    cmp     rdx, 16                     ; clamp up to 16
    jae     .ok
    mov     edx, 16
.ok:
    push    rbx                         ; preserve callee-saved registers
    push    r12
    push    r13
    push    r14
    push    r15
    mov     rbx, rdi                    ; rbx = a
    mov     r12, rsi                    ; r12 = size
    mov     r13, rdx                    ; r13 = align
    mov     rax, r12
    add     rax, 15
    jc      .fail
    and     rax, -16
    mov     r14, rax                    ; r14 = 16-aligned size
    mov     rcx, [rbx+A_PTR]            ; rcx = bump pointer
    test    rcx, rcx
    jz      .grow
    mov     rax, rcx                    ; p = align_up(ptr, align)
    lea     r10, [r13-1]
    add     rax, r10
    jc      .fail
    not     r10
    and     rax, r10
    lea     rdx, [rax+r14]              ; new pointer
    jc      .fail
    cmp     rdx, [rbx+A_END]
    ja      .grow
    mov     [rbx+A_PTR], rdx
    sub     rdx, rcx                    ; consumed = new - old (pad + size)
    add     [rbx+A_USED], rdx
    mov     r8, [rbx+A_USED]
    cmp     r8, [rbx+A_PEAK]
    jbe     .done
    mov     [rbx+A_PEAK], r8
    jmp     .done
.grow:
    cmp     qword [rbx+A_ALLOC], 0
    je      .fail
    mov     rdi, rbx
    mov     rsi, r14
    mov     rdx, r13
    call    L_arena_grow
    test    rax, rax
    jz      .fail
    mov     rcx, [rbx+A_PTR]            ; data is already align-aligned
    mov     rax, rcx
    lea     rdx, [rax+r14]
    cmp     rdx, [rbx+A_END]
    ja      .fail
    mov     [rbx+A_PTR], rdx
    sub     rdx, rcx
    add     [rbx+A_USED], rdx
    mov     r8, [rbx+A_USED]
    cmp     r8, [rbx+A_PEAK]
    jbe     .done
    mov     [rbx+A_PEAK], r8
.done:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret
.fail:
    xor     eax, eax
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret
.bad:
    xor     eax, eax
    ret

;==============================================================================
; void *asm_arena_calloc(asm_arena *a, size_t count, size_t size)
;------------------------------------------------------------------------------
; Allocates count*size zeroed bytes, or NULL on overflow/exhaustion.
;==============================================================================
global asm_arena_calloc:function
asm_arena_calloc:
    push    rbx                         ; preserve callee-saved registers
    push    r12
    push    r13
    test    rdi, rdi
    jz      .fail
    mov     rbx, rdi
    mov     rax, rsi                    ; rax = count
    mul     rdx                         ; rdx:rax = count * size
    test    rdx, rdx
    jnz     .fail                       ; product overflowed 64 bits
    mov     r12, rax                    ; r12 = total bytes
    mov     rdi, rbx
    mov     rsi, r12
    call    asm_arena_alloc
    test    rax, rax
    jz      .done
    mov     r13, rax                    ; keep the result
    mov     rdi, rax                    ; zero it
    xor     esi, esi
    mov     rdx, r12
    call    asm_memset
    mov     rax, r13
.done:
    pop     r13
    pop     r12
    pop     rbx
    ret
.fail:
    xor     eax, eax
    pop     r13
    pop     r12
    pop     rbx
    ret

;==============================================================================
; void *asm_arena_realloc(asm_arena *a, void *ptr, size_t old, size_t nw)
;------------------------------------------------------------------------------
; Grows/shrinks the most recent allocation in place when possible, otherwise
; allocates a new block and copies min(old, nw) bytes. ptr may be NULL.
;==============================================================================
global asm_arena_realloc:function
asm_arena_realloc:
    push    rbx                         ; preserve callee-saved registers
    push    r12
    push    r13
    push    r14
    push    r15
    test    rdi, rdi
    jz      .fail
    mov     rbx, rdi                    ; rbx = a
    mov     r12, rsi                    ; r12 = ptr
    mov     r13, rdx                    ; r13 = old size
    mov     r14, rcx                    ; r14 = new size
    test    r12, r12
    jz      .alloc_new                  ; realloc(NULL, n) == alloc(n)
    mov     rax, r13                    ; old aligned
    add     rax, 15
    jc      .fail
    and     rax, -16
    mov     rcx, r14                    ; new aligned
    add     rcx, 15
    jc      .fail
    and     rcx, -16
    mov     r15, rcx                    ; r15 = new aligned
    lea     rdx, [r12+rax]              ; is ptr the last allocation?
    cmp     rdx, [rbx+A_PTR]
    jne     .alloc_new
    lea     rdx, [r12+r15]              ; new end
    cmp     rdx, [rbx+A_END]
    ja      .alloc_new
    sub     r15, rax                    ; used delta (may be negative)
    add     [rbx+A_USED], r15
    mov     [rbx+A_PTR], rdx            ; commit in place
    mov     rax, r12
    jmp     .done
.alloc_new:
    mov     rdi, rbx                    ; p = alloc(new)
    mov     rsi, r14
    call    asm_arena_alloc
    test    rax, rax
    jz      .fail
    mov     r15, rax                    ; r15 = new block
    test    r12, r12
    jz      .ret_new                    ; nothing to copy
    mov     rcx, r13                    ; n = min(old, new)
    cmp     rcx, r14
    jbe     .copy
    mov     rcx, r14
.copy:
    mov     rdi, r15
    mov     rsi, r12
    mov     rdx, rcx
    call    asm_memcpy
.ret_new:
    mov     rax, r15
    jmp     .done
.fail:
    xor     eax, eax
.done:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

;==============================================================================
; void asm_arena_mark(const asm_arena *a, asm_mark *m)
;------------------------------------------------------------------------------
; Snapshot the current position so it can be restored with release().
;==============================================================================
global asm_arena_mark:function
asm_arena_mark:
    mov     rax, [rdi+A_CUR]
    mov     [rsi], rax                  ; m->chunk
    mov     rax, [rdi+A_PTR]
    mov     [rsi+8], rax                ; m->ptr
    mov     rax, [rdi+A_USED]
    mov     [rsi+16], rax               ; m->used
    ret

;==============================================================================
; int asm_arena_release(asm_arena *a, const asm_mark *m)
;------------------------------------------------------------------------------
; Rolls back to a mark, freeing every chunk allocated after it.
; Returns 0 on success, -1 if the mark is not valid for this arena.
;==============================================================================
global asm_arena_release:function
asm_arena_release:
    push    rbx                         ; preserve callee-saved registers
    push    r12
    push    r13
    push    r14
    push    r15
    mov     rbx, rdi                    ; rbx = a
    mov     r12, [rsi]                  ; r12 = target chunk
    test    r12, r12
    jz      .bad
    mov     rax, [rbx+A_CUR]            ; walk the chunk chain
.walk:
    test    rax, rax
    jz      .bad
    cmp     rax, r12
    je      .found
    mov     rax, [rax+C_NEXT]
    jmp     .walk
.found:
    mov     r13, [rsi+8]                ; r13 = target ptr
    mov     r8, [r12+C_DATA]
    cmp     r13, r8
    jb      .bad
    mov     r9, r8
    add     r9, [r12+C_CAP]
    cmp     r13, r9
    ja      .bad
    mov     r14, [rsi+16]               ; r14 = target used
    mov     rax, [rbx+A_CUR]            ; free chunks newer than r12
    mov     r15, [rbx+A_FREE]
.free_loop:
    cmp     rax, r12
    je      .freed
    mov     rcx, [rax+C_NEXT]
    push    rcx                         ; preserve list links across the call
    push    rax
    mov     rdx, [rax+C_CAP]
    sub     [rbx+A_TOTAL], rdx
    test    r15, r15
    jz      .no_free
    mov     rdi, [rax+C_RAW]
    mov     rsi, [rax+C_BSIZE]
    mov     rdx, [rbx+A_CTX]
    call    r15
.no_free:
    pop     rax
    pop     rcx
    mov     rax, rcx
    jmp     .free_loop
.freed:
    mov     [rbx+A_CUR], r12            ; restore the mark position
    mov     [rbx+A_PTR], r13
    mov     rax, [r12+C_DATA]
    add     rax, [r12+C_CAP]
    mov     [rbx+A_END], rax
    mov     [rbx+A_USED], r14
    xor     eax, eax
    jmp     .done
.bad:
    mov     eax, -1
.done:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

;==============================================================================
; void asm_arena_reset(asm_arena *a)
;------------------------------------------------------------------------------
; Releases all chunks except the first and rewinds to its start. O(chunks).
;==============================================================================
global asm_arena_reset:function
asm_arena_reset:
    push    rbx                         ; preserve callee-saved registers
    push    r12
    push    r13
    push    r14
    push    r15
    mov     rbx, rdi
    mov     r12, [rbx+A_FIRST]          ; r12 = first chunk
    test    r12, r12
    jz      .zero_stats                 ; growable arena with no chunk yet
    mov     rax, [rbx+A_CUR]            ; free everything after the first
    mov     r15, [rbx+A_FREE]
.free_loop:
    cmp     rax, r12
    je      .freed
    mov     rcx, [rax+C_NEXT]
    push    rcx
    push    rax
    mov     rdx, [rax+C_CAP]
    sub     [rbx+A_TOTAL], rdx
    test    r15, r15
    jz      .no_free
    mov     rdi, [rax+C_RAW]
    mov     rsi, [rax+C_BSIZE]
    mov     rdx, [rbx+A_CTX]
    call    r15
.no_free:
    pop     rax
    pop     rcx
    mov     rax, rcx
    jmp     .free_loop
.freed:
    mov     [rbx+A_CUR], r12            ; rewind to the first chunk
    mov     rax, [r12+C_DATA]
    mov     [rbx+A_PTR], rax
    mov     rdx, [r12+C_CAP]
    add     rdx, rax
    mov     [rbx+A_END], rdx
    mov     rdx, [r12+C_CAP]
    mov     [rbx+A_TOTAL], rdx
.zero_stats:
    mov     qword [rbx+A_USED], 0
    mov     qword [rbx+A_PEAK], 0
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

;==============================================================================
; void asm_arena_destroy(asm_arena *a)
;------------------------------------------------------------------------------
; Releases every chunk (when a free callback is set) and zeroes the arena.
; A fixed arena owns nothing, so only its bookkeeping is cleared.
;==============================================================================
global asm_arena_destroy:function
asm_arena_destroy:
    push    rbx                         ; preserve callee-saved registers
    push    r12
    push    r13
    push    r14
    push    r15
    mov     rbx, rdi
    mov     r15, [rbx+A_FREE]
    mov     rax, [rbx+A_CUR]
.free_loop:
    test    rax, rax
    jz      .cleared
    mov     rcx, [rax+C_NEXT]
    push    rcx
    push    rax
    test    r15, r15
    jz      .no_free
    mov     rdi, [rax+C_RAW]
    mov     rsi, [rax+C_BSIZE]
    mov     rdx, [rbx+A_CTX]
    call    r15
.no_free:
    pop     rax
    pop     rcx
    mov     rax, rcx
    jmp     .free_loop
.cleared:
    mov     rdi, rbx                    ; zero the whole structure
    xor     eax, eax
    mov     ecx, A_SIZE / 8
    rep     stosq
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

;==============================================================================
; size_t asm_arena_used(const asm_arena *a)
;==============================================================================
global asm_arena_used:function
asm_arena_used:
    mov     rax, [rdi+A_USED]
    ret

;==============================================================================
; size_t asm_arena_peak(const asm_arena *a)
;------------------------------------------------------------------------------
; High-water mark of asm_arena_used() since the last reset.
;==============================================================================
global asm_arena_peak:function
asm_arena_peak:
    mov     rax, [rdi+A_PEAK]
    ret

;==============================================================================
; size_t asm_arena_remaining(const asm_arena *a)
;------------------------------------------------------------------------------
; Free bytes left in the current chunk.
;==============================================================================
global asm_arena_remaining:function
asm_arena_remaining:
    mov     rax, [rdi+A_END]
    sub     rax, [rdi+A_PTR]
    ret

;==============================================================================
; size_t asm_arena_capacity(const asm_arena *a)
;------------------------------------------------------------------------------
; Total usable bytes currently backed by all chunks.
;==============================================================================
global asm_arena_capacity:function
asm_arena_capacity:
    mov     rax, [rdi+A_TOTAL]
    ret

GNU_STACK_NOTE
