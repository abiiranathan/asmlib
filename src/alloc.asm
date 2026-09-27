;==============================================================================
; alloc.asm - malloc/calloc/realloc/free backed directly by mmap
;------------------------------------------------------------------------------
; A compact segregated free-list allocator with no libc dependency:
;
;   void *asm_malloc (size_t size);
;   void *asm_calloc (size_t count, size_t size);
;   void *asm_realloc(void *ptr, size_t size);
;   void  asm_free   (void *ptr);
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
;   immediately before the payload holding the class index (or -1 for a large
;   mapping) and, for large blocks, the mapped size.
;
; The allocator is single-threaded and never returns small-run memory to the
; kernel (like a slab); large blocks are returned. That matches the usual
; malloc workhorse pattern while staying small and dependency free.
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

section .bss
align 64
malloc_freelist: resq NUM_CLASSES       ; one singly-linked list per size class

section .text

;==============================================================================
; void *asm_malloc(size_t size)
;------------------------------------------------------------------------------
; Returns a 16-byte aligned block of at least size bytes, or NULL.
;
; Parameters (System V AMD64 ABI):
;   rdi = size (size_t)  - requested payload size (0 is treated as 1)
; Returns:
;   rax = payload pointer, or NULL on overflow or mmap failure
; Uses / clobbers:
;   Reads rdi; writes rax, rcx, rdx, r8, r9. Pushes/restores rbx.
;   Calls L_alloc_run for small blocks and asm_sys_mmap for large ones.
;==============================================================================
global asm_malloc:function
asm_malloc:
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
; void asm_free(void *ptr)
;------------------------------------------------------------------------------
; Releases a block from asm_malloc (ptr may be NULL). Do not pass pointers
; from any other allocator.
;
; Parameters (System V AMD64 ABI):
;   rdi = ptr (void *)  - block previously returned by asm_malloc
; Returns:
;   rax = unused (void)
; Uses / clobbers:
;   Reads rdi; writes rax, r8, r9. Small blocks are pushed back on their class
;   list; large blocks tail-call asm_sys_munmap. No callee-saved registers used.
;==============================================================================
global asm_free:function
asm_free:
    ; ---- NULL is a no-op ----
    test    rdi, rdi                    ; ptr == NULL?
    jz      .ret                        ; free(NULL) is a no-op
    ; ---- recover the class index from the header ----
    mov     rax, [rdi-HDR]              ; class index, or -1
    cmp     rax, -1                     ; large mapping marker?
    je      .large                      ; yes -> munmap it
    ; ---- small: push the block onto its class list ----
    lea     r9, [rel malloc_freelist]   ; small: push onto its class list
    mov     r8, [r9+rax*8]              ; r8 = old list head
    mov     [rdi], r8                   ; block->next = old head
    mov     [r9+rax*8], rdi             ; class head = this block
.ret:
    ret                                 ; return (small block recycled)
    ; ---- large: unmap the whole mapping ----
.large:
    mov     rsi, [rdi-HDR+8]            ; mapped length
    sub     rdi, HDR                    ; mapping base
    jmp     asm_sys_munmap              ; tail-call munmap(base, length)

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
;   Calls asm_malloc and asm_memset.
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
    ; ---- allocate and zero the block ----
    mov     rdi, rbx                    ; arg1 = total bytes
    call    asm_malloc                  ; allocate the block
    test    rax, rax                    ; allocation succeeded?
    jz      .fail                       ; failed -> return NULL
    mov     r12, rax                    ; keep the block
    mov     rdi, rax                    ; arg1 = block
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
; void *asm_realloc(void *ptr, size_t size)
;------------------------------------------------------------------------------
; Grows or shrinks a block. Keeps the pointer when the request fits the
; existing usable size, otherwise allocates, copies min(old,new) and frees.
;ptrNULL behaves like asm_malloc(size); size 0 frees and returns NULL.
;
; Parameters (System V AMD64 ABI):
;   rdi = ptr (void *)  - existing block, or NULL
;   rsi = size (size_t)  - requested new payload size
; Returns:
;   rax = resized block, or NULL on overflow or allocation failure
; Uses / clobbers:
;   Reads rdi, rsi; writes rax, rdx. Pushes/restores rbx and r12-r15.
;   Calls asm_malloc, asm_memcpy and asm_free.
;==============================================================================
global asm_realloc:function
asm_realloc:
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
    mov     rax, [r12-HDR]              ; old usable size
    cmp     rax, -1                     ; large mapping marker?
    je      .large_old                  ; yes -> size stored in header
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
    ; ---- allocate a new block, copy and free the old ----
    mov     rdi, r13                    ; allocate a new block
    call    asm_malloc                  ; allocate the new block
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
    call    asm_free                    ; release the old block
    mov     rax, r15                    ; rax = new block
    jmp     .done                       ; return new block
    ; ---- in place: keep the pointer ----
.inplace:
    mov     rax, r12                    ; rax = ptr (unchanged)
    jmp     .done                       ; return in-place block
.alloc:
    mov     rdi, r13                    ; arg1 = new size
    call    asm_malloc                  ; realloc(NULL,n) -> malloc(n)
    jmp     .done                       ; return the new block
    ; ---- zero size: free and return NULL ----
.free_null:
    mov     rdi, r12                    ; arg1 = ptr
    call    asm_free                    ; release the block
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

GNU_STACK_NOTE
