;==============================================================================
; alloc.asm - malloc/calloc/realloc/free backed directly by mmap
;------------------------------------------------------------------------------
; A compact segregated free-list allocator with no libc dependency:
;
;   void *asm_malloc (size_t size);
;   void *asm_calloc (size_t count, size_t size);
;   void *asm_realloc(void *ptr, size_t size);
;   void  asm_free   (void *ptr);
;   void *asm_reallocarray(void *ptr, size_t count, size_t size);
;   void *asm_aligned_alloc(size_t alignment, size_t size);
;   int   asm_posix_memalign(void **memptr, size_t alignment, size_t size);
;   size_t asm_malloc_usable_size(void *ptr);
;
; Strategy
; --------
; * Requests up to ASM_MALLOC_SMALL_MAX usable bytes are rounded up to a
;   16-byte class and served from a per-class free list. An empty class is
;   replenished by mapping a "run" and pushing every block in it onto the
;   free list (a slab). Freed blocks go straight back onto their class list.
; * Larger requests get their own page-rounded anonymous mapping, stored with
;   its length so asm_free can munmap it exactly.
; * Every returned pointer is 16-byte aligned. Blocks carry a 16-byte header
;   immediately before the payload holding the class index (-1 for a large
;   mapping, -2 for an aligned/indirect block) and, for large blocks, the
;   mapped size. An indirect header stores the backing asm_malloc block so the
;   over-aligned pointer frees exactly what it borrowed.
; * Over-aligned requests bigger than 16 bytes are satisfied by allocating a
;   backing block with room for the alignment slack, then stamping an indirect
;   header in front of the aligned payload.
;
; The heap is thread-safe via a single global spinlock (malloc_lock) that
; serialises every free-list and header update, so concurrent callers can share
; one address space. It is not async-signal-safe: do not call these routines
; from a signal handler that may interrupt an allocation on the same thread.
; Small-run memory is never returned to the kernel (like a slab); large blocks
; are. That matches the usual malloc workhorse pattern while staying small and
; dependency free.
;==============================================================================

BITS 64
default rel

%include "common.inc"

extern asm_memset
extern asm_memcpy
extern asm_sys_mmap
extern asm_sys_munmap

%define SMALL_TOTAL_MAX 4096            ; size_t SMALL_TOTAL_MAX - header+payload at or below stays small
%define RUN_SIZE        65536           ; size_t RUN_SIZE - target bytes per slab run
%define HDR             16              ; size_t HDR - per-block header size in bytes
%define NUM_CLASSES     512             ; size_t NUM_CLASSES - free-list slots (max class index 256)
%define INDIRECT        (-2)            ; size_t INDIRECT - aligned/indirect block marker
%define SIZE_MAX        (-1)            ; size_t SIZE_MAX - largest representable size_t

section .bss
align 64
malloc_freelist: resq NUM_CLASSES       ; one singly-linked list per size class
align 64
malloc_lock:     resd 1                 ; global spinlock: 0 = free, 1 = held

section .text

;==============================================================================
; internal: L_malloc(size_t size) -> void *
;------------------------------------------------------------------------------
; Unlocked core of asm_malloc. Returns a 16-byte aligned block of at least
; size bytes, or NULL. Callers must already hold malloc_lock.
;
; Parameters (System V AMD64 ABI):
;   rdi = size (size_t)  - requested payload size (0 is treated as 1)
; Returns:
;   rax = payload pointer, or NULL on overflow or mmap failure
; Uses / clobbers:
;   Reads rdi; writes rax, rcx, rdx, r8, r9. Pushes/restores rbx.
;   Calls L_alloc_run for small blocks and asm_sys_mmap for large ones.
;==============================================================================
L_malloc:
    ; ---- prologue: preserve callee-saved register ----
    push    rbx                         ; preserve callee-saved register
    ; ---- normalise a zero-size request ----
    test    rdi, rdi                    ; malloc(0) -> a unique small block
    jnz     .nonzero                    ; size != 0 -> keep it
    mov     edi, 1                      ; treat malloc(0) as 1 byte
.nonzero:
    ; ---- size the payload and derive the class ----
    mov     rax, rdi                    ; align the payload to 16
    add     rax, 15                     ; rax = size + 15 (round-up bias)
    jc      .fail                       ; size overflow
    and     rax, -16                    ; rax = 16-aligned payload
    mov     rcx, rax                    ; rcx = aligned payload
    add     rcx, HDR                    ; total = aligned payload + header
    jc      .fail                       ; total overflow -> fail
    cmp     rcx, SMALL_TOTAL_MAX        ; small class?
    ja      .large                      ; header + payload > small max -> large
    ; ---- small class: pop from its free list ----
    mov     rdx, rcx                    ; class index = total / 16
    shr     rdx, 4                      ; class index = total / 16
    lea     r9, [rel malloc_freelist]   ; r9 = free-list base
    mov     rax, [r9+rdx*8]             ; pop the free list
    test    rax, rax                    ; free list empty?
    jz      .run                        ; empty -> replenish from a run
    mov     r8, [rax]                   ; next
    mov     [r9+rdx*8], r8              ; class head = next block
    mov     [rax-HDR], rdx              ; stamp the class index
    mov     qword [rax-HDR+8], 0        ; clear large-size slot in header
    jmp     .done                       ; return the popped block
    ; ---- small class: replenish from a new run ----
.run:
    mov     rdi, rdx                    ; replenish this class from a new run
    call    L_alloc_run                 ; replenish the class and pop one
    jmp     .done                       ; return the block from the run
    ; ---- large: page-rounded anonymous mapping ----
.large:
    mov     rbx, rax                    ; rbx = aligned payload
    add     rbx, HDR                    ; rbx = base + header
    add     rbx, 4095                   ; page-round the mapping size
    jc      .fail                       ; round-up overflow -> fail
    and     rbx, -4096                  ; page-round the mapping size
    mov     rdi, rbx                    ; arg1 = mapping size
    call    asm_sys_mmap                ; map the large block
    test    rax, rax                    ; mapping succeeded?
    jz      .fail                       ; mmap failed -> fail
    mov     qword [rax], -1             ; mark as a large mapping
    mov     [rax+8], rbx                ; remember the mapped length
    add     rax, HDR                    ; payload = base + header
    ; ---- epilogue ----
.done:
    pop     rbx                         ; restore callee-saved register
    ret                                 ; return the block
    ; ---- failure path ----
.fail:
    xor     eax, eax                    ; rax = NULL (failure)
    pop     rbx                         ; restore callee-saved register
    ret                                 ; return NULL

;==============================================================================
; void *asm_malloc(size_t size)
;------------------------------------------------------------------------------
; Thread-safe front end: holds malloc_lock for the whole of L_malloc.
;
; Parameters (System V AMD64 ABI):
;   rdi = size (size_t)  - requested payload size
; Returns:
;   rax = payload pointer, or NULL
;==============================================================================
global asm_malloc:function
asm_malloc:
    push    rbx                         ; preserve callee-saved + keep rsp aligned
    call    L_lock                      ; enter the critical section
    call    L_malloc                    ; allocate under the lock
    mov     rbx, rax                    ; stash the result across the unlock
    call    L_unlock                    ; leave the critical section
    mov     rax, rbx                    ; restore the result
    pop     rbx                         ; restore callee-saved register
    ret                                 ; return the block

;==============================================================================
; internal: L_free(void *ptr) -> void
;------------------------------------------------------------------------------
; Unlocked core of asm_free. Releases a block from asm_malloc (ptr may be NULL).
; Callers must already hold malloc_lock.
;
; Parameters (System V AMD64 ABI):
;   rdi = ptr (void *)  - block previously returned by asm_malloc
; Returns:
;   rax = unused (void)
; Uses / clobbers:
;   Reads rdi; writes rax, r8, r9. Small blocks are pushed back on their class
;   list; large blocks call asm_sys_munmap under the lock; indirect
;   (over-aligned) blocks recurse into L_free on their backing block. No
;   callee-saved registers used.
;==============================================================================
L_free:
    ; ---- NULL is a no-op ----
    test    rdi, rdi                    ; ptr == NULL?
    jz      .ret                        ; free(NULL) is a no-op
    ; ---- recover the class index from the header ----
    mov     rax, [rdi-HDR]              ; class index, -1 or -2
    cmp     rax, -1                     ; large mapping marker?
    je      .large                      ; yes -> munmap it
    cmp     rax, INDIRECT               ; aligned/indirect marker?
    je      .indirect                   ; yes -> release the backing block
    ; ---- small: push the block onto its class list ----
    lea     r9, [rel malloc_freelist]   ; small: push onto its class list
    mov     r8, [r9+rax*8]              ; r8 = old list head
    mov     [rdi], r8                   ; block->next = old head
    mov     [r9+rax*8], rdi             ; class head = this block
.ret:
    ret                                 ; return (small block recycled)
    ; ---- indirect: free the backing block instead ----
.indirect:
    mov     rdi, [rdi-HDR+8]            ; rdi = orig backing block
    test    rdi, rdi                    ; orig == NULL?
    jz      .ret                        ; nothing to release
    sub     rsp, 8                      ; keep rsp 16-byte aligned for the call
    call    L_free                      ; recurse (orig is never indirect)
    add     rsp, 8                      ; restore the stack
    ret                                 ; return
    ; ---- large: unmap the whole mapping ----
.large:
    mov     rsi, [rdi-HDR+8]            ; mapped length
    sub     rdi, HDR                    ; mapping base
    sub     rsp, 8                      ; keep rsp 16-byte aligned for the call
    call    asm_sys_munmap              ; release the mapping (under the lock)
    add     rsp, 8                      ; restore the stack
    ret                                 ; return

;==============================================================================
; void asm_free(void *ptr)
;------------------------------------------------------------------------------
; Thread-safe front end: holds malloc_lock around L_free.
;
; Parameters (System V AMD64 ABI):
;   rdi = ptr (void *)  - block previously returned by asm_malloc
; Returns:
;   rax = unused (void)
;==============================================================================
global asm_free:function
asm_free:
    push    rbx                         ; preserve callee-saved + keep rsp aligned
    call    L_lock                      ; enter the critical section
    call    L_free                      ; release under the lock
    call    L_unlock                    ; leave the critical section
    pop     rbx                         ; restore callee-saved register
    ret                                 ; return

;==============================================================================
; void *asm_calloc(size_t count, size_t size)
;------------------------------------------------------------------------------
; Allocates count*size zeroed bytes, or NULL on overflow/exhaustion.
;
; Parameters (System V AMD64 ABI):
;   rdi = count (size_t)  - element count
;   rsi = size (size_t)  - element size in bytes
; Returns:
;   rax = zeroed block, or NULL on overflow or allocation failure
; Uses / clobbers:
;   Reads rdi, rsi; writes rax, rdx. Pushes/restores rbx, r12, r13.
;   Calls L_malloc under the lock, then asm_memset outside it.
;==============================================================================
global asm_calloc:function
asm_calloc:
    ; ---- prologue: preserve callee-saved registers ----
    push    rbx                         ; preserve callee-saved registers
    push    r12                         ; save block
    push    r13                         ; save scratch
    ; ---- count * size with overflow check ----
    mov     rax, rdi                    ; rax = count
    mul     rsi                         ; rdx:rax = count * size
    test    rdx, rdx                    ; product high half == 0?
    jnz     .fail                       ; product overflowed 64 bits
    mov     rbx, rax                    ; rbx = total bytes
    test    rbx, rbx                    ; count*size == 0?
    jnz     .go                         ; non-zero -> allocate as is
    mov     ebx, 1                      ; treat zero request as 1 byte
.go:
    ; ---- allocate under the lock ----
    call    L_lock                      ; enter the critical section
    mov     rdi, rbx                    ; arg1 = total bytes
    call    L_malloc                    ; allocate the block
    mov     r12, rax                    ; keep the block
    call    L_unlock                    ; leave the critical section
    ; ---- zero the block outside the lock (it is on no free list) ----
    test    r12, r12                    ; allocation succeeded?
    jz      .fail                       ; failed -> return NULL
    mov     rdi, r12                    ; arg1 = block
    xor     esi, esi                    ; fill byte = 0
    mov     rdx, rbx                    ; arg3 = total bytes
    call    asm_memset                  ; zero it
    mov     rax, r12                    ; return the block
    ; ---- epilogue ----
    jmp     .done                       ; epilogue
    ; ---- failure path ----
.fail:
    xor     eax, eax                    ; rax = NULL (failure)
.done:
    pop     r13                         ; restore scratch
    pop     r12                         ; restore block
    pop     rbx                         ; restore total
    ret                                 ; return

;==============================================================================
; internal: L_realloc(void *ptr, size_t size) -> void *
;------------------------------------------------------------------------------
; Unlocked core of asm_realloc. Grows or shrinks a block. Keeps the pointer
; when the request fits the existing usable size, otherwise allocates, copies
; min(old,new) and frees. Over-aligned (indirect) blocks always move through
; L_malloc. ptr NULL behaves like L_malloc(size); size 0 frees and returns
; NULL. Callers must already hold malloc_lock.
;
; Parameters (System V AMD64 ABI):
;   rdi = ptr (void *)  - existing block, or NULL
;   rsi = size (size_t)  - requested new payload size
; Returns:
;   rax = resized block, or NULL on overflow or allocation failure
; Uses / clobbers:
;   Reads rdi, rsi; writes rax, rdx. Pushes/restores rbx and r12-r15.
;   Calls L_malloc, L_usable_size, asm_memcpy and L_free.
;==============================================================================
L_realloc:
    ; ---- prologue: preserve callee-saved registers ----
    push    rbx                         ; preserve callee-saved registers
    push    r12                         ; save ptr
    push    r13                         ; save new size
    push    r14                         ; save old usable size
    push    r15                         ; save new block
    ; ---- handle NULL and zero-size special cases ----
    mov     r12, rdi                    ; r12 = ptr
    mov     r13, rsi                    ; r13 = new size
    test    r12, r12                    ; ptr == NULL?
    jz      .alloc                      ; realloc(NULL, n) == malloc(n)
    test    r13, r13                    ; new size == 0?
    jz      .free_null                  ; realloc(p, 0) frees p
    ; ---- recover the old usable size from the header ----
    mov     rax, [r12-HDR]              ; class index, -1 or -2
    cmp     rax, -1                     ; large mapping marker?
    je      .large_old                  ; yes -> size stored in header
    cmp     rax, INDIRECT               ; aligned/indirect marker?
    je      .indirect_old               ; yes -> usable comes from the backing block
    shl     rax, 4                      ; class size
    sub     rax, HDR                    ; usable = class_size - header
    jmp     .have_old                   ; old size resolved
.large_old:
    mov     rax, [r12-HDR+8]            ; rax = mapped length
    sub     rax, HDR                    ; usable = mapped - header
.have_old:
    mov     r14, rax                    ; r14 = old usable
    ; ---- size the requested payload ----
    mov     rbx, r13                    ; needed payload = align16(new)
    add     rbx, 15                     ; rbx = new + 15 (round-up bias)
    jc      .fail                       ; overflow -> fail
    and     rbx, -16                    ; rbx = 16-aligned new size
    ; ---- in-place fit check ----
    cmp     rbx, r14                    ; does it fit in place?
    jbe     .inplace                    ; fits in place -> keep pointer
    jmp     .move                       ; no -> move to a new block
    ; ---- indirect: old usable = backing usable - (ptr - orig) ----
.indirect_old:
    mov     rbx, [r12-HDR+8]            ; rbx = orig backing block
    mov     rdi, rbx                    ; arg1 = orig
    call    L_usable_size               ; rax = backing usable
    mov     rcx, r12                    ; rcx = ptr
    sub     rcx, rbx                    ; rcx = ptr - orig (header offset)
    sub     rax, rcx                    ; usable -= the alignment offset
    mov     r14, rax                    ; r14 = old usable
    ; ---- allocate a new block, copy and free the old ----
.move:
    mov     rdi, r13                    ; allocate a new block
    call    L_malloc                    ; allocate the new block
    test    rax, rax                    ; allocation succeeded?
    jz      .fail                       ; failed -> return NULL
    mov     r15, rax                    ; r15 = new block
    mov     rdx, r14                    ; copy min(old usable, new)
    cmp     rdx, r13                    ; old usable <= new size?
    jbe     .copy                       ; yes -> copy old usable bytes
    mov     rdx, r13                    ; else copy new bytes
.copy:
    mov     rdi, r15                    ; arg1 = destination
    mov     rsi, r12                    ; arg2 = source
    call    asm_memcpy                  ; copy the live prefix
    mov     rdi, r12                    ; release the old block
    call    L_free                      ; release the old block
    mov     rax, r15                    ; rax = new block
    jmp     .done                       ; return new block
    ; ---- in place: keep the pointer ----
.inplace:
    mov     rax, r12                    ; rax = ptr (unchanged)
    jmp     .done                       ; return in-place block
.alloc:
    mov     rdi, r13                    ; arg1 = new size
    call    L_malloc                    ; realloc(NULL,n) -> malloc(n)
    jmp     .done                       ; return the new block
    ; ---- zero size: free and return NULL ----
.free_null:
    mov     rdi, r12                    ; arg1 = ptr
    call    L_free                      ; release the block
    xor     eax, eax                    ; rax = NULL
    jmp     .done                       ; return NULL
    ; ---- failure path ----
.fail:
    xor     eax, eax                    ; rax = NULL (failure)
    ; ---- epilogue ----
.done:
    pop     r15                         ; restore new block
    pop     r14                         ; restore old usable size
    pop     r13                         ; restore new size
    pop     r12                         ; restore ptr
    pop     rbx                         ; restore rbx
    ret                                 ; return

;==============================================================================
; void *asm_realloc(void *ptr, size_t size)
;------------------------------------------------------------------------------
; Thread-safe front end: holds malloc_lock for the whole of L_realloc.
;
; Parameters (System V AMD64 ABI):
;   rdi = ptr (void *)  - existing block, or NULL
;   rsi = size (size_t)  - requested new payload size
; Returns:
;   rax = resized block, or NULL
;==============================================================================
global asm_realloc:function
asm_realloc:
    push    rbx                         ; preserve callee-saved + keep rsp aligned
    call    L_lock                      ; enter the critical section
    call    L_realloc                   ; resize under the lock
    mov     rbx, rax                    ; stash the result across the unlock
    call    L_unlock                    ; leave the critical section
    mov     rax, rbx                    ; restore the result
    pop     rbx                         ; restore callee-saved register
    ret                                 ; return the block

;==============================================================================
; void *asm_reallocarray(void *ptr, size_t count, size_t size)
;------------------------------------------------------------------------------
; Overflow-checked asm_realloc. When count != 0 and size > SIZE_MAX/count the
; product would wrap; NULL is returned and ptr is left untouched. Otherwise the
; request is forwarded to the internal L_realloc under a single lock.
;
; Parameters (System V AMD64 ABI):
;   rdi = ptr (void *)  - existing block, or NULL
;   rsi = count (size_t)  - element count
;   rdx = size (size_t)  - element size in bytes
; Returns:
;   rax = resized block, or NULL on overflow or allocation failure
; Uses / clobbers:
;   Reads rdi, rsi, rdx; writes rax, rcx, rdx, r8. Calls L_realloc under the lock.
;==============================================================================
global asm_reallocarray:function
asm_reallocarray:
    ; ---- count == 0: the product is 0 -> realloc(ptr, 0) ----
    test    rsi, rsi                    ; count == 0?
    jz      .zero                       ; yes -> forward a zero-size request
    ; ---- overflow check: size > SIZE_MAX / count ? ----
    mov     r8, rdx                     ; r8 = size
    mov     rax, SIZE_MAX               ; rax = SIZE_MAX (dividend low half)
    xor     edx, edx                    ; rdx = 0 (dividend high half)
    div     rsi                         ; rax = SIZE_MAX / count
    cmp     r8, rax                     ; size > SIZE_MAX / count?
    ja      .overflow                   ; yes -> the product would wrap
    ; ---- product is safe: count * size ----
    mov     rax, rsi                    ; rax = count
    mul     r8                          ; rdx:rax = count * size (high half is 0)
    mov     rsi, rax                    ; arg2 = product
    jmp     .locked                     ; realloc(ptr, product) under the lock
.zero:
    xor     esi, esi                    ; arg2 = 0
.locked:
    ; ---- serialise the resize with the rest of the heap ----
    push    rbx                         ; preserve callee-saved + keep rsp aligned
    call    L_lock                      ; enter the critical section
    call    L_realloc                   ; resize under the lock
    mov     rbx, rax                    ; stash the result across the unlock
    call    L_unlock                    ; leave the critical section
    mov     rax, rbx                    ; restore the result
    pop     rbx                         ; restore callee-saved register
    ret                                 ; return the resized block
.overflow:
    xor     eax, eax                    ; rax = NULL (overflow)
    ret                                 ; return NULL without touching ptr

;==============================================================================
; internal: L_usable_size(void *ptr) -> size_t
;------------------------------------------------------------------------------
; Unlocked core of asm_malloc_usable_size. Usable payload bytes in a block from
; asm_malloc, or 0 for NULL. A small class block reports class*16 - header; a
; large block reports its mapped length minus the header; an over-aligned
; (indirect) block reports its backing block's usable size minus the alignment
; offset. Callers must already hold malloc_lock.
;
; Parameters (System V AMD64 ABI):
;   rdi = ptr (void *)  - block previously returned by asm_malloc, or NULL
; Returns:
;   rax = usable payload bytes, or 0 when ptr is NULL
; Uses / clobbers:
;   Reads rdi; writes rax, rcx, rdx, r8. No callee-saved registers used.
;==============================================================================
L_usable_size:
    ; ---- NULL has no usable bytes ----
    test    rdi, rdi                    ; ptr == NULL?
    jz      .null                       ; yes -> 0
    ; ---- decode the header marker ----
    mov     rax, [rdi-HDR]              ; class index, -1 or -2
    cmp     rax, -1                     ; large mapping marker?
    je      .large                      ; yes -> mapped length stored in header
    cmp     rax, INDIRECT               ; aligned/indirect marker?
    je      .indirect                   ; yes -> ask the backing block
    ; ---- small class: usable = class_size - header ----
    shl     rax, 4                      ; class size
    sub     rax, HDR                    ; minus the block header
    ret                                 ; return usable bytes
.large:
    mov     rax, [rdi-HDR+8]            ; mapped length
    sub     rax, HDR                    ; minus the block header
    ret                                 ; return usable bytes
.indirect:
    ; ---- indirect: backing usable minus the alignment offset ----
    mov     r8, [rdi-HDR+8]             ; r8 = orig backing block
    mov     rax, [r8-HDR]               ; backing class index (never indirect)
    cmp     rax, -1                     ; backing is a large mapping?
    je      .ind_large                  ; yes -> mapped length in header
    shl     rax, 4                      ; backing class size
    sub     rax, HDR                    ; backing usable
    jmp     .ind_sub                    ; apply the alignment offset
.ind_large:
    mov     rax, [r8-HDR+8]             ; backing mapped length
    sub     rax, HDR                    ; backing usable
.ind_sub:
    sub     rdi, r8                     ; rdi = ptr - orig (alignment offset)
    sub     rax, rdi                    ; usable -= offset
    ret                                 ; return usable bytes
.null:
    xor     eax, eax                    ; rax = 0
    ret                                 ; return 0

;==============================================================================
; size_t asm_malloc_usable_size(void *ptr)
;------------------------------------------------------------------------------
; Thread-safe front end: holds malloc_lock while L_usable_size reads the header.
;
; Parameters (System V AMD64 ABI):
;   rdi = ptr (void *)  - block previously returned by asm_malloc, or NULL
; Returns:
;   rax = usable payload bytes, or 0 when ptr is NULL
;==============================================================================
global asm_malloc_usable_size:function
asm_malloc_usable_size:
    push    rbx                         ; preserve callee-saved + keep rsp aligned
    call    L_lock                      ; enter the critical section
    call    L_usable_size               ; read the header under the lock
    mov     rbx, rax                    ; stash the result across the unlock
    call    L_unlock                    ; leave the critical section
    mov     rax, rbx                    ; restore the result
    pop     rbx                         ; restore callee-saved register
    ret                                 ; return usable bytes

;==============================================================================
; internal: L_aligned_alloc(size_t alignment, size_t size) -> void *
;------------------------------------------------------------------------------
; Unlocked core of asm_aligned_alloc. Allocates `size` bytes whose address is a
; multiple of `alignment` (a non-zero power of two), or NULL on invalid
; alignment or allocation failure. C11 would also require size to be a multiple
; of alignment; we deliberately relax that and accept any size. Callers must
; already hold malloc_lock.
;
; Parameters (System V AMD64 ABI):
;   rdi = alignment (size_t)  - required alignment (power of two)
;   rsi = size (size_t)  - requested payload size
; Returns:
;   rax = aligned block, or NULL on invalid alignment or failure
; Uses / clobbers:
;   Reads rdi, rsi; writes rax, rcx, rdx. Pushes/restores rbx and r12, r13.
;   Calls L_malloc.
;==============================================================================
L_aligned_alloc:
    ; ---- validate the alignment (non-zero power of two) ----
    test    rdi, rdi                    ; alignment == 0?
    jz      .bad                        ; invalid -> NULL
    mov     rax, rdi                    ; rax = alignment
    dec     rax                         ; rax = alignment - 1
    test    rdi, rax                    ; more than one bit set?
    jnz     .bad                        ; not a power of two -> NULL
    cmp     rdi, 16                     ; alignment <= 16?
    ja      .big                        ; over-aligned -> indirect block
    ; ---- alignment <= 16: L_malloc is already 16-byte aligned ----
    mov     rdi, rsi                    ; arg1 = size
    jmp     L_malloc                    ; tail-call malloc(size)
    ; ---- over-aligned: carve an indirect block ----
.big:
    ; ---- prologue: preserve callee-saved registers ----
    push    rbx                         ; preserve callee-saved registers
    push    r12                         ; save alignment
    push    r13                         ; save size
    mov     r12, rdi                    ; r12 = alignment
    mov     r13, rsi                    ; r13 = size
    ; ---- total = size + alignment + header (with overflow checks) ----
    mov     rbx, r13                    ; rbx = size
    add     rbx, r12                    ; rbx = size + alignment
    jc      .fail                       ; overflow -> fail
    add     rbx, HDR                    ; rbx = size + alignment + header
    jc      .fail                       ; overflow -> fail
    ; ---- allocate the backing block ----
    mov     rdi, rbx                    ; arg1 = total bytes
    call    L_malloc                    ; orig = malloc(total)
    test    rax, rax                    ; allocation succeeded?
    jz      .fail                       ; failed -> return NULL
    ; ---- p = align_up(orig + header, alignment) ----
    lea     rcx, [rax+HDR]              ; rcx = orig + header
    lea     rdx, [r12-1]                ; rdx = alignment - 1
    add     rcx, rdx                    ; rcx = orig + header + alignment - 1
    not     rdx                         ; rdx = ~(alignment - 1)
    and     rcx, rdx                    ; rcx = align_up(orig + header, alignment)
    ; ---- stamp the indirect header just before p ----
    mov     qword [rcx-HDR], INDIRECT   ; qword0 = indirect marker
    mov     [rcx-HDR+8], rax            ; qword1 = orig backing block
    mov     rax, rcx                    ; rax = aligned payload
    ; ---- epilogue ----
    pop     r13                         ; restore size
    pop     r12                         ; restore alignment
    pop     rbx                         ; restore rbx
    ret                                 ; return aligned block
    ; ---- failure path ----
.fail:
    xor     eax, eax                    ; rax = NULL (failure)
    pop     r13                         ; restore size
    pop     r12                         ; restore alignment
    pop     rbx                         ; restore rbx
    ret                                 ; return NULL
    ; ---- invalid alignment -> NULL ----
.bad:
    xor     eax, eax                    ; rax = NULL (bad alignment)
    ret                                 ; return NULL

;==============================================================================
; void *asm_aligned_alloc(size_t alignment, size_t size)
;------------------------------------------------------------------------------
; Thread-safe front end: holds malloc_lock for the whole of L_aligned_alloc.
;
; Parameters (System V AMD64 ABI):
;   rdi = alignment (size_t)  - required alignment (power of two)
;   rsi = size (size_t)  - requested payload size
; Returns:
;   rax = aligned block, or NULL on invalid alignment or failure
;==============================================================================
global asm_aligned_alloc:function
asm_aligned_alloc:
    push    rbx                         ; preserve callee-saved + keep rsp aligned
    call    L_lock                      ; enter the critical section
    call    L_aligned_alloc             ; allocate under the lock
    mov     rbx, rax                    ; stash the result across the unlock
    call    L_unlock                    ; leave the critical section
    mov     rax, rbx                    ; restore the result
    pop     rbx                         ; restore callee-saved register
    ret                                 ; return the aligned block

;==============================================================================
; int asm_posix_memalign(void **memptr, size_t alignment, size_t size)
;------------------------------------------------------------------------------
; POSIX posix_memalign: stores an `alignment`-aligned block of `size` bytes at
; *memptr and returns 0; returns EINVAL(22) for an alignment that is not a
; power of two or is below sizeof(void*), and ENOMEM(12) on allocation failure.
; *memptr is left untouched on both error paths.
;
; Parameters (System V AMD64 ABI):
;   rdi = memptr (void **)  - out-parameter receiving the block
;   rsi = alignment (size_t)  - required alignment (power of two, >= 8)
;   rdx = size (size_t)  - requested payload size
; Returns:
;   rax = 0 on success, EINVAL(22) on bad alignment, ENOMEM(12) on failure
; Uses / clobbers:
;   Reads rdi, rsi, rdx; writes rax and *memptr. Pushes/restores rbx.
;   Calls L_aligned_alloc under the lock.
;==============================================================================
global asm_posix_memalign:function
asm_posix_memalign:
    ; ---- prologue: preserve the out-parameter ----
    push    rbx                         ; preserve callee-saved register
    mov     rbx, rdi                    ; rbx = memptr
    ; ---- validate the alignment (non-zero power of two, >= sizeof(void*)) ----
    test    rsi, rsi                    ; alignment == 0?
    jz      .einval                     ; invalid -> EINVAL
    mov     rax, rsi                    ; rax = alignment
    dec     rax                         ; rax = alignment - 1
    test    rsi, rax                    ; more than one bit set?
    jnz     .einval                     ; not a power of two -> EINVAL
    cmp     rsi, 8                      ; alignment < sizeof(void*)?
    jb      .einval                     ; too small -> EINVAL
    ; ---- allocate under the lock and hand the block back ----
    call    L_lock                      ; enter the critical section
    mov     rdi, rsi                    ; arg1 = alignment
    mov     rsi, rdx                    ; arg2 = size
    call    L_aligned_alloc             ; p = aligned_alloc(align, size)
    test    rax, rax                    ; allocation succeeded?
    jz      .enomem                     ; failed -> release the lock, ENOMEM
    mov     [rbx], rax                  ; *memptr = p (only on success)
    call    L_unlock                    ; leave the critical section
    xor     eax, eax                    ; return 0 (success)
    pop     rbx                         ; restore out-parameter
    ret                                 ; return 0
    ; ---- invalid alignment -> EINVAL (no lock taken) ----
.einval:
    mov     eax, 22                     ; EINVAL
    pop     rbx                         ; restore out-parameter
    ret                                 ; return EINVAL
    ; ---- allocation failure -> ENOMEM (lock held) ----
.enomem:
    call    L_unlock                    ; leave the critical section
    mov     eax, 12                     ; ENOMEM
    pop     rbx                         ; restore out-parameter
    ret                                 ; return ENOMEM

;==============================================================================
; internal: L_alloc_run(size_t class_index) -> void *block
;------------------------------------------------------------------------------
; Maps a fresh run, threads every block onto the class free list and returns
; one block (or NULL). The run memory is retained for later reuse.
;
; Parameters (System V AMD64 ABI):
;   rdi = class_index (size_t)  - size class whose free list is replenished
; Returns:
;   rax = one block from the new run, or NULL on mmap failure
; Uses / clobbers:
;   Reads rdi; writes rax, rcx, rdx, r9. Pushes/restores rbx and r12-r15.
;   Calls asm_sys_mmap.
;==============================================================================
L_alloc_run:
    ; ---- prologue: preserve callee-saved registers ----
    push    rbx                         ; preserve callee-saved registers
    push    r12                         ; save class index
    push    r13                         ; save class size
    push    r14                         ; save run size
    push    r15                         ; save block count
    ; ---- derive the class size and run size ----
    mov     r12, rdi                    ; r12 = class index
    mov     r13, r12                    ; r13 = class index
    shl     r13, 4                      ; r13 = class size
    mov     r14, RUN_SIZE               ; r14 = target run size
    mov     rax, r13                    ; rax = class size
    shl     rax, 2                      ; run size = max(RUN_SIZE, 4*class)
    cmp     rax, r14                    ; 4*class > RUN_SIZE?
    cmova   r14, rax                    ; r14 = max(RUN_SIZE, 4*class)
    ; ---- map the run ----
    mov     rdi, r14                    ; arg1 = run size
    call    asm_sys_mmap                ; map the run
    test    rax, rax                    ; mapping succeeded?
    jz      .fail                       ; mmap failed -> fail
    ; ---- compute how many blocks fit ----
    mov     rbx, rax                    ; rbx = run base
    mov     rax, r14                    ; nblocks = run_size / class_size
    xor     edx, edx                    ; clear rdx for division
    div     r13                         ; rax = run_size / class_size
    test    rax, rax                    ; at least one block?
    jz      .fail                       ; zero blocks -> fail
    mov     r15, rax                    ; r15 = block count
    lea     r9, [rel malloc_freelist]   ; r9 = free-list base
    xor     rcx, rcx                    ; block counter
    mov     rdx, rbx                    ; current block
    ; ---- thread every block onto the class free list ----
.link:
    lea     rax, [rdx+HDR]              ; payload
    mov     r8, [r9+r12*8]              ; link onto the free list
    mov     [rax], r8                   ; block->next = old head
    mov     [r9+r12*8], rax             ; class head = this block
    add     rdx, r13                    ; next block
    inc     rcx                         ; ++block counter
    cmp     rcx, r15                    ; threaded every block?
    jb      .link                       ; no -> thread the next
    ; ---- pop one block for the caller ----
    mov     rax, [r9+r12*8]             ; pop one for the caller
    mov     rcx, [rax]                  ; rcx = next block
    mov     [r9+r12*8], rcx             ; class head = remainder
    mov     [rax-HDR], r12              ; stamp its class
    mov     qword [rax-HDR+8], 0        ; clear large-size slot
    ; ---- epilogue: return the block ----
    pop     r15                         ; restore block count
    pop     r14                         ; restore run size
    pop     r13                         ; restore class size
    pop     r12                         ; restore class index
    pop     rbx                         ; restore rbx
    ret                                 ; return the block
    ; ---- failure path ----
.fail:
    xor     eax, eax                    ; rax = NULL (failure)
    pop     r15                         ; restore block count
    pop     r14                         ; restore run size
    pop     r13                         ; restore class size
    pop     r12                         ; restore class index
    pop     rbx                         ; restore rbx
    ret                                 ; return NULL

;==============================================================================
; internal: L_lock(void) -> void
;------------------------------------------------------------------------------
; Acquires malloc_lock, spinning until it observes the lock free. xchg with a
; memory operand is implicitly locked, so the test-and-set is atomic. Clobbers
; eax only (and flags), so argument registers survive the call.
;==============================================================================
L_lock:
    mov     eax, 1                      ; value to store into the lock
.retry:
    xchg    eax, [rel malloc_lock]      ; atomically swap in "held"
    test    eax, eax                    ; was it already held?
    jz      .got                        ; no -> we own it
    pause                               ; spin hint while contended
    mov     eax, 1                      ; reload for the next attempt
    jmp     .retry                      ; try again
.got:
    ret                                 ; lock acquired

;==============================================================================
; internal: L_unlock(void) -> void
;------------------------------------------------------------------------------
; Releases malloc_lock. A plain store is enough because the lock only guards
; data touched while a caller holds the lock. Clobbers no registers.
;==============================================================================
L_unlock:
    mov     dword [rel malloc_lock], 0  ; mark the lock free
    ret                                 ; return

GNU_STACK_NOTE
