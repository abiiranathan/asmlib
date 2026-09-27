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
;==============================================================================
global asm_sys_mmap:function
asm_sys_mmap:
    mov     rsi, rdi                    ; len = size
    xor     edi, edi                    ; addr = NULL (let the kernel choose)
    mov     edx, PROT_RW                ; prot
    mov     r10d, MAP_ANON_PRIV         ; flags
    mov     r8, -1                      ; fd = -1 (anonymous)
    xor     r9d, r9d                    ; offset = 0
    mov     eax, SYS_mmap
    syscall
    cmp     rax, ERR_LIMIT              ; kernel error range?
    jae     .fail
    ret
.fail:
    xor     eax, eax                    ; normalise to NULL
    ret

;==============================================================================
; int asm_sys_munmap(void *ptr, size_t size)
;------------------------------------------------------------------------------
; Releases a mapping obtained from asm_sys_mmap. Returns 0 on success.
;==============================================================================
global asm_sys_munmap:function
asm_sys_munmap:
    mov     eax, SYS_munmap
    syscall
    ret

;==============================================================================
; void *asm_sys_alloc(size_t size, void *ctx)
;------------------------------------------------------------------------------
; Arena-compatible allocation callback (ctx is unused).
;==============================================================================
global asm_sys_alloc:function
asm_sys_alloc:
    jmp     asm_sys_mmap                ; rdi = size already

;==============================================================================
; void asm_sys_free(void *ptr, size_t size, void *ctx)
;------------------------------------------------------------------------------
; Arena-compatible free callback (ctx is unused); munmaps the whole chunk.
;==============================================================================
global asm_sys_free:function
asm_sys_free:
    jmp     asm_sys_munmap              ; rdi = ptr, rsi = size already

GNU_STACK_NOTE
