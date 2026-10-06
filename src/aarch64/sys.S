/*==============================================================================
 * sys.S - thin raw-syscall wrappers (Linux AArch64) for the OS allocators
 *------------------------------------------------------------------------------
 * SPDX-License-Identifier: MIT
 *
 * AArch64 port of src/sys.asm. These are the only platform-specific routines
 * in the library; they give the arena and the malloc-style allocator a way to
 * obtain memory from the kernel with no libc:
 *
 *   void *asm_sys_mmap  (size_t size);                 -> page-aligned or NULL
 *   int   asm_sys_munmap(void *ptr, size_t size);      -> 0 or -errno
 *   void *asm_sys_alloc (size_t size, void *ctx);      -> arena alloc callback
 *   void  asm_sys_free  (void *ptr, size_t size, void *ctx); arena free cb
 *
 * AArch64 Linux syscalls take the number in x8 and the arguments in x0..x5;
 * `svc #0` returns the result in x0 (negative errno in [-4095,-1] on error).
 * x8 is caller-saved, so nothing needs saving here.
 *============================================================================*/

#include "common_aarch64.inc"

    .text

/*==============================================================================
 * void *asm_sys_mmap(size_t size)
 *------------------------------------------------------------------------------
 * Anonymous private read/write mapping of at least `size` bytes, page aligned,
 * zero filled. Returns NULL on failure (errno is not exposed).
 *
 * Parameters (AAPCS64):
 *   x0 = size (size_t)  - requested mapping length in bytes
 * Returns:
 *   x0 = page-aligned mapping address, or NULL on failure
 * Uses / clobbers:
 *   reads x0; writes x0, x1..x5, x8 (all caller-saved)
 *============================================================================*/
    .globl asm_sys_mmap
    .type  asm_sys_mmap, %function
    .p2align 2
asm_sys_mmap:
    /* ---- argument setup: mmap(addr=0, len, prot, flags, fd=-1, off=0) ---- */
    mov     x1, x0                      /* x1 = len = size                      */
    mov     x0, #0                      /* x0 = addr = NULL (kernel chooses)    */
    mov     x2, #PROT_RW                /* x2 = PROT_READ | PROT_WRITE          */
    mov     x3, #MAP_ANON_PRIV          /* x3 = MAP_PRIVATE | MAP_ANONYMOUS     */
    mov     x4, #-1                     /* x4 = fd = -1 (anonymous)             */
    mov     x5, #0                      /* x5 = offset = 0                      */
    mov     x8, #SYS_mmap               /* x8 = 222 (mmap syscall number)       */
    /* ---- enter the kernel ---- */
    svc     #0                          /* x0 = result, or -errno on failure    */
    /* ---- classify the result and return ---- */
    cmn     x0, #4096                   /* sets C if (unsigned)x0 >= -4096      */
    b.lo    1f                          /* carry clear: a real (non-error) addr */
    mov     x0, #0                      /* x0 in [-4095,-1]: error -> NULL      */
1:
    ret                                 /* return x0 (mapping or NULL)          */
    .size asm_sys_mmap, .-asm_sys_mmap

/*==============================================================================
 * int asm_sys_munmap(void *ptr, size_t size)
 *------------------------------------------------------------------------------
 * Releases a mapping obtained from asm_sys_mmap. Returns 0 on success.
 *
 * Parameters (AAPCS64):
 *   x0 = ptr  (void *)  - base address of the mapping
 *   x1 = size (size_t)  - length in bytes (must match the original mapping)
 * Returns:
 *   x0 = 0 on success, or -errno on failure
 *============================================================================*/
    .globl asm_sys_munmap
    .type  asm_sys_munmap, %function
    .p2align 2
asm_sys_munmap:
    mov     x8, #SYS_munmap             /* x8 = 215 (munmap syscall number)     */
    svc     #0                          /* x0 = 0 or -errno                     */
    ret                                 /* return the kernel result in x0       */
    .size asm_sys_munmap, .-asm_sys_munmap

/*==============================================================================
 * long asm_sys_write(int fd, const void *buf, size_t count)
 *------------------------------------------------------------------------------
 * Raw write(2) for the formatted-output (dprintf/printf) layer. Returns the
 * number of bytes written or -errno; callers must handle short writes.
 *
 * Parameters (AAPCS64):
 *   x0 = fd (int)      - file descriptor
 *   x1 = buf (void *)  - bytes to write
 *   x2 = count (size_t)- byte count
 * Returns:
 *   x0 = bytes written, or -errno
 *============================================================================*/
    .globl asm_sys_write
    .type  asm_sys_write, %function
    .p2align 2
asm_sys_write:
    mov     x8, #SYS_write              /* x8 = 64 (write syscall number)       */
    svc     #0                          /* x0 = bytes written or -errno         */
    ret
    .size asm_sys_write, .-asm_sys_write

/*==============================================================================
 * void *asm_sys_alloc(size_t size, void *ctx)
 *------------------------------------------------------------------------------
 * Arena-compatible allocation callback (ctx is unused).
 *
 * Parameters (AAPCS64):
 *   x0 = size (size_t)  - bytes to map
 *   x1 = ctx  (void *)  - ignored
 * Returns:
 *   x0 = mapping address, or NULL
 *============================================================================*/
    .globl asm_sys_alloc
    .type  asm_sys_alloc, %function
    .p2align 2
asm_sys_alloc:
    b       asm_sys_mmap                /* x0 = size already; tail-call mmap    */
    .size asm_sys_alloc, .-asm_sys_alloc

/*==============================================================================
 * void asm_sys_free(void *ptr, size_t size, void *ctx)
 *------------------------------------------------------------------------------
 * Arena-compatible free callback (ctx is unused); munmaps the whole chunk.
 *
 * Parameters (AAPCS64):
 *   x0 = ptr  (void *)  - mapping base
 *   x1 = size (size_t)  - mapping length
 *   x2 = ctx  (void *)  - ignored
 *============================================================================*/
    .globl asm_sys_free
    .type  asm_sys_free, %function
    .p2align 2
asm_sys_free:
    b       asm_sys_munmap              /* arg0/arg1 already in place           */
    .size asm_sys_free, .-asm_sys_free

/*==============================================================================
 * int asm_arena_init_mmap(asm_arena *a, size_t chunk_size)
 *------------------------------------------------------------------------------
 * Growable arena whose chunks come straight from the kernel via anonymous mmap.
 * Linux AArch64 only (this module is the sole OS boundary); arena.S itself has
 * no syscalls, so an arena over caller memory links without any OS code.
 *
 * Parameters (AAPCS64):
 *   x0 = a          (asm_arena *) - arena to initialise
 *   x1 = chunk_size (size_t)      - default chunk size, clamped up to 4096
 * Returns:
 *   w0 = 0 on success, -1 if a is NULL
 *============================================================================*/
    .globl asm_arena_init_mmap
    .type  asm_arena_init_mmap, %function
    .p2align 2
asm_arena_init_mmap:
    mov     x4, x1                      /* arg5 = chunk_size                     */
    mov     x3, xzr                     /* arg4 = ctx = NULL                     */
    adrp    x1, asm_sys_alloc
    add     x1, x1, :lo12:asm_sys_alloc /* arg2 = asm_sys_alloc callback         */
    adrp    x2, asm_sys_free
    add     x2, x2, :lo12:asm_sys_free  /* arg3 = asm_sys_free callback          */
    b       asm_arena_init_grow         /* tail-call the growable initialiser    */
    .size asm_arena_init_mmap, .-asm_arena_init_mmap

GNU_STACK_NOTE
