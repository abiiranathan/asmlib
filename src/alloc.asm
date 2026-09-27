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

%define SMALL_TOTAL_MAX 4096            ; header + payload <= this stays "small"
%define RUN_SIZE        65536           ; target bytes per slab run
%define HDR             16              ; per-block header size
%define NUM_CLASSES     512             ; max class index = 4096/16 = 256

section .bss
align 64
malloc_freelist: resq NUM_CLASSES       ; one singly-linked list per size class

section .text

;==============================================================================
; void *asm_malloc(size_t size)
;------------------------------------------------------------------------------
; Returns a 16-byte aligned block of at least size bytes, or NULL.
;==============================================================================
global asm_malloc:function
asm_malloc:
    push    rbx                         ; preserve callee-saved register
    test    rdi, rdi                    ; malloc(0) -> a unique small block
    jnz     .nonzero
    mov     edi, 1
.nonzero:
    mov     rax, rdi                    ; align the payload to 16
    add     rax, 15
    jc      .fail                       ; size overflow
    and     rax, -16
    mov     rcx, rax
    add     rcx, HDR                    ; total = aligned payload + header
    jc      .fail
    cmp     rcx, SMALL_TOTAL_MAX        ; small class?
    ja      .large
    mov     rdx, rcx                    ; class index = total / 16
    shr     rdx, 4
    lea     r9, [rel malloc_freelist]
    mov     rax, [r9+rdx*8]             ; pop the free list
    test    rax, rax
    jz      .run
    mov     r8, [rax]                   ; next
    mov     [r9+rdx*8], r8
    mov     [rax-HDR], rdx              ; stamp the class index
    mov     qword [rax-HDR+8], 0
    jmp     .done
.run:
    mov     rdi, rdx                    ; replenish this class from a new run
    call    L_alloc_run
    jmp     .done
.large:
    mov     rbx, rax                    ; rbx = aligned payload
    add     rbx, HDR
    add     rbx, 4095                   ; page-round the mapping size
    jc      .fail
    and     rbx, -4096
    mov     rdi, rbx
    call    asm_sys_mmap
    test    rax, rax
    jz      .fail
    mov     qword [rax], -1             ; mark as a large mapping
    mov     [rax+8], rbx                ; remember the mapped length
    add     rax, HDR                    ; payload = base + header
.done:
    pop     rbx
    ret
.fail:
    xor     eax, eax
    pop     rbx
    ret

;==============================================================================
; void asm_free(void *ptr)
;------------------------------------------------------------------------------
; Releases a block from asm_malloc (ptr may be NULL). Do not pass pointers
; from any other allocator.
;==============================================================================
global asm_free:function
asm_free:
    test    rdi, rdi
    jz      .ret
    mov     rax, [rdi-HDR]              ; class index, or -1
    cmp     rax, -1
    je      .large
    lea     r9, [rel malloc_freelist]   ; small: push onto its class list
    mov     r8, [r9+rax*8]
    mov     [rdi], r8
    mov     [r9+rax*8], rdi
.ret:
    ret
.large:
    mov     rsi, [rdi-HDR+8]            ; mapped length
    sub     rdi, HDR                    ; mapping base
    jmp     asm_sys_munmap

;==============================================================================
; void *asm_calloc(size_t count, size_t size)
;------------------------------------------------------------------------------
; Allocates count*size zeroed bytes, or NULL on overflow/exhaustion.
;==============================================================================
global asm_calloc:function
asm_calloc:
    push    rbx                         ; preserve callee-saved registers
    push    r12
    push    r13
    mov     rax, rdi                    ; rax = count
    mul     rsi                         ; rdx:rax = count * size
    test    rdx, rdx
    jnz     .fail                       ; product overflowed 64 bits
    mov     rbx, rax                    ; rbx = total bytes
    test    rbx, rbx
    jnz     .go
    mov     ebx, 1
.go:
    mov     rdi, rbx
    call    asm_malloc
    test    rax, rax
    jz      .fail
    mov     r12, rax                    ; keep the block
    mov     rdi, rax
    xor     esi, esi
    mov     rdx, rbx
    call    asm_memset                  ; zero it
    mov     rax, r12
    jmp     .done
.fail:
    xor     eax, eax
.done:
    pop     r13
    pop     r12
    pop     rbx
    ret

;==============================================================================
; void *asm_realloc(void *ptr, size_t size)
;------------------------------------------------------------------------------
; Grows or shrinks a block. Keeps the pointer when the request fits the
; existing usable size, otherwise allocates, copies min(old,new) and frees.
;ptrNULL behaves like asm_malloc(size); size 0 frees and returns NULL.
;==============================================================================
global asm_realloc:function
asm_realloc:
    push    rbx                         ; preserve callee-saved registers
    push    r12
    push    r13
    push    r14
    push    r15
    mov     r12, rdi                    ; r12 = ptr
    mov     r13, rsi                    ; r13 = new size
    test    r12, r12
    jz      .alloc
    test    r13, r13
    jz      .free_null
    mov     rax, [r12-HDR]              ; old usable size
    cmp     rax, -1
    je      .large_old
    shl     rax, 4                      ; class size
    sub     rax, HDR
    jmp     .have_old
.large_old:
    mov     rax, [r12-HDR+8]
    sub     rax, HDR
.have_old:
    mov     r14, rax                    ; r14 = old usable
    mov     rbx, r13                    ; needed payload = align16(new)
    add     rbx, 15
    jc      .fail
    and     rbx, -16
    cmp     rbx, r14                    ; does it fit in place?
    jbe     .inplace
    mov     rdi, r13                    ; allocate a new block
    call    asm_malloc
    test    rax, rax
    jz      .fail
    mov     r15, rax
    mov     rdx, r14                    ; copy min(old usable, new)
    cmp     rdx, r13
    jbe     .copy
    mov     rdx, r13
.copy:
    mov     rdi, r15
    mov     rsi, r12
    call    asm_memcpy
    mov     rdi, r12                    ; release the old block
    call    asm_free
    mov     rax, r15
    jmp     .done
.inplace:
    mov     rax, r12
    jmp     .done
.alloc:
    mov     rdi, r13
    call    asm_malloc
    jmp     .done
.free_null:
    mov     rdi, r12
    call    asm_free
    xor     eax, eax
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
; internal: L_alloc_run(size_t class_index) -> void *block
;------------------------------------------------------------------------------
; Maps a fresh run, threads every block onto the class free list and returns
; one block (or NULL). The run memory is retained for later reuse.
;==============================================================================
L_alloc_run:
    push    rbx                         ; preserve callee-saved registers
    push    r12
    push    r13
    push    r14
    push    r15
    mov     r12, rdi                    ; r12 = class index
    mov     r13, r12
    shl     r13, 4                      ; r13 = class size
    mov     r14, RUN_SIZE
    mov     rax, r13
    shl     rax, 2                      ; run size = max(RUN_SIZE, 4*class)
    cmp     rax, r14
    cmova   r14, rax
    mov     rdi, r14
    call    asm_sys_mmap
    test    rax, rax
    jz      .fail
    mov     rbx, rax                    ; rbx = run base
    mov     rax, r14                    ; nblocks = run_size / class_size
    xor     edx, edx
    div     r13
    test    rax, rax
    jz      .fail
    mov     r15, rax                    ; r15 = block count
    lea     r9, [rel malloc_freelist]
    xor     rcx, rcx                    ; block counter
    mov     rdx, rbx                    ; current block
.link:
    lea     rax, [rdx+HDR]              ; payload
    mov     r8, [r9+r12*8]              ; link onto the free list
    mov     [rax], r8
    mov     [r9+r12*8], rax
    add     rdx, r13                    ; next block
    inc     rcx
    cmp     rcx, r15
    jb      .link
    mov     rax, [r9+r12*8]             ; pop one for the caller
    mov     rcx, [rax]
    mov     [r9+r12*8], rcx
    mov     [rax-HDR], r12              ; stamp its class
    mov     qword [rax-HDR+8], 0
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

GNU_STACK_NOTE
