;==============================================================================
; sys.asm - thin raw-syscall wrappers (Linux x86-64) for the OS allocators
;------------------------------------------------------------------------------
; These are the only platform-specific routines in the library. They give the
; arena and the malloc-style allocator a way to obtain memory from the kernel
; without any libc involvement:
;
;   void *asm_sys_mmap  (size_t size);                 -> page-aligned or NULL
;   int   asm_sys_munmap(void *ptr, size_t size);      -> 0 or -errno
;   void *asm_sys_alloc (size_t size, void *ctx);      -> arena alloc callback
;   void  asm_sys_free  (void *ptr, size_t size, void *ctx); arena free callback
;
; The kernel preserves the callee-saved registers across `syscall`; rcx and
; r11 are clobbered (both caller-saved), so no extra saving is needed here.
; On a non-Linux or freestanding target these two primitives are replaced by
; the caller's own allocator passed to asm_arena_init_grow().
;==============================================================================

BITS 64
default rel

%include "common.inc"

%define SYS_mmap    9                   ; mmap(addr, len, prot, flags, fd, off)
%define SYS_munmap  11                  ; munmap(addr, len)
%define PROT_RW     3                   ; PROT_READ | PROT_WRITE
%define MAP_ANON_PRIV 0x22              ; MAP_PRIVATE | MAP_ANONYMOUS
%define ERR_LIMIT   (-4095)             ; values in [-4095,-1] encode -errno

section .text

;==============================================================================
; void *asm_sys_mmap(size_t size)
;------------------------------------------------------------------------------
; Anonymous private read/write mapping of at least `size` bytes, page aligned,
; zero filled. Returns NULL on failure (errno is not exposed).
;
; Parameters (System V AMD64 ABI):
;   rdi = size (size_t)  - requested mapping length in bytes
; Returns:
;   rax = page-aligned mapping address, or NULL on failure
; Uses / clobbers:
;   reads rdi; writes rax and the caller-saved rcx/r11 (clobbered by syscall);
;   rsi, rdx, r10, r8, r9 carry the remaining mmap(2) arguments
;==============================================================================
global asm_sys_mmap:function            ; export the mmap wrapper as a function
asm_sys_mmap:
    ; ---- argument setup: map the SysV argument into the mmap(2) register ABI ----
    mov     rsi, rdi                    ; rsi = size (mmap length argument)
    xor     edi, edi                    ; rdi = 0 (addr = NULL: kernel chooses address)
    mov     edx, PROT_RW                ; rdx = PROT_READ | PROT_WRITE
    mov     r10d, MAP_ANON_PRIV         ; r10 = MAP_PRIVATE | MAP_ANONYMOUS (4th syscall arg)
    mov     r8, -1                      ; r8 = -1 (fd, ignored for anonymous mappings)
    xor     r9d, r9d                    ; r9 = 0 (file offset)
    mov     eax, SYS_mmap               ; eax = 9 (mmap syscall number)
    ; ---- enter the kernel ----
    syscall                             ; invoke mmap; rax = result, rcx/r11 clobbered
    ; ---- classify the result and return ----
    cmp     rax, ERR_LIMIT              ; is rax inside the [-4095, -1] error range?
    jae     .fail                       ; yes: kernel returned -errno
    ret                                 ; return the mapping address in rax
.fail:
    xor     eax, eax                    ; normalise the error to NULL
    ret                                 ; return NULL

;==============================================================================
; int asm_sys_munmap(void *ptr, size_t size)
;------------------------------------------------------------------------------
; Releases a mapping obtained from asm_sys_mmap. Returns 0 on success.
;
; Parameters (System V AMD64 ABI):
;   rdi = ptr  (void *)  - base address of the mapping
;   rsi = size (size_t)  - length in bytes (must match the original mapping)
; Returns:
;   rax = 0 on success, or -errno on failure
; Uses / clobbers:
;   reads rdi and rsi; writes rax and the caller-saved rcx/r11 (syscall clobbers)
;==============================================================================
global asm_sys_munmap:function          ; export the munmap wrapper as a function
asm_sys_munmap:
    ; ---- issue munmap with rdi = ptr and rsi = size already in place ----
    mov     eax, SYS_munmap             ; eax = 11 (munmap syscall number)
    syscall                             ; invoke munmap; rax = 0 or -errno, rcx/r11 clobbered
    ret                                 ; return the kernel result in rax

;==============================================================================
; void *asm_sys_alloc(size_t size, void *ctx)
;------------------------------------------------------------------------------
; Arena-compatible allocation callback. `ctx` is unused: an anonymous mmap
; needs no backing-allocator context.
;
; Parameters (System V AMD64 ABI):
;   rdi = size (size_t)  - requested allocation size in bytes
;   rsi = ctx  (void *)  - ignored
; Returns:
;   rax = page-aligned mapping address, or NULL on failure (see asm_sys_mmap)
; Uses / clobbers:
;   tail-calls asm_sys_mmap with rdi forwarded; rsi is overwritten there and
;   the callee's clobbers (rax, rcx, r11) apply
;==============================================================================
global asm_sys_alloc:function           ; export the arena alloc callback as a function
asm_sys_alloc:
    jmp     asm_sys_mmap                ; tail-call mmap; rdi = size already

;==============================================================================
; void asm_sys_free(void *ptr, size_t size, void *ctx)
;------------------------------------------------------------------------------
; Arena-compatible free callback. `ctx` is unused; the whole mapping is
; released with munmap(2).
;
; Parameters (System V AMD64 ABI):
;   rdi = ptr  (void *)  - base address of the mapping
;   rsi = size (size_t)  - length in bytes
;   rdx = ctx  (void *)  - ignored
; Returns:
;   nothing (the void return value is unused; munmap's status is dropped)
; Uses / clobbers:
;   tail-calls asm_sys_munmap with rdi/rsi forwarded; rdx is ignored and the
;   callee's clobbers (rax, rcx, r11) apply
;==============================================================================
global asm_sys_free:function            ; export the arena free callback as a function
asm_sys_free:
    jmp     asm_sys_munmap              ; tail-call munmap; rdi = ptr, rsi = size already

GNU_STACK_NOTE                          ; emit the non-executable .note.GNU-stack section
