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
%define A_PTR       0                   ; unsigned char *ptr - next free byte in the current chunk
%define A_END       8                   ; unsigned char *end - one past the current chunk
%define A_CUR       16                  ; chunk *cur - newest (current) chunk
%define A_FIRST     24                  ; chunk *first - oldest chunk, reset target
%define A_ALLOC     32                  ; void *(*alloc)(size_t, void *) - backing allocator callback
%define A_FREE      40                  ; void (*free)(void *, void *) - backing release callback
%define A_CTX       48                  ; void *ctx - context for both callbacks
%define A_CHUNK     56                  ; size_t chunk - default size for growable chunks
%define A_TOTAL     64                  ; size_t total - usable bytes across all chunks
%define A_USED      72                  ; size_t used - bytes handed out since reset
%define A_PEAK      80                  ; size_t peak - high-water mark of used
%define A_SIZE      88                  ; size_t A_SIZE - sizeof(asm_arena) in bytes

; ---- chunk header offsets ---------------------------------------------------
%define C_RAW       0                   ; void *raw - allocation base passed to free
%define C_NEXT      8                   ; chunk *next - next older chunk
%define C_CAP       16                  ; size_t cap - usable bytes in this chunk
%define C_BSIZE     24                  ; size_t bsize - backing bytes passed to free
%define C_DATA      32                  ; unsigned char *data - first usable byte
%define C_HDR       48                   ; size_t C_HDR - chunk header size / alignment base

section .text

;==============================================================================
; int asm_arena_init(asm_arena *a, void *buf, size_t size)
;------------------------------------------------------------------------------
; Fixed arena over caller memory. The first 64 bytes of buf hold the chunk
; header and alignment padding. Returns 0 on success, -1 on bad arguments.
;
; Parameters (System V AMD64 ABI):
;   rdi = a (asm_arena *)  - arena to initialise
;   rsi = buf (void *)  - caller-owned backing buffer
;   rdx = size (size_t)  - length of buf in bytes
; Returns:
;   rax = 0 on success, -1 on invalid arguments
; Uses / clobbers:
;   Reads rdi, rsi, rdx; writes rax, rcx, r8. No callee-saved registers used.
;==============================================================================
global asm_arena_init:function
asm_arena_init:
    ; ---- validate arguments ----
    test    rdi, rdi                    ; a == NULL?
    jz      .bad                        ; fail: no arena
    test    rsi, rsi                    ; buf == NULL?
    jz      .bad                        ; fail: no buffer
    cmp     rdx, 64                     ; enough room for header + capacity?
    jb      .bad                        ; fail: size < 64
    ; ---- compute the aligned data pointer and capacity ----
    lea     rax, [rsi+C_HDR]            ; data = align_up(buf + 48, 16)
    add     rax, 15                     ; rax = buf + 48 + 15 (round-up bias)
    and     rax, -16                    ; round rax down to a 16-byte boundary
    lea     rcx, [rsi+rdx]              ; end = buf + size
    cmp     rax, rcx                    ; does data fit before end?
    jae     .bad                        ; no capacity left
    ; ---- write the chunk header at buf ----
    mov     [rsi+C_RAW], rsi            ; raw = buf (never freed)
    mov     qword [rsi+C_NEXT], 0       ; next = NULL (no older chunk)
    mov     r8, rcx                     ; r8 = buf + size
    sub     r8, rax                     ; cap
    mov     [rsi+C_CAP], r8             ; cap = end - data
    mov     [rsi+C_BSIZE], rdx          ; bsize = size
    mov     [rsi+C_DATA], rax           ; data = aligned payload base
    ; ---- initialise the arena ----
    mov     [rdi+A_PTR], rax            ; ptr = first free byte
    mov     [rdi+A_END], rcx            ; end = buf + size
    mov     [rdi+A_CUR], rsi            ; cur = the only chunk
    mov     [rdi+A_FIRST], rsi          ; first = the only chunk
    mov     qword [rdi+A_ALLOC], 0      ; fixed arena: no alloc callback
    mov     qword [rdi+A_FREE], 0       ; fixed arena: no free callback
    mov     qword [rdi+A_CTX], 0        ; ctx = NULL
    mov     qword [rdi+A_CHUNK], 0      ; no default grow size
    mov     [rdi+A_TOTAL], r8           ; total = cap
    mov     qword [rdi+A_USED], 0       ; used = 0
    mov     qword [rdi+A_PEAK], 0       ; peak = 0
    xor     eax, eax                    ; return 0 (success)
    ret                                 ; return
    ; ---- invalid arguments -> -1 ----
.bad:
    mov     eax, -1                     ; return -1 (bad arguments)
    ret                                 ; return

;==============================================================================
; int asm_arena_init_grow(asm_arena *a, alloc, free, ctx, chunk_size)
;------------------------------------------------------------------------------
; Growable arena. alloc(size, ctx) must return at least 16-byte aligned memory
; or NULL; free(ptr, ctx) releases it (may be NULL if memory never needs to be
; returned, e.g. a bump region for the process lifetime).
;
; Parameters (System V AMD64 ABI):
;   rdi = a (asm_arena *)  - arena to initialise
;   rsi = alloc (void *(*)(size_t, void *))  - backing allocation callback
;   rdx = free (void (*)(void *, void *))  - backing release callback (may be NULL)
;   rcx = ctx (void *)  - opaque context passed to both callbacks
;   r8 = chunk_size (size_t)  - default chunk size, clamped up to 4096
; Returns:
;   rax = 0 on success, -1 if a or alloc is NULL
; Uses / clobbers:
;   Reads rdi, rsi, rdx, rcx, r8; writes rax, r9. No callee-saved registers used.
;==============================================================================
global asm_arena_init_grow:function
asm_arena_init_grow:
    ; ---- validate arguments ----
    test    rdi, rdi                    ; a == NULL?
    jz      .bad                        ; fail: no arena
    test    rsi, rsi                    ; alloc == NULL?
    jz      .bad                        ; fail: no alloc callback
    ; ---- store the backing allocator and clamp the chunk size ----
    mov     [rdi+A_ALLOC], rsi          ; store alloc callback
    mov     [rdi+A_FREE], rdx           ; store free callback (may be NULL)
    mov     [rdi+A_CTX], rcx            ; store allocator context
    mov     r9, 4096                    ; default chunk is at least 4 KiB
    cmp     r8, r9                      ; chunk_size below 4096?
    cmovb   r8, r9                      ; clamp chunk_size up to 4096
    mov     [rdi+A_CHUNK], r8           ; remember default chunk size
    ; ---- clear the arena state ----
    mov     qword [rdi+A_PTR], 0        ; ptr = NULL (no chunk yet)
    mov     qword [rdi+A_END], 0        ; end = NULL
    mov     qword [rdi+A_CUR], 0        ; cur = NULL
    mov     qword [rdi+A_FIRST], 0      ; first = NULL
    mov     qword [rdi+A_TOTAL], 0      ; total = 0
    mov     qword [rdi+A_USED], 0       ; used = 0
    mov     qword [rdi+A_PEAK], 0       ; peak = 0
    xor     eax, eax                    ; return 0 (success)
    ret                                 ; return
    ; ---- invalid arguments -> -1 ----
.bad:
    mov     eax, -1                     ; return -1 (bad arguments)
    ret                                 ; return

;==============================================================================
; int asm_arena_init_mmap(asm_arena *a, size_t chunk_size)
;------------------------------------------------------------------------------
; Growable arena whose chunks come straight from the kernel via anonymous
; mmap. No libc, no caller-supplied allocator. Requires Linux x86-64.
;
; Parameters (System V AMD64 ABI):
;   rdi = a (asm_arena *)  - arena to initialise
;   rsi = chunk_size (size_t)  - default chunk size, clamped up to 4096
; Returns:
;   rax = 0 on success, -1 if a is NULL
; Uses / clobbers:
;   Reads rdi, rsi; writes rax, rcx, rdx, r8, r9; tail-calls asm_arena_init_grow.
;==============================================================================
global asm_arena_init_mmap:function
asm_arena_init_mmap:
    ; ---- wire up the anonymous-mmap backend ----
    mov     r8, rsi                     ; chunk_size
    xor     ecx, ecx                    ; ctx = NULL
    lea     rsi, [rel asm_sys_alloc]    ; alloc callback
    lea     rdx, [rel asm_sys_free]     ; free callback
    jmp     asm_arena_init_grow         ; tail-call the growable initialiser

;==============================================================================
; internal: L_arena_grow(asm_arena *a, size_t need, size_t align) -> chunk data
;------------------------------------------------------------------------------
; Obtains a new chunk from the backing allocator, links it as the current
; chunk and returns its (align-aligned) data pointer, or NULL.
;
; Parameters (System V AMD64 ABI):
;   rdi = a (asm_arena *)  - arena whose backing allocator is used
;   rsi = need (size_t)  - minimum usable capacity required
;   rdx = align (size_t)  - alignment for the returned data pointer
; Returns:
;   rax = chunk data pointer, or NULL if the backing allocation fails
; Uses / clobbers:
;   Reads rdi, rsi, rdx; writes rax, rcx, r8-r10, r14, r15. Pushes/restores
;   rbx and r12-r15. Calls the arena's alloc callback.
;==============================================================================
L_arena_grow:
    ; ---- prologue: preserve callee-saved registers ----
    push    rbx                         ; preserve callee-saved registers
    push    r12                         ; save a
    push    r13                         ; save need
    push    r14                         ; save align
    push    r15                         ; save scratch
    ; ---- stash arguments; size the backing allocation ----
    mov     rbx, rdi                    ; rbx = a
    mov     r12, rsi                    ; r12 = need
    mov     r13, rdx                    ; r13 = align
    mov     r14, [rbx+A_CHUNK]          ; r14 = chunk_size
    cmp     r12, r14                    ; need > chunk_size?
    cmova   r14, r12                    ; r14 = max(chunk_size, need)
    lea     r15, [r14+C_HDR]            ; r15 = chunk_size + header + align
    add     r15, r13                    ; total = chunk + header + align
    jc      .fail                       ; size overflow
    ; ---- call the backing allocator ----
    mov     rdi, r15                    ; alloc(total_size, ctx)
    mov     rsi, [rbx+A_CTX]            ; arg2 = ctx
    mov     rax, [rbx+A_ALLOC]          ; rax = alloc callback
    test    rax, rax                    ; callback present?
    jz      .fail                       ; no allocator -> fail
    call    rax                         ; rax = raw (or NULL)
    test    rax, rax                    ; raw == NULL?
    jz      .fail                       ; allocation failed -> fail
    ; ---- align the payload and compute the capacity ----
    mov     r14, rax                    ; r14 = raw
    lea     rcx, [r14+C_HDR]            ; data = align_up(raw + 48, align)
    lea     r10, [r13-1]                ; r10 = align - 1
    add     rcx, r10                    ; data = raw + 48 + align-1
    not     r10                         ; r10 = ~(align-1)
    and     rcx, r10                    ; align data down to align
    lea     rdx, [r14+r15]              ; end = raw + total_size
    mov     r8, rdx                     ; r8 = raw + total_size
    sub     r8, rcx                     ; cap = end - data
    ; ---- fill in and link the new chunk header ----
    mov     [r14+C_RAW], r14            ; fill the chunk header
    mov     rax, [rbx+A_CUR]            ; rax = old current chunk
    mov     [r14+C_NEXT], rax           ; next = old current
    mov     [r14+C_CAP], r8             ; cap = end - data
    mov     [r14+C_BSIZE], r15          ; bsize = requested total
    mov     [r14+C_DATA], rcx           ; data = aligned payload
    mov     [rbx+A_CUR], r14            ; make it current
    mov     [rbx+A_PTR], rcx            ; ptr = data
    mov     [rbx+A_END], rdx            ; end = raw + total
    add     [rbx+A_TOTAL], r8           ; total += cap
    ; ---- remember the first chunk ----
    cmp     qword [rbx+A_FIRST], 0      ; remember the first chunk
    jne     .have_first                 ; first chunk already set?
    mov     [rbx+A_FIRST], r14          ; record the first chunk
.have_first:
    ; ---- epilogue: return the data pointer ----
    mov     rax, rcx                    ; return the data pointer
    pop     r15                         ; restore scratch
    pop     r14                         ; restore align
    pop     r13                         ; restore need
    pop     r12                         ; restore a
    pop     rbx                         ; restore a
    ret                                 ; return data pointer
.fail:
    ; ---- allocation failed -> return NULL ----
    xor     eax, eax                    ; rax = NULL (failure)
    pop     r15                         ; restore scratch
    pop     r14                         ; restore align
    pop     r13                         ; restore need
    pop     r12                         ; restore a
    pop     rbx                         ; restore a
    ret                                 ; return NULL

;==============================================================================
; void *asm_arena_alloc(asm_arena *a, size_t size)
;------------------------------------------------------------------------------
; Returns a 16-byte aligned block of at least size bytes, or NULL.
;
; Parameters (System V AMD64 ABI):
;   rdi = a (asm_arena *)  - arena to allocate from
;   rsi = size (size_t)  - minimum block size in bytes
; Returns:
;   rax = 16-byte aligned block, or NULL on overflow or exhaustion
; Uses / clobbers:
;   Reads rdi, rsi; writes rax, rcx, rdx, r8. Pushes/restores rbx, r12, r13.
;   Calls L_arena_grow when the current chunk lacks room.
;==============================================================================
global asm_arena_alloc:function
asm_arena_alloc:
    ; ---- prologue: preserve callee-saved registers ----
    push    rbx                         ; preserve callee-saved registers
    push    r12                         ; save size
    push    r13                         ; save scratch
    ; ---- validate the arena ----
    test    rdi, rdi                    ; a == NULL?
    jz      .fail                       ; a == NULL -> fail
    mov     rbx, rdi                    ; rbx = a
    mov     r12, rsi                    ; r12 = size
    ; ---- round the request up to 16 bytes ----
    mov     rax, r12                    ; rax = size
    add     rax, 15                     ; round up to 16
    jc      .fail                       ; size + 15 overflow -> fail
    and     rax, -16                    ; round size up to 16
    mov     r12, rax                    ; r12 = aligned size
    ; ---- try the current chunk ----
    mov     rcx, [rbx+A_PTR]            ; rcx = bump pointer
    test    rcx, rcx                    ; current chunk present?
    jz      .grow                       ; no chunk -> grow
    lea     rdx, [rcx+r12]              ; rdx = end of new block
    jc      .fail                       ; ptr + size overflow -> fail
    ; ---- fit check ----
    cmp     rdx, [rbx+A_END]            ; fits in the current chunk?
    ja      .grow                       ; does not fit -> grow
    ; ---- commit the allocation and update stats ----
    mov     [rbx+A_PTR], rdx            ; commit
    mov     rax, rcx                    ; rax = start of block
    add     [rbx+A_USED], r12           ; stats
    mov     r8, [rbx+A_USED]            ; r8 = new used
    cmp     r8, [rbx+A_PEAK]            ; used > peak?
    jbe     .done                       ; no new peak -> done
    mov     [rbx+A_PEAK], r8            ; peak = used
.done:
    ; ---- epilogue ----
    pop     r13                         ; restore scratch
    pop     r12                         ; restore size
    pop     rbx                         ; restore a
    ret                                 ; return block
    ; ---- grow: add a new chunk via the backing allocator ----
.grow:
    cmp     qword [rbx+A_ALLOC], 0      ; can we grow?
    je      .fail                       ; no allocator -> fail
    mov     rdi, rbx                    ; arg1 = a
    mov     rsi, r12                    ; arg2 = aligned size
    mov     edx, 16                     ; arg3 = 16-byte alignment
    call    L_arena_grow                ; get a new chunk
    test    rax, rax                    ; grow succeeded?
    jz      .fail                       ; grow failed -> fail
    ; ---- bump from the start of the new chunk ----
    mov     rcx, [rbx+A_PTR]            ; new chunk: bump from its start
    lea     rdx, [rcx+r12]              ; rdx = end of block
    cmp     rdx, [rbx+A_END]            ; fits in new chunk?
    ja      .fail                       ; cannot happen (cap >= need)
    mov     [rbx+A_PTR], rdx            ; commit bump pointer
    mov     rax, rcx                    ; rax = block
    add     [rbx+A_USED], r12           ; used += size
    mov     r8, [rbx+A_USED]            ; r8 = new used
    cmp     r8, [rbx+A_PEAK]            ; used > peak?
    jbe     .done                       ; no new peak -> done
    mov     [rbx+A_PEAK], r8            ; peak = used
    jmp     .done                       ; return block
    ; ---- failure path ----
.fail:
    xor     eax, eax                    ; rax = NULL (failure)
    pop     r13                         ; restore scratch
    pop     r12                         ; restore size
    pop     rbx                         ; restore a
    ret                                 ; return NULL

;==============================================================================
; void *asm_arena_alloc_aligned(asm_arena *a, size_t size, size_t align)
;------------------------------------------------------------------------------
; Like asm_arena_alloc but the result is aligned to `align` (a power of two;
; values below 16 are treated as 16).
;
; Parameters (System V AMD64 ABI):
;   rdi = a (asm_arena *)  - arena to allocate from
;   rsi = size (size_t)  - minimum block size in bytes
;   rdx = align (size_t)  - required alignment (power of two, min 16)
; Returns:
;   rax = align-aligned block, or NULL on bad alignment, overflow or exhaustion
; Uses / clobbers:
;   Reads rdi, rsi, rdx; writes rax, rcx, rdx, r8, r10. Pushes/restores
;   rbx and r12-r15. Calls L_arena_grow when the current chunk lacks room.
;==============================================================================
global asm_arena_alloc_aligned:function
asm_arena_alloc_aligned:
    ; ---- validate the alignment ----
    test    rdi, rdi                    ; a == NULL?
    jz      .bad                        ; a == NULL -> fail
    test    rdx, rdx                    ; align == 0?
    jz      .bad                        ; align == 0 -> fail
    mov     rax, rdx                    ; rax = align
    dec     rax                         ; rax = align - 1
    test    rdx, rax                    ; align a power of two?
    jnz     .bad                        ; not a power of two -> fail
    cmp     rdx, 16                     ; clamp up to 16
    jae     .ok                         ; align >= 16 -> keep
    mov     edx, 16                     ; clamp align to 16
.ok:
    ; ---- prologue: preserve callee-saved registers ----
    push    rbx                         ; preserve callee-saved registers
    push    r12                         ; save size
    push    r13                         ; save align
    push    r14                         ; save rounded size
    push    r15                         ; save scratch
    mov     rbx, rdi                    ; rbx = a
    mov     r12, rsi                    ; r12 = size
    mov     r13, rdx                    ; r13 = align
    ; ---- round the request up to 16 bytes ----
    mov     rax, r12                    ; rax = size
    add     rax, 15                     ; size + 15 (round-up bias)
    jc      .fail                       ; size + 15 overflow -> fail
    and     rax, -16                    ; r14 = 16-aligned size
    mov     r14, rax                    ; r14 = 16-aligned size
    mov     rcx, [rbx+A_PTR]            ; rcx = bump pointer
    test    rcx, rcx                    ; current chunk present?
    jz      .grow                       ; no chunk -> grow
    ; ---- align the bump pointer within the current chunk ----
    mov     rax, rcx                    ; p = align_up(ptr, align)
    lea     r10, [r13-1]                ; r10 = align - 1
    add     rax, r10                    ; rax = ptr + align - 1
    jc      .fail                       ; alignment add overflow -> fail
    not     r10                         ; r10 = ~(align-1)
    and     rax, r10                    ; rax = align_up(ptr, align)
    ; ---- fit check ----
    lea     rdx, [rax+r14]              ; new pointer
    jc      .fail                       ; block end overflow -> fail
    cmp     rdx, [rbx+A_END]            ; fits in chunk?
    ja      .grow                       ; does not fit -> grow
    ; ---- commit the allocation and update stats ----
    mov     [rbx+A_PTR], rdx            ; commit bump pointer
    sub     rdx, rcx                    ; consumed = new - old (pad + size)
    add     [rbx+A_USED], rdx           ; used += pad + size
    mov     r8, [rbx+A_USED]            ; r8 = new used
    cmp     r8, [rbx+A_PEAK]            ; used > peak?
    jbe     .done                       ; no new peak -> done
    mov     [rbx+A_PEAK], r8            ; peak = used
    jmp     .done                       ; return block
    ; ---- grow: request an aligned chunk ----
.grow:
    cmp     qword [rbx+A_ALLOC], 0      ; allocator present?
    je      .fail                       ; no allocator -> fail
    mov     rdi, rbx                    ; arg1 = a
    mov     rsi, r14                    ; arg2 = rounded size
    mov     rdx, r13                    ; arg3 = align
    call    L_arena_grow                ; get an aligned chunk
    test    rax, rax                    ; grow succeeded?
    jz      .fail                       ; grow failed -> fail
    mov     rcx, [rbx+A_PTR]            ; data is already align-aligned
    mov     rax, rcx                    ; rax = block
    lea     rdx, [rax+r14]              ; rdx = end of block
    cmp     rdx, [rbx+A_END]            ; fits in new chunk?
    ja      .fail                       ; cannot happen -> fail
    mov     [rbx+A_PTR], rdx            ; commit bump pointer
    sub     rdx, rcx                    ; consumed = end - start
    add     [rbx+A_USED], rdx           ; used += consumed
    mov     r8, [rbx+A_USED]            ; r8 = new used
    cmp     r8, [rbx+A_PEAK]            ; used > peak?
    jbe     .done                       ; no new peak -> done
    mov     [rbx+A_PEAK], r8            ; peak = used
    ; ---- epilogue ----
.done:
    pop     r15                         ; restore scratch
    pop     r14                         ; restore rounded size
    pop     r13                         ; restore align
    pop     r12                         ; restore size
    pop     rbx                         ; restore a
    ret                                 ; return block
    ; ---- failure path ----
.fail:
    xor     eax, eax                    ; rax = NULL (failure)
    pop     r15                         ; restore scratch
    pop     r14                         ; restore rounded size
    pop     r13                         ; restore align
    pop     r12                         ; restore size
    pop     rbx                         ; restore a
    ret                                 ; return NULL
    ; ---- invalid alignment -> NULL ----
.bad:
    xor     eax, eax                    ; rax = NULL (bad alignment)
    ret                                 ; return NULL

;==============================================================================
; void *asm_arena_calloc(asm_arena *a, size_t count, size_t size)
;------------------------------------------------------------------------------
; Allocates count*size zeroed bytes, or NULL on overflow/exhaustion.
;
; Parameters (System V AMD64 ABI):
;   rdi = a (asm_arena *)  - arena to allocate from
;   rsi = count (size_t)  - element count
;   rdx = size (size_t)  - element size in bytes
; Returns:
;   rax = zeroed block, or NULL on overflow or exhaustion
; Uses / clobbers:
;   Reads rdi, rsi, rdx; writes rax, rdx. Pushes/restores rbx, r12, r13.
;   Calls asm_arena_alloc and asm_memset.
;==============================================================================
global asm_arena_calloc:function
asm_arena_calloc:
    ; ---- prologue: preserve callee-saved registers ----
    push    rbx                         ; preserve callee-saved registers
    push    r12                         ; save total bytes
    push    r13                         ; save block
    ; ---- validate the arena ----
    test    rdi, rdi                    ; a == NULL?
    jz      .fail                       ; a == NULL -> fail
    mov     rbx, rdi                    ; rbx = a
    ; ---- count * size with overflow check ----
    mov     rax, rsi                    ; rax = count
    mul     rdx                         ; rdx:rax = count * size
    test    rdx, rdx                    ; product high half == 0?
    jnz     .fail                       ; product overflowed 64 bits
    mov     r12, rax                    ; r12 = total bytes
    ; ---- allocate and zero the block ----
    mov     rdi, rbx                    ; arg1 = a
    mov     rsi, r12                    ; arg2 = total bytes
    call    asm_arena_alloc             ; allocate the block
    test    rax, rax                    ; allocation succeeded?
    jz      .done                       ; failed -> return NULL
    mov     r13, rax                    ; keep the result
    mov     rdi, rax                    ; zero it
    xor     esi, esi                    ; fill byte = 0
    mov     rdx, r12                    ; length = total bytes
    call    asm_memset                  ; zero the block
    mov     rax, r13                    ; return the block
    ; ---- epilogue ----
.done:
    pop     r13                         ; restore block
    pop     r12                         ; restore total
    pop     rbx                         ; restore a
    ret                                 ; return
    ; ---- failure path ----
.fail:
    xor     eax, eax                    ; rax = NULL (failure)
    pop     r13                         ; restore block
    pop     r12                         ; restore total
    pop     rbx                         ; restore a
    ret                                 ; return NULL

;==============================================================================
; void *asm_arena_realloc(asm_arena *a, void *ptr, size_t old, size_t nw)
;------------------------------------------------------------------------------
; Grows/shrinks the most recent allocation in place when possible, otherwise
; allocates a new block and copies min(old, nw) bytes. ptr may be NULL.
;
; Parameters (System V AMD64 ABI):
;   rdi = a (asm_arena *)  - arena to reallocate in
;   rsi = ptr (void *)  - existing block, or NULL
;   rdx = old (size_t)  - current usable size of ptr
;   rcx = nw (size_t)  - requested new size in bytes
; Returns:
;   rax = resized block, or NULL on overflow or allocation failure
; Uses / clobbers:
;   Reads rdi, rsi, rdx, rcx; writes rax, rcx, rdx, r15. Pushes/restores
;   rbx and r12-r15. Calls asm_arena_alloc and asm_memcpy.
;==============================================================================
global asm_arena_realloc:function
asm_arena_realloc:
    ; ---- prologue: preserve callee-saved registers ----
    push    rbx                         ; preserve callee-saved registers
    push    r12                         ; save ptr
    push    r13                         ; save old size
    push    r14                         ; save new size
    push    r15                         ; save scratch
    ; ---- validate arguments; treat NULL ptr as alloc ----
    test    rdi, rdi                    ; a == NULL?
    jz      .fail                       ; a == NULL -> fail
    mov     rbx, rdi                    ; rbx = a
    mov     r12, rsi                    ; r12 = ptr
    mov     r13, rdx                    ; r13 = old size
    mov     r14, rcx                    ; r14 = new size
    test    r12, r12                    ; ptr == NULL?
    jz      .alloc_new                  ; realloc(NULL, n) == alloc(n)
    ; ---- round old and new sizes up to 16 ----
    mov     rax, r13                    ; old aligned
    add     rax, 15                     ; old + 15 (round-up bias)
    jc      .fail                       ; old + 15 overflow -> fail
    and     rax, -16                    ; rax = old rounded to 16
    mov     rcx, r14                    ; new aligned
    add     rcx, 15                     ; new + 15 (round-up bias)
    jc      .fail                       ; new + 15 overflow -> fail
    and     rcx, -16                    ; rcx = new rounded to 16
    mov     r15, rcx                    ; r15 = new aligned
    ; ---- in-place growth of the last allocation ----
    lea     rdx, [r12+rax]              ; is ptr the last allocation?
    cmp     rdx, [rbx+A_PTR]            ; ptr the last allocation?
    jne     .alloc_new                  ; no -> allocate a new block
    lea     rdx, [r12+r15]              ; new end
    cmp     rdx, [rbx+A_END]            ; new end within chunk?
    ja      .alloc_new                  ; no -> allocate a new block
    sub     r15, rax                    ; used delta (may be negative)
    add     [rbx+A_USED], r15           ; used += (new - old)
    mov     [rbx+A_PTR], rdx            ; commit in place
    mov     rax, r12                    ; rax = ptr (unchanged)
    jmp     .done                       ; return in-place block
    ; ---- allocate a new block and copy ----
.alloc_new:
    mov     rdi, rbx                    ; p = alloc(new)
    mov     rsi, r14                    ; arg2 = new size
    call    asm_arena_alloc             ; allocate the new block
    test    rax, rax                    ; allocation succeeded?
    jz      .fail                       ; failed -> return NULL
    mov     r15, rax                    ; r15 = new block
    test    r12, r12                    ; anything to copy?
    jz      .ret_new                    ; nothing to copy
    mov     rcx, r13                    ; n = min(old, new)
    cmp     rcx, r14                    ; old <= new?
    jbe     .copy                       ; yes -> copy old bytes
    mov     rcx, r14                    ; else copy new bytes
.copy:
    mov     rdi, r15                    ; arg1 = destination
    mov     rsi, r12                    ; arg2 = source
    mov     rdx, rcx                    ; arg3 = bytes to copy
    call    asm_memcpy                  ; copy the live prefix
.ret_new:
    mov     rax, r15                    ; rax = new block
    jmp     .done                       ; return new block
    ; ---- failure path ----
.fail:
    xor     eax, eax                    ; rax = NULL (failure)
    ; ---- epilogue ----
.done:
    pop     r15                         ; restore scratch
    pop     r14                         ; restore new size
    pop     r13                         ; restore old size
    pop     r12                         ; restore ptr
    pop     rbx                         ; restore a
    ret                                 ; return

;==============================================================================
; void asm_arena_mark(const asm_arena *a, asm_mark *m)
;------------------------------------------------------------------------------
; Snapshot the current position so it can be restored with release().
;
; Parameters (System V AMD64 ABI):
;   rdi = a (const asm_arena *)  - arena to snapshot
;   rsi = m (asm_mark *)  - mark to fill in
; Returns:
;   rax = unused (void)
; Uses / clobbers:
;   Reads rdi; writes rax and the three words at m (chunk, ptr, used).
;==============================================================================
global asm_arena_mark:function
asm_arena_mark:
    ; ---- snapshot chunk, position and used ----
    mov     rax, [rdi+A_CUR]            ; rax = a->cur
    mov     [rsi], rax                  ; m->chunk
    mov     rax, [rdi+A_PTR]            ; rax = a->ptr
    mov     [rsi+8], rax                ; m->ptr
    mov     rax, [rdi+A_USED]           ; rax = a->used
    mov     [rsi+16], rax               ; m->used
    ret                                 ; return (mark filled in)

;==============================================================================
; int asm_arena_release(asm_arena *a, const asm_mark *m)
;------------------------------------------------------------------------------
; Rolls back to a mark, freeing every chunk allocated after it.
; Returns 0 on success, -1 if the mark is not valid for this arena.
;
; Parameters (System V AMD64 ABI):
;   rdi = a (asm_arena *)  - arena to roll back
;   rsi = m (const asm_mark *)  - mark previously filled by asm_arena_mark
; Returns:
;   rax = 0 on success, -1 if the mark is not valid for this arena
; Uses / clobbers:
;   Reads rdi, rsi; writes rax, rcx, rdx, r8, r9. Pushes/restores rbx and
;   r12-r15. Calls the arena's free callback for every newer chunk.
;==============================================================================
global asm_arena_release:function
asm_arena_release:
    ; ---- prologue: preserve callee-saved registers ----
    push    rbx                         ; preserve callee-saved registers
    push    r12                         ; save mark chunk
    push    r13                         ; save mark ptr
    push    r14                         ; save mark used
    push    r15                         ; save free callback
    mov     rbx, rdi                    ; rbx = a
    mov     r12, [rsi]                  ; r12 = target chunk
    test    r12, r12                    ; mark chunk == NULL?
    jz      .bad                        ; invalid mark -> fail
    ; ---- walk the chunk chain to the mark ----
    mov     rax, [rbx+A_CUR]            ; walk the chunk chain
.walk:
    test    rax, rax                    ; end of chunk chain?
    jz      .bad                        ; mark not in this arena -> fail
    cmp     rax, r12                    ; reached the mark chunk?
    je      .found                      ; yes -> found it
    mov     rax, [rax+C_NEXT]           ; rax = older chunk
    jmp     .walk                       ; keep walking
.found:
    ; ---- validate the saved pointer against the chunk ----
    mov     r13, [rsi+8]                ; r13 = target ptr
    mov     r8, [r12+C_DATA]            ; r8 = chunk data base
    cmp     r13, r8                     ; mark ptr below data?
    jb      .bad                        ; invalid mark -> fail
    mov     r9, r8                      ; r9 = data base
    add     r9, [r12+C_CAP]             ; r9 = data + cap
    cmp     r13, r9                     ; mark ptr above cap?
    ja      .bad                        ; invalid mark -> fail
    mov     r14, [rsi+16]               ; r14 = target used
    ; ---- free every chunk newer than the mark ----
    mov     rax, [rbx+A_CUR]            ; free chunks newer than r12
    mov     r15, [rbx+A_FREE]           ; r15 = free callback
.free_loop:
    cmp     rax, r12                    ; reached the mark chunk?
    je      .freed                      ; yes -> stop freeing
    mov     rcx, [rax+C_NEXT]           ; rcx = older chunk link
    push    rcx                         ; preserve list links across the call
    push    rax                         ; preserve the chunk across the call
    mov     rdx, [rax+C_CAP]            ; rdx = chunk capacity
    sub     [rbx+A_TOTAL], rdx          ; total -= cap
    test    r15, r15                    ; free callback set?
    jz      .no_free                    ; no -> skip release
    mov     rdi, [rax+C_RAW]            ; arg1 = raw base
    mov     rsi, [rax+C_BSIZE]          ; arg2 = backing size
    mov     rdx, [rbx+A_CTX]            ; arg3 = ctx
    call    r15                         ; free the chunk
.no_free:
    pop     rax                         ; restore the chunk
    pop     rcx                         ; restore the next link
    mov     rax, rcx                    ; advance to next older chunk
    jmp     .free_loop                  ; free the rest
.freed:
    ; ---- restore the marked position ----
    mov     [rbx+A_CUR], r12            ; restore the mark position
    mov     [rbx+A_PTR], r13            ; ptr = mark position
    mov     rax, [r12+C_DATA]           ; rax = chunk data base
    add     rax, [r12+C_CAP]            ; rax = data + cap
    mov     [rbx+A_END], rax            ; end = chunk end
    mov     [rbx+A_USED], r14           ; used = mark used
    xor     eax, eax                    ; return 0 (success)
    jmp     .done                       ; epilogue
    ; ---- invalid mark -> -1 ----
.bad:
    mov     eax, -1                     ; return -1 (invalid mark)
    ; ---- epilogue ----
.done:
    pop     r15                         ; restore free callback
    pop     r14                         ; restore mark used
    pop     r13                         ; restore mark ptr
    pop     r12                         ; restore mark chunk
    pop     rbx                         ; restore a
    ret                                 ; return

;==============================================================================
; void asm_arena_reset(asm_arena *a)
;------------------------------------------------------------------------------
; Releases all chunks except the first and rewinds to its start. O(chunks).
;
; Parameters (System V AMD64 ABI):
;   rdi = a (asm_arena *)  - arena to reset
; Returns:
;   rax = unused (void)
; Uses / clobbers:
;   Reads rdi; writes rax, rcx, rdx. Pushes/restores rbx and r12-r15.
;   Calls the arena's free callback for every chunk after the first.
;==============================================================================
global asm_arena_reset:function
asm_arena_reset:
    ; ---- prologue: preserve callee-saved registers ----
    push    rbx                         ; preserve callee-saved registers
    push    r12                         ; save first chunk
    push    r13                         ; save scratch
    push    r14                         ; save scratch
    push    r15                         ; save free callback
    mov     rbx, rdi                    ; rbx = a
    ; ---- start from the first chunk ----
    mov     r12, [rbx+A_FIRST]          ; r12 = first chunk
    test    r12, r12                    ; first chunk exists?
    jz      .zero_stats                 ; growable arena with no chunk yet
    mov     rax, [rbx+A_CUR]            ; free everything after the first
    mov     r15, [rbx+A_FREE]           ; r15 = free callback
    ; ---- free every chunk newer than the first ----
.free_loop:
    cmp     rax, r12                    ; reached the first chunk?
    je      .freed                      ; yes -> stop freeing
    mov     rcx, [rax+C_NEXT]           ; rcx = older chunk link
    push    rcx                         ; preserve the next link
    push    rax                         ; preserve the chunk
    mov     rdx, [rax+C_CAP]            ; rdx = chunk capacity
    sub     [rbx+A_TOTAL], rdx          ; total -= cap
    test    r15, r15                    ; free callback set?
    jz      .no_free                    ; no -> skip release
    mov     rdi, [rax+C_RAW]            ; arg1 = raw base
    mov     rsi, [rax+C_BSIZE]          ; arg2 = backing size
    mov     rdx, [rbx+A_CTX]            ; arg3 = ctx
    call    r15                         ; free the chunk
.no_free:
    pop     rax                         ; restore the chunk
    pop     rcx                         ; restore the next link
    mov     rax, rcx                    ; advance to next older chunk
    jmp     .free_loop                  ; free the rest
.freed:
    ; ---- rewind to the start of the first chunk ----
    mov     [rbx+A_CUR], r12            ; rewind to the first chunk
    mov     rax, [r12+C_DATA]           ; rax = first chunk data
    mov     [rbx+A_PTR], rax            ; ptr = first chunk data
    mov     rdx, [r12+C_CAP]            ; rdx = first chunk cap
    add     rdx, rax                    ; rdx = data + cap
    mov     [rbx+A_END], rdx            ; end = first chunk end
    mov     rdx, [r12+C_CAP]            ; rdx = first chunk cap
    mov     [rbx+A_TOTAL], rdx          ; total = first chunk cap
    ; ---- clear the statistics ----
.zero_stats:
    mov     qword [rbx+A_USED], 0       ; used = 0
    mov     qword [rbx+A_PEAK], 0       ; peak = 0
    ; ---- epilogue: restore callee-saved registers ----
    pop     r15                         ; restore free callback
    pop     r14                         ; restore scratch
    pop     r13                         ; restore scratch
    pop     r12                         ; restore first chunk
    pop     rbx                         ; restore a
    ret                                 ; return

;==============================================================================
; void asm_arena_destroy(asm_arena *a)
;------------------------------------------------------------------------------
; Releases every chunk (when a free callback is set) and zeroes the arena.
; A fixed arena owns nothing, so only its bookkeeping is cleared.
;
; Parameters (System V AMD64 ABI):
;   rdi = a (asm_arena *)  - arena to destroy
; Returns:
;   rax = unused (void)
; Uses / clobbers:
;   Reads rdi; writes rax, rcx, rdx and zeroes the 88-byte arena. Pushes/restores
;   rbx and r12-r15. Calls the arena's free callback for every chunk.
;==============================================================================
global asm_arena_destroy:function
asm_arena_destroy:
    ; ---- prologue: preserve callee-saved registers ----
    push    rbx                         ; preserve callee-saved registers
    push    r12                         ; save scratch
    push    r13                         ; save scratch
    push    r14                         ; save scratch
    push    r15                         ; save free callback
    mov     rbx, rdi                    ; rbx = a
    mov     r15, [rbx+A_FREE]           ; r15 = free callback
    mov     rax, [rbx+A_CUR]            ; rax = newest chunk
    ; ---- free every chunk in the chain ----
.free_loop:
    test    rax, rax                    ; more chunks?
    jz      .cleared                    ; no -> clear structure
    mov     rcx, [rax+C_NEXT]           ; rcx = older chunk link
    push    rcx                         ; preserve the next link
    push    rax                         ; preserve the chunk
    test    r15, r15                    ; free callback set?
    jz      .no_free                    ; no -> skip release
    mov     rdi, [rax+C_RAW]            ; arg1 = raw base
    mov     rsi, [rax+C_BSIZE]          ; arg2 = backing size
    mov     rdx, [rbx+A_CTX]            ; arg3 = ctx
    call    r15                         ; free the chunk
.no_free:
    pop     rax                         ; restore the chunk
    pop     rcx                         ; restore the next link
    mov     rax, rcx                    ; advance to next older chunk
    jmp     .free_loop                  ; free the rest
    ; ---- zero the arena structure ----
.cleared:
    mov     rdi, rbx                    ; zero the whole structure
    xor     eax, eax                    ; rax = 0
    mov     ecx, A_SIZE / 8             ; ecx = qwords in asm_arena
    rep     stosq                       ; zero the whole structure
    ; ---- epilogue: restore callee-saved registers ----
    pop     r15                         ; restore free callback
    pop     r14                         ; restore scratch
    pop     r13                         ; restore scratch
    pop     r12                         ; restore scratch
    pop     rbx                         ; restore a
    ret                                 ; return

;==============================================================================
; size_t asm_arena_used(const asm_arena *a)
;------------------------------------------------------------------------------
; Bytes handed out since the last reset.
;
; Parameters (System V AMD64 ABI):
;   rdi = a (const asm_arena *)  - arena to query
; Returns:
;   rax = a->used
; Uses / clobbers:
;   Reads rdi; writes rax. No callee-saved registers used.
;==============================================================================
global asm_arena_used:function
asm_arena_used:
    ; ---- load the counter ----
    mov     rax, [rdi+A_USED]           ; return a->used
    ret                                 ; return

;==============================================================================
; size_t asm_arena_peak(const asm_arena *a)
;------------------------------------------------------------------------------
; High-water mark of asm_arena_used() since the last reset.
;
; Parameters (System V AMD64 ABI):
;   rdi = a (const asm_arena *)  - arena to query
; Returns:
;   rax = a->peak
; Uses / clobbers:
;   Reads rdi; writes rax. No callee-saved registers used.
;==============================================================================
global asm_arena_peak:function
asm_arena_peak:
    ; ---- load the high-water mark ----
    mov     rax, [rdi+A_PEAK]           ; return a->peak
    ret                                 ; return

;==============================================================================
; size_t asm_arena_remaining(const asm_arena *a)
;------------------------------------------------------------------------------
; Free bytes left in the current chunk.
;
; Parameters (System V AMD64 ABI):
;   rdi = a (const asm_arena *)  - arena to query
; Returns:
;   rax = a->end - a->ptr
; Uses / clobbers:
;   Reads rdi; writes rax. No callee-saved registers used.
;==============================================================================
global asm_arena_remaining:function
asm_arena_remaining:
    ; ---- remaining = end - ptr ----
    mov     rax, [rdi+A_END]            ; rax = a->end
    sub     rax, [rdi+A_PTR]            ; rax = end - ptr
    ret                                 ; return remaining bytes

;==============================================================================
; size_t asm_arena_capacity(const asm_arena *a)
;------------------------------------------------------------------------------
; Total usable bytes currently backed by all chunks.
;
; Parameters (System V AMD64 ABI):
;   rdi = a (const asm_arena *)  - arena to query
; Returns:
;   rax = a->total
; Uses / clobbers:
;   Reads rdi; writes rax. No callee-saved registers used.
;==============================================================================
global asm_arena_capacity:function
asm_arena_capacity:
    ; ---- load the total capacity ----
    mov     rax, [rdi+A_TOTAL]          ; return a->total
    ret                                 ; return

GNU_STACK_NOTE
