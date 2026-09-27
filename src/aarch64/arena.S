/*==============================================================================
 * arena.S - a chunked, resettable linear (bump) arena allocator (AArch64)
 *------------------------------------------------------------------------------
 * SPDX-License-Identifier: MIT
 *
 * AArch64 port of src/arena.asm. A robust arena allocator for high-throughput
 * temporary allocations:
 *
 *   int    asm_arena_init         (asm_arena *a, void *buf, size_t size);
 *   int    asm_arena_init_grow    (asm_arena *a, void *(*alloc)(size_t,void*),
 *                                  void (*free)(void*,size_t,void*), void *ctx,
 *                                  size_t chunk_size);
 *   int    asm_arena_init_mmap    (asm_arena *a, size_t chunk_size);
 *   void  *asm_arena_alloc        (asm_arena *a, size_t size);
 *   void  *asm_arena_alloc_aligned(asm_arena *a, size_t size, size_t align);
 *   void  *asm_arena_calloc       (asm_arena *a, size_t count, size_t size);
 *   void  *asm_arena_realloc      (asm_arena *a, void *ptr, size_t old, size_t nw);
 *   void   asm_arena_mark         (const asm_arena *a, asm_mark *m);
 *   int    asm_arena_release      (asm_arena *a, const asm_mark *m);
 *   void   asm_arena_reset        (asm_arena *a);
 *   void   asm_arena_destroy      (asm_arena *a);
 *   size_t asm_arena_used         (const asm_arena *a);
 *   size_t asm_arena_peak         (const asm_arena *a);
 *   size_t asm_arena_remaining    (const asm_arena *a);
 *   size_t asm_arena_capacity     (const asm_arena *a);
 *
 * Design
 * ------
 * * Allocations are handed out by bumping a pointer (a few instructions).
 * * Memory is carved from a chain of chunks. A fixed arena uses one
 *   user-supplied buffer; a growable arena obtains further chunks from a
 *   caller-provided backing allocator (e.g. malloc or asm_sys_alloc), so it
 *   stays usable in freestanding code where no allocator exists.
 * * Every allocation is at least 16-byte aligned; alloc_aligned supports any
 *   power-of-two alignment.
 * * reset() keeps the first chunk and releases all later chunks in one step.
 * * mark()/release() give scoped rollback: release frees the chunks newer than
 *   the mark and restores the bump pointer.
 * * Exhaustion returns NULL; it never overruns the backing store.
 *
 * This allocator is single-threaded, like the x86 version it ports.
 *
 * AAPCS64 notes: arguments arrive in x0..x7 and the result leaves in x0;
 * x19..x28 are callee-saved and x30 (lr) is saved across any call. Registers
 * are paired with stp/ldp so the stack stays 16-byte aligned for calls.
 *============================================================================*/

#include "common_aarch64.inc"

    .text

/* ---- asm_arena field offsets (must match include/asmlib.h) ---------------- */
#define A_PTR    0                      /* unsigned char *ptr - next free byte   */
#define A_END    8                      /* unsigned char *end - one past chunk   */
#define A_CUR    16                     /* chunk *cur - newest (current) chunk   */
#define A_FIRST  24                     /* chunk *first - oldest chunk, reset base */
#define A_ALLOC  32                     /* void *(*alloc)(size_t, void *)        */
#define A_FREE   40                     /* void (*free)(void *, size_t, void *)  */
#define A_CTX    48                     /* void *ctx - callback context          */
#define A_CHUNK  56                     /* size_t chunk - default grow size      */
#define A_TOTAL  64                     /* size_t total - usable bytes all chunks */
#define A_USED   72                     /* size_t used - bytes handed out        */
#define A_PEAK   80                     /* size_t peak - high-water mark of used */
#define A_SIZE   88                     /* sizeof(asm_arena)                     */

/* ---- chunk header offsets ------------------------------------------------ */
#define C_RAW    0                      /* void *raw - base passed to free       */
#define C_NEXT   8                      /* chunk *next - next older chunk        */
#define C_CAP    16                     /* size_t cap - usable bytes in chunk    */
#define C_BSIZE  24                     /* size_t bsize - backing bytes for free */
#define C_DATA   32                     /* unsigned char *data - first usable    */
#define C_HDR    48                     /* chunk header size / alignment base    */

/*==============================================================================
 * int asm_arena_init(asm_arena *a, void *buf, size_t size)
 *------------------------------------------------------------------------------
 * Fixed arena over caller memory. The first 64 bytes of buf hold the chunk
 * header and alignment padding. Returns 0, or -1 on bad arguments.
 *
 * Parameters (AAPCS64):
 *   x0 = a    (asm_arena *)  - arena to initialise
 *   x1 = buf  (void *)       - caller-owned backing buffer
 *   x2 = size (size_t)       - length of buf in bytes
 * Returns:
 *   w0 = 0 on success, -1 on invalid arguments
 *============================================================================*/
    .globl asm_arena_init
    .type  asm_arena_init, %function
    .p2align 2
asm_arena_init:
    /* ---- validate arguments ---- */
    cbz     x0, .Linit_bad              /* a == NULL -> fail                     */
    cbz     x1, .Linit_bad              /* buf == NULL -> fail                   */
    cmp     x2, #64                     /* enough room for header + capacity?    */
    b.lo    .Linit_bad                  /* size < 64 -> fail                     */
    /* ---- compute the aligned data pointer and capacity ---- */
    add     x3, x1, #(C_HDR + 15)       /* data = align16(buf + 48)              */
    and     x3, x3, #-16                /* round data down to a 16-byte boundary */
    add     x4, x1, x2                  /* end = buf + size                      */
    cmp     x3, x4                      /* does data fit before end?             */
    b.hs    .Linit_bad                  /* no capacity left -> fail              */
    /* ---- write the chunk header at buf ---- */
    str     x1, [x1, #C_RAW]            /* raw = buf (never freed)               */
    str     xzr, [x1, #C_NEXT]          /* next = NULL (no older chunk)          */
    sub     x5, x4, x3                  /* cap = end - data                      */
    str     x5, [x1, #C_CAP]            /* cap = end - data                      */
    str     x2, [x1, #C_BSIZE]          /* bsize = size                          */
    str     x3, [x1, #C_DATA]           /* data = aligned payload base           */
    /* ---- initialise the arena ---- */
    str     x3, [x0, #A_PTR]            /* ptr = first free byte                 */
    str     x4, [x0, #A_END]            /* end = buf + size                      */
    str     x1, [x0, #A_CUR]            /* cur = the only chunk                  */
    str     x1, [x0, #A_FIRST]          /* first = the only chunk                */
    str     xzr, [x0, #A_ALLOC]         /* fixed arena: no alloc callback        */
    str     xzr, [x0, #A_FREE]          /* fixed arena: no free callback         */
    str     xzr, [x0, #A_CTX]           /* ctx = NULL                            */
    str     xzr, [x0, #A_CHUNK]         /* no default grow size                  */
    str     x5, [x0, #A_TOTAL]          /* total = cap                           */
    str     xzr, [x0, #A_USED]          /* used = 0                              */
    str     xzr, [x0, #A_PEAK]          /* peak = 0                              */
    mov     w0, #0                      /* return 0 (success)                    */
    ret
.Linit_bad:
    mov     w0, #-1                     /* return -1 (bad arguments)             */
    ret
    .size asm_arena_init, .-asm_arena_init

/*==============================================================================
 * int asm_arena_init_grow(asm_arena *a, alloc, free, ctx, chunk_size)
 *------------------------------------------------------------------------------
 * Growable arena. alloc(size, ctx) must return at least 16-byte aligned memory
 * or NULL; free(ptr, size, ctx) releases it (may be NULL if memory never needs
 * to be returned, e.g. a bump region for the process lifetime).
 *
 * Parameters (AAPCS64):
 *   x0 = a          (asm_arena *)            - arena to initialise
 *   x1 = alloc      (void *(*)(size_t,void*))- backing allocation callback
 *   x2 = free       (void (*)(void*,size_t,void*)) - release callback (or NULL)
 *   x3 = ctx        (void *)                 - opaque callback context
 *   x4 = chunk_size (size_t)                 - default chunk size, min 4096
 * Returns:
 *   w0 = 0 on success, -1 if a or alloc is NULL
 *============================================================================*/
    .globl asm_arena_init_grow
    .type  asm_arena_init_grow, %function
    .p2align 2
asm_arena_init_grow:
    /* ---- validate arguments ---- */
    cbz     x0, .Lgrow_bad              /* a == NULL -> fail                     */
    cbz     x1, .Lgrow_bad              /* alloc == NULL -> fail                 */
    /* ---- store the backing allocator and clamp the chunk size ---- */
    str     x1, [x0, #A_ALLOC]          /* store alloc callback                  */
    str     x2, [x0, #A_FREE]           /* store free callback (may be NULL)     */
    str     x3, [x0, #A_CTX]            /* store allocator context               */
    mov     x5, #4096                   /* default chunk is at least 4 KiB       */
    cmp     x4, x5                      /* chunk_size below 4096?                */
    csel    x4, x5, x4, lo              /* clamp chunk_size up to 4096           */
    str     x4, [x0, #A_CHUNK]          /* remember default chunk size           */
    /* ---- clear the arena state ---- */
    str     xzr, [x0, #A_PTR]           /* ptr = NULL (no chunk yet)             */
    str     xzr, [x0, #A_END]           /* end = NULL                            */
    str     xzr, [x0, #A_CUR]           /* cur = NULL                            */
    str     xzr, [x0, #A_FIRST]         /* first = NULL                          */
    str     xzr, [x0, #A_TOTAL]         /* total = 0                             */
    str     xzr, [x0, #A_USED]          /* used = 0                              */
    str     xzr, [x0, #A_PEAK]          /* peak = 0                              */
    mov     w0, #0                      /* return 0 (success)                    */
    ret
.Lgrow_bad:
    mov     w0, #-1                     /* return -1 (bad arguments)             */
    ret
    .size asm_arena_init_grow, .-asm_arena_init_grow

/*==============================================================================
 * int asm_arena_init_mmap(asm_arena *a, size_t chunk_size)
 *------------------------------------------------------------------------------
 * Growable arena whose chunks come straight from the kernel via anonymous
 * mmap. No libc, no caller-supplied allocator. Requires Linux AArch64.
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
    /* ---- wire up the anonymous-mmap backend and tail-call init_grow ---- */
    mov     x4, x1                      /* arg5 = chunk_size                     */
    mov     x3, xzr                     /* arg4 = ctx = NULL                     */
    adrp    x1, asm_sys_alloc           /* arg2 = asm_sys_alloc callback         */
    add     x1, x1, :lo12:asm_sys_alloc
    adrp    x2, asm_sys_free            /* arg3 = asm_sys_free callback          */
    add     x2, x2, :lo12:asm_sys_free
    b       asm_arena_init_grow         /* tail-call the growable initialiser    */
    .size asm_arena_init_mmap, .-asm_arena_init_mmap

/*==============================================================================
 * internal: L_arena_grow(asm_arena *a, size_t need, size_t align) -> chunk data
 *------------------------------------------------------------------------------
 * Obtains a new chunk from the backing allocator, links it as the current
 * chunk and returns its (align-aligned) data pointer, or NULL.
 *
 * Parameters (AAPCS64):
 *   x0 = a     (asm_arena *) - arena whose backing allocator is used
 *   x1 = need  (size_t)      - minimum usable capacity required
 *   x2 = align (size_t)      - alignment for the returned data pointer
 * Returns:
 *   x0 = chunk data pointer, or NULL if the backing allocation fails
 * Uses callee-saved x19..x24 and saves lr across the indirect callback call.
 *============================================================================*/
    .type  L_arena_grow, %function
    .p2align 2
L_arena_grow:
    /* ---- prologue: preserve callee-saved registers and lr ---- */
    stp     x19, x20, [sp, #-16]!       /* x19 = a,  x20 = need                  */
    stp     x21, x22, [sp, #-16]!       /* x21 = align, x22 = chunk size         */
    stp     x23, x24, [sp, #-16]!       /* x23 = total, x24 = raw                */
    str     x30, [sp, #-16]!            /* preserve the return address           */
    mov     x19, x0                     /* x19 = a                               */
    mov     x20, x1                     /* x20 = need                            */
    mov     x21, x2                     /* x21 = align                           */
    /* ---- size the backing allocation: max(chunk, need) + header + align ---- */
    ldr     x22, [x19, #A_CHUNK]        /* x22 = chunk_size                      */
    cmp     x20, x22                    /* need > chunk_size?                    */
    csel    x22, x20, x22, hi           /* x22 = max(chunk_size, need)           */
    add     x23, x22, #C_HDR            /* total = chunk + header                */
    adds    x23, x23, x21               /* total += align                        */
    b.cs    .Lgrow_fail                 /* size overflow -> fail                 */
    /* ---- call the backing allocator: alloc(total_size, ctx) ---- */
    mov     x0, x23                     /* arg1 = total size                     */
    ldr     x1, [x19, #A_CTX]           /* arg2 = ctx                            */
    ldr     x9, [x19, #A_ALLOC]         /* x9 = alloc callback                   */
    cbz     x9, .Lgrow_fail             /* no allocator -> fail                  */
    blr     x9                          /* x0 = raw (or NULL)                    */
    cbz     x0, .Lgrow_fail             /* allocation failed -> fail             */
    mov     x24, x0                     /* x24 = raw                             */
    /* ---- align the payload and compute the capacity ---- */
    add     x1, x24, #C_HDR             /* data = align_up(raw + 48, align)      */
    sub     x2, x21, #1                 /* x2 = align - 1                        */
    add     x1, x1, x2                  /* data += align - 1                     */
    mvn     x2, x2                      /* x2 = ~(align - 1)                     */
    and     x1, x1, x2                  /* x1 = aligned payload                  */
    add     x2, x24, x23                /* x2 = end = raw + total                */
    sub     x3, x2, x1                  /* x3 = cap = end - data                 */
    /* ---- fill in and link the new chunk header ---- */
    str     x24, [x24, #C_RAW]          /* raw = allocation base                 */
    ldr     x4, [x19, #A_CUR]           /* x4 = old current chunk                */
    str     x4, [x24, #C_NEXT]          /* next = old current                    */
    str     x3, [x24, #C_CAP]           /* cap                                   */
    str     x23, [x24, #C_BSIZE]        /* bsize = requested total               */
    str     x1, [x24, #C_DATA]          /* data = aligned payload                */
    str     x24, [x19, #A_CUR]          /* make it current                       */
    str     x1, [x19, #A_PTR]           /* ptr = data                            */
    str     x2, [x19, #A_END]           /* end = raw + total                     */
    ldr     x4, [x19, #A_TOTAL]         /* total += cap                          */
    add     x4, x4, x3
    str     x4, [x19, #A_TOTAL]
    ldr     x4, [x19, #A_FIRST]         /* remember the first chunk              */
    cbnz    x4, .Lgrow_have_first       /* first chunk already set?              */
    str     x24, [x19, #A_FIRST]        /* record the first chunk                */
.Lgrow_have_first:
    mov     x0, x1                      /* return the data pointer               */
    ldr     x30, [sp], #16              /* restore the return address            */
    ldp     x23, x24, [sp], #16
    ldp     x21, x22, [sp], #16
    ldp     x19, x20, [sp], #16
    ret
.Lgrow_fail:
    mov     x0, xzr                     /* return NULL (failure)                 */
    ldr     x30, [sp], #16              /* restore the return address            */
    ldp     x23, x24, [sp], #16
    ldp     x21, x22, [sp], #16
    ldp     x19, x20, [sp], #16
    ret
    .size L_arena_grow, .-L_arena_grow

/*==============================================================================
 * void *asm_arena_alloc(asm_arena *a, size_t size)
 *------------------------------------------------------------------------------
 * Returns a 16-byte aligned block of at least size bytes, or NULL.
 *
 * Parameters (AAPCS64):
 *   x0 = a    (asm_arena *) - arena to allocate from
 *   x1 = size (size_t)      - minimum block size in bytes
 * Returns:
 *   x0 = 16-byte aligned block, or NULL on overflow/exhaustion
 *============================================================================*/
    .globl asm_arena_alloc
    .type  asm_arena_alloc, %function
    .p2align 2
asm_arena_alloc:
    /* ---- prologue: preserve callee-saved registers and lr ---- */
    stp     x19, x20, [sp, #-16]!       /* x19 = a, x20 = aligned size           */
    str     x30, [sp, #-16]!
    /* ---- validate the arena and round the request up to 16 ---- */
    cbz     x0, .Lalloc_fail            /* a == NULL -> fail                     */
    mov     x19, x0                     /* x19 = a                               */
    adds    x20, x1, #15                /* size + 15 (round-up bias)             */
    b.cs    .Lalloc_fail                /* size + 15 overflow -> fail            */
    and     x20, x20, #-16              /* x20 = 16-aligned size                 */
    /* ---- try the current chunk ---- */
    ldr     x2, [x19, #A_PTR]           /* x2 = bump pointer                     */
    cbz     x2, .Lalloc_grow            /* no chunk -> grow                      */
    adds    x3, x2, x20                 /* x3 = end of new block                 */
    b.cs    .Lalloc_fail                /* ptr + size overflow -> fail           */
    ldr     x4, [x19, #A_END]           /* fits in the current chunk?            */
    cmp     x3, x4
    b.hi    .Lalloc_grow                /* does not fit -> grow                  */
    /* ---- commit the allocation and update stats ---- */
    str     x3, [x19, #A_PTR]           /* commit the bump pointer               */
    mov     x0, x2                      /* x0 = start of block                   */
    b       .Lalloc_commit
.Lalloc_grow:
    ldr     x4, [x19, #A_ALLOC]         /* can we grow?                          */
    cbz     x4, .Lalloc_fail            /* no allocator -> fail                  */
    mov     x0, x19                     /* arg1 = a                              */
    mov     x1, x20                     /* arg2 = aligned size                   */
    mov     x2, #16                     /* arg3 = 16-byte alignment              */
    bl      L_arena_grow                /* get a new chunk                       */
    cbz     x0, .Lalloc_fail            /* grow failed -> fail                   */
    /* ---- bump from the start of the new chunk ---- */
    ldr     x1, [x19, #A_PTR]           /* new chunk: bump from its start        */
    add     x2, x1, x20                 /* x2 = end of block                     */
    ldr     x3, [x19, #A_END]           /* fits in new chunk?                    */
    cmp     x2, x3
    b.hi    .Lalloc_fail                /* cannot happen (cap >= need) -> fail   */
    str     x2, [x19, #A_PTR]           /* commit the bump pointer               */
    mov     x0, x1                      /* x0 = block                            */
.Lalloc_commit:
    ldr     x3, [x19, #A_USED]          /* used += size                          */
    add     x3, x3, x20
    str     x3, [x19, #A_USED]
    ldr     x4, [x19, #A_PEAK]          /* used > peak?                          */
    cmp     x3, x4
    b.ls    .Lalloc_done
    str     x3, [x19, #A_PEAK]          /* peak = used                           */
.Lalloc_done:
    ldr     x30, [sp], #16
    ldp     x19, x20, [sp], #16
    ret
.Lalloc_fail:
    mov     x0, xzr                     /* return NULL (failure)                 */
    ldr     x30, [sp], #16
    ldp     x19, x20, [sp], #16
    ret
    .size asm_arena_alloc, .-asm_arena_alloc

/*==============================================================================
 * void *asm_arena_alloc_aligned(asm_arena *a, size_t size, size_t align)
 *------------------------------------------------------------------------------
 * Like asm_arena_alloc but the result is aligned to `align` (a power of two;
 * values below 16 are treated as 16).
 *
 * Parameters (AAPCS64):
 *   x0 = a     (asm_arena *) - arena to allocate from
 *   x1 = size  (size_t)      - minimum block size in bytes
 *   x2 = align (size_t)      - required alignment (power of two, min 16)
 * Returns:
 *   x0 = align-aligned block, or NULL on bad alignment/overflow/exhaustion
 *============================================================================*/
    .globl asm_arena_alloc_aligned
    .type  asm_arena_alloc_aligned, %function
    .p2align 2
asm_arena_alloc_aligned:
    /* ---- validate the alignment (non-zero power of two, min 16) ---- */
    cbz     x0, .Lalign_bad             /* a == NULL -> fail                     */
    cbz     x2, .Lalign_bad             /* align == 0 -> fail                    */
    sub     x3, x2, #1                  /* x3 = align - 1                        */
    tst     x2, x3                      /* more than one bit set?                */
    b.ne    .Lalign_bad                 /* not a power of two -> fail            */
    cmp     x2, #16                     /* clamp up to 16                        */
    b.hs    .Lalign_ok
    mov     x2, #16                     /* clamp align to 16                     */
.Lalign_ok:
    /* ---- prologue: preserve callee-saved registers and lr ---- */
    stp     x19, x20, [sp, #-16]!       /* x19 = a,  x20 = rounded size          */
    stp     x21, x22, [sp, #-16]!       /* x21 = align, x22 = old ptr            */
    str     x30, [sp, #-16]!
    mov     x19, x0                     /* x19 = a                               */
    mov     x21, x2                     /* x21 = align                           */
    /* ---- round the request up to 16 ---- */
    adds    x20, x1, #15                /* size + 15 (round-up bias)             */
    b.cs    .Lalign_fail                /* size + 15 overflow -> fail            */
    and     x20, x20, #-16              /* x20 = 16-aligned size                 */
    ldr     x22, [x19, #A_PTR]          /* x22 = bump pointer                    */
    cbz     x22, .Lalign_grow           /* no chunk -> grow                      */
    /* ---- align the bump pointer within the current chunk ---- */
    sub     x3, x21, #1                 /* x3 = align - 1                        */
    adds    x0, x22, x3                 /* p = ptr + align - 1                   */
    b.cs    .Lalign_fail                /* alignment add overflow -> fail        */
    mvn     x3, x3                      /* x3 = ~(align - 1)                     */
    and     x0, x0, x3                  /* x0 = align_up(ptr, align)             */
    /* ---- fit check ---- */
    adds    x3, x0, x20                 /* x3 = end of block                     */
    b.cs    .Lalign_fail                /* block end overflow -> fail            */
    ldr     x4, [x19, #A_END]           /* fits in chunk?                        */
    cmp     x3, x4
    b.hi    .Lalign_grow                /* does not fit -> grow                  */
    /* ---- commit the allocation and update stats ---- */
    str     x3, [x19, #A_PTR]           /* commit the bump pointer               */
    sub     x3, x3, x22                 /* consumed = new - old (pad + size)     */
    b       .Lalign_commit
.Lalign_grow:
    ldr     x4, [x19, #A_ALLOC]         /* allocator present?                    */
    cbz     x4, .Lalign_fail            /* no allocator -> fail                  */
    mov     x0, x19                     /* arg1 = a                              */
    mov     x1, x20                     /* arg2 = rounded size                   */
    mov     x2, x21                     /* arg3 = align                          */
    bl      L_arena_grow                /* get an aligned chunk                  */
    cbz     x0, .Lalign_fail            /* grow failed -> fail                   */
    ldr     x22, [x19, #A_PTR]          /* data is already align-aligned         */
    mov     x0, x22                     /* x0 = block                            */
    add     x3, x0, x20                 /* x3 = end of block                     */
    ldr     x4, [x19, #A_END]           /* fits in new chunk?                    */
    cmp     x3, x4
    b.hi    .Lalign_fail                /* cannot happen -> fail                 */
    str     x3, [x19, #A_PTR]           /* commit the bump pointer               */
    sub     x3, x3, x22                 /* consumed = end - start                */
.Lalign_commit:
    ldr     x4, [x19, #A_USED]          /* used += consumed                      */
    add     x4, x4, x3
    str     x4, [x19, #A_USED]
    ldr     x5, [x19, #A_PEAK]          /* used > peak?                          */
    cmp     x4, x5
    b.ls    .Lalign_done
    str     x4, [x19, #A_PEAK]          /* peak = used                           */
.Lalign_done:
    ldr     x30, [sp], #16
    ldp     x21, x22, [sp], #16
    ldp     x19, x20, [sp], #16
    ret
.Lalign_fail:
    mov     x0, xzr                     /* return NULL (failure)                 */
    ldr     x30, [sp], #16
    ldp     x21, x22, [sp], #16
    ldp     x19, x20, [sp], #16
    ret
.Lalign_bad:
    mov     x0, xzr                     /* return NULL (bad alignment)           */
    ret
    .size asm_arena_alloc_aligned, .-asm_arena_alloc_aligned

/*==============================================================================
 * void *asm_arena_calloc(asm_arena *a, size_t count, size_t size)
 *------------------------------------------------------------------------------
 * Allocates count*size zeroed bytes, or NULL on overflow/exhaustion.
 *
 * Parameters (AAPCS64):
 *   x0 = a     (asm_arena *) - arena to allocate from
 *   x1 = count (size_t)      - element count
 *   x2 = size  (size_t)      - element size in bytes
 * Returns:
 *   x0 = zeroed block, or NULL on overflow or exhaustion
 *============================================================================*/
    .globl asm_arena_calloc
    .type  asm_arena_calloc, %function
    .p2align 2
asm_arena_calloc:
    /* ---- prologue: preserve callee-saved registers and lr ---- */
    stp     x19, x20, [sp, #-16]!       /* x19 = a,  x20 = total bytes           */
    stp     x21, x30, [sp, #-16]!       /* x21 = block                           */
    /* ---- validate the arena and compute count * size ---- */
    cbz     x0, .Lcalloc_fail           /* a == NULL -> fail                     */
    mov     x19, x0                     /* x19 = a                               */
    umulh   x3, x1, x2                  /* high half of count * size             */
    cbnz    x3, .Lcalloc_fail           /* product overflowed 64 bits -> fail    */
    mul     x20, x1, x2                 /* x20 = total bytes                     */
    /* ---- allocate and zero the block ---- */
    mov     x0, x19                     /* arg1 = a                              */
    mov     x1, x20                     /* arg2 = total bytes                    */
    bl      asm_arena_alloc             /* allocate the block                    */
    cbz     x0, .Lcalloc_done           /* failed -> return NULL                 */
    mov     x21, x0                     /* x21 = block                           */
    mov     x0, x21                     /* zero it                               */
    mov     w1, #0                      /* fill byte = 0                         */
    mov     x2, x20                     /* length = total bytes                  */
    bl      asm_memset                  /* zero the block                        */
    mov     x0, x21                     /* return the block                      */
.Lcalloc_done:
    ldp     x21, x30, [sp], #16
    ldp     x19, x20, [sp], #16
    ret
.Lcalloc_fail:
    mov     x0, xzr                     /* return NULL (failure)                 */
    ldp     x21, x30, [sp], #16
    ldp     x19, x20, [sp], #16
    ret
    .size asm_arena_calloc, .-asm_arena_calloc

/*==============================================================================
 * void *asm_arena_realloc(asm_arena *a, void *ptr, size_t old, size_t nw)
 *------------------------------------------------------------------------------
 * Grows/shrinks the most recent allocation in place when possible, otherwise
 * allocates a new block and copies min(old, nw) bytes. ptr may be NULL.
 *
 * Parameters (AAPCS64):
 *   x0 = a   (asm_arena *) - arena to reallocate in
 *   x1 = ptr (void *)      - existing block, or NULL
 *   x2 = old (size_t)      - current usable size of ptr
 *   x3 = nw  (size_t)      - requested new size in bytes
 * Returns:
 *   x0 = resized block, or NULL on overflow or allocation failure
 *============================================================================*/
    .globl asm_arena_realloc
    .type  asm_arena_realloc, %function
    .p2align 2
asm_arena_realloc:
    /* ---- prologue: preserve callee-saved registers and lr ---- */
    stp     x19, x20, [sp, #-16]!       /* x19 = a,  x20 = ptr                   */
    stp     x21, x22, [sp, #-16]!       /* x21 = old, x22 = new size             */
    stp     x23, x24, [sp, #-16]!       /* x23 = old aligned, x24 = new block    */
    str     x30, [sp, #-16]!
    /* ---- validate arguments; treat NULL ptr as alloc ---- */
    cbz     x0, .Lrealloc_fail          /* a == NULL -> fail                     */
    mov     x19, x0                     /* x19 = a                               */
    mov     x20, x1                     /* x20 = ptr                             */
    mov     x21, x2                     /* x21 = old size                        */
    mov     x22, x3                     /* x22 = new size                        */
    cbz     x20, .Lrealloc_new          /* realloc(NULL, n) == alloc(n)          */
    /* ---- round old and new sizes up to 16 ---- */
    adds    x23, x21, #15               /* old + 15 (round-up bias)              */
    b.cs    .Lrealloc_fail              /* old + 15 overflow -> fail             */
    and     x23, x23, #-16              /* x23 = old rounded to 16               */
    adds    x24, x22, #15               /* new + 15 (round-up bias)              */
    b.cs    .Lrealloc_fail              /* new + 15 overflow -> fail             */
    and     x24, x24, #-16              /* x24 = new rounded to 16               */
    /* ---- in-place growth of the last allocation ---- */
    add     x3, x20, x23                /* ptr + old aligned                      */
    ldr     x4, [x19, #A_PTR]           /* is ptr the last allocation?           */
    cmp     x3, x4
    b.ne    .Lrealloc_new               /* no -> allocate a new block            */
    add     x3, x20, x24                /* new end                               */
    ldr     x4, [x19, #A_END]           /* new end within chunk?                 */
    cmp     x3, x4
    b.hi    .Lrealloc_new               /* no -> allocate a new block            */
    sub     x4, x24, x23                /* used delta (may be negative)          */
    ldr     x5, [x19, #A_USED]          /* used += (new - old)                   */
    add     x5, x5, x4
    str     x5, [x19, #A_USED]
    str     x3, [x19, #A_PTR]           /* commit in place                       */
    mov     x0, x20                     /* return ptr (unchanged)                */
    b       .Lrealloc_done
    /* ---- allocate a new block and copy ---- */
.Lrealloc_new:
    mov     x0, x19                     /* arg1 = a                              */
    mov     x1, x22                     /* arg2 = new size                       */
    bl      asm_arena_alloc             /* allocate the new block                */
    cbz     x0, .Lrealloc_fail          /* failed -> return NULL                 */
    mov     x24, x0                     /* x24 = new block                       */
    cbz     x20, .Lrealloc_ret_new      /* nothing to copy                       */
    mov     x2, x21                     /* n = min(old, new)                     */
    cmp     x2, x22
    csel    x2, x2, x22, ls             /* old <= new ? old : new                */
    mov     x0, x24                     /* arg1 = destination                    */
    mov     x1, x20                     /* arg2 = source                         */
    bl      asm_memcpy                  /* copy the live prefix                  */
.Lrealloc_ret_new:
    mov     x0, x24                     /* return the new block                  */
    b       .Lrealloc_done
.Lrealloc_fail:
    mov     x0, xzr                     /* return NULL (failure)                 */
.Lrealloc_done:
    ldr     x30, [sp], #16
    ldp     x23, x24, [sp], #16
    ldp     x21, x22, [sp], #16
    ldp     x19, x20, [sp], #16
    ret
    .size asm_arena_realloc, .-asm_arena_realloc

/*==============================================================================
 * void asm_arena_mark(const asm_arena *a, asm_mark *m)
 *------------------------------------------------------------------------------
 * Snapshot the current position so it can be restored with release().
 *
 * Parameters (AAPCS64):
 *   x0 = a (const asm_arena *) - arena to snapshot
 *   x1 = m (asm_mark *)        - mark to fill in
 *============================================================================*/
    .globl asm_arena_mark
    .type  asm_arena_mark, %function
    .p2align 2
asm_arena_mark:
    /* ---- snapshot chunk, position and used ---- */
    ldr     x2, [x0, #A_CUR]            /* m->chunk = a->cur                     */
    str     x2, [x1]
    ldr     x2, [x0, #A_PTR]            /* m->ptr = a->ptr                       */
    str     x2, [x1, #8]
    ldr     x2, [x0, #A_USED]           /* m->used = a->used                     */
    str     x2, [x1, #16]
    ret
    .size asm_arena_mark, .-asm_arena_mark

/*==============================================================================
 * int asm_arena_release(asm_arena *a, const asm_mark *m)
 *------------------------------------------------------------------------------
 * Rolls back to a mark, freeing every chunk allocated after it. Returns 0 on
 * success, -1 if the mark is not valid for this arena.
 *
 * Parameters (AAPCS64):
 *   x0 = a (asm_arena *)      - arena to roll back
 *   x1 = m (const asm_mark *) - mark previously filled by asm_arena_mark
 * Returns:
 *   w0 = 0 on success, -1 if the mark is not valid for this arena
 *============================================================================*/
    .globl asm_arena_release
    .type  asm_arena_release, %function
    .p2align 2
asm_arena_release:
    /* ---- prologue: preserve callee-saved registers and lr ---- */
    stp     x19, x20, [sp, #-16]!       /* x19 = a, x20 = mark chunk             */
    stp     x21, x22, [sp, #-16]!       /* x21 = mark ptr, x22 = mark used       */
    stp     x23, x24, [sp, #-16]!       /* x23 = chunk, x24 = free callback      */
    stp     x25, x30, [sp, #-16]!       /* x25 = next link, x30 = lr             */
    mov     x19, x0                     /* x19 = a                               */
    ldr     x20, [x1]                   /* x20 = target chunk                    */
    cbz     x20, .Lrelease_bad          /* mark chunk == NULL -> invalid         */
    /* ---- walk the chunk chain to the mark ---- */
    ldr     x23, [x19, #A_CUR]          /* walk the chunk chain                  */
.Lrelease_walk:
    cbz     x23, .Lrelease_bad          /* end of chain -> mark not in arena     */
    cmp     x23, x20                    /* reached the mark chunk?               */
    b.eq    .Lrelease_found             /* yes -> found it                       */
    ldr     x23, [x23, #C_NEXT]         /* advance to the older chunk            */
    b       .Lrelease_walk
.Lrelease_found:
    /* ---- validate the saved pointer against the chunk ---- */
    ldr     x21, [x1, #8]               /* x21 = target ptr                      */
    ldr     x4, [x20, #C_DATA]          /* x4 = chunk data base                  */
    cmp     x21, x4                     /* mark ptr below data?                  */
    b.lo    .Lrelease_bad
    ldr     x5, [x20, #C_CAP]           /* x5 = data + cap                       */
    add     x5, x4, x5
    cmp     x21, x5                     /* mark ptr above cap?                   */
    b.hi    .Lrelease_bad
    ldr     x22, [x1, #16]              /* x22 = target used                     */
    /* ---- free every chunk newer than the mark ---- */
    ldr     x23, [x19, #A_CUR]          /* free chunks newer than x20            */
    ldr     x24, [x19, #A_FREE]         /* x24 = free callback                   */
.Lrelease_free:
    cmp     x23, x20                    /* reached the mark chunk?               */
    b.eq    .Lrelease_freed             /* yes -> stop freeing                   */
    ldr     x25, [x23, #C_NEXT]         /* x25 = older chunk link                */
    ldr     x4, [x23, #C_CAP]           /* total -= cap                          */
    ldr     x5, [x19, #A_TOTAL]
    sub     x5, x5, x4
    str     x5, [x19, #A_TOTAL]
    cbz     x24, .Lrelease_skip         /* free callback set?                    */
    ldr     x0, [x23, #C_RAW]           /* arg1 = raw base                       */
    ldr     x1, [x23, #C_BSIZE]         /* arg2 = backing size                   */
    ldr     x2, [x19, #A_CTX]           /* arg3 = ctx                            */
    blr     x24                         /* free the chunk                        */
.Lrelease_skip:
    mov     x23, x25                    /* advance to the next older chunk       */
    b       .Lrelease_free
.Lrelease_freed:
    /* ---- restore the marked position ---- */
    str     x20, [x19, #A_CUR]          /* cur = mark chunk                      */
    str     x21, [x19, #A_PTR]          /* ptr = mark position                   */
    ldr     x4, [x20, #C_DATA]          /* end = data + cap                      */
    ldr     x5, [x20, #C_CAP]
    add     x4, x4, x5
    str     x4, [x19, #A_END]
    str     x22, [x19, #A_USED]         /* used = mark used                      */
    mov     w0, #0                      /* return 0 (success)                    */
    b       .Lrelease_done
.Lrelease_bad:
    mov     w0, #-1                     /* return -1 (invalid mark)              */
.Lrelease_done:
    ldp     x25, x30, [sp], #16
    ldp     x23, x24, [sp], #16
    ldp     x21, x22, [sp], #16
    ldp     x19, x20, [sp], #16
    ret
    .size asm_arena_release, .-asm_arena_release

/*==============================================================================
 * void asm_arena_reset(asm_arena *a)
 *------------------------------------------------------------------------------
 * Releases all chunks except the first and rewinds to its start. O(chunks).
 *
 * Parameters (AAPCS64):
 *   x0 = a (asm_arena *) - arena to reset
 *============================================================================*/
    .globl asm_arena_reset
    .type  asm_arena_reset, %function
    .p2align 2
asm_arena_reset:
    /* ---- prologue: preserve callee-saved registers and lr ---- */
    stp     x19, x20, [sp, #-16]!       /* x19 = a, x20 = first chunk            */
    stp     x21, x22, [sp, #-16]!       /* x21 = chunk, x22 = free callback      */
    stp     x23, x30, [sp, #-16]!       /* x23 = next link, x30 = lr             */
    mov     x19, x0                     /* x19 = a                               */
    /* ---- start from the first chunk ---- */
    ldr     x20, [x19, #A_FIRST]        /* x20 = first chunk                     */
    cbz     x20, .Lreset_zero           /* growable arena with no chunk yet      */
    ldr     x21, [x19, #A_CUR]          /* free everything after the first       */
    ldr     x22, [x19, #A_FREE]         /* x22 = free callback                   */
    /* ---- free every chunk newer than the first ---- */
.Lreset_free:
    cmp     x21, x20                    /* reached the first chunk?              */
    b.eq    .Lreset_freed
    ldr     x23, [x21, #C_NEXT]         /* x23 = older chunk link                */
    ldr     x4, [x21, #C_CAP]           /* total -= cap                          */
    ldr     x5, [x19, #A_TOTAL]
    sub     x5, x5, x4
    str     x5, [x19, #A_TOTAL]
    cbz     x22, .Lreset_skip           /* free callback set?                    */
    ldr     x0, [x21, #C_RAW]           /* arg1 = raw base                       */
    ldr     x1, [x21, #C_BSIZE]         /* arg2 = backing size                   */
    ldr     x2, [x19, #A_CTX]           /* arg3 = ctx                            */
    blr     x22                         /* free the chunk                        */
.Lreset_skip:
    mov     x21, x23                    /* advance to the next older chunk       */
    b       .Lreset_free
.Lreset_freed:
    /* ---- rewind to the start of the first chunk ---- */
    str     x20, [x19, #A_CUR]          /* cur = first chunk                     */
    ldr     x4, [x20, #C_DATA]          /* ptr = first chunk data                */
    str     x4, [x19, #A_PTR]
    ldr     x5, [x20, #C_CAP]           /* end = data + cap                      */
    add     x5, x4, x5
    str     x5, [x19, #A_END]
    ldr     x5, [x20, #C_CAP]           /* total = first chunk cap               */
    str     x5, [x19, #A_TOTAL]
    /* ---- clear the statistics ---- */
.Lreset_zero:
    str     xzr, [x19, #A_USED]         /* used = 0                              */
    str     xzr, [x19, #A_PEAK]         /* peak = 0                              */
    ldp     x23, x30, [sp], #16
    ldp     x21, x22, [sp], #16
    ldp     x19, x20, [sp], #16
    ret
    .size asm_arena_reset, .-asm_arena_reset

/*==============================================================================
 * void asm_arena_destroy(asm_arena *a)
 *------------------------------------------------------------------------------
 * Releases every chunk (when a free callback is set) and zeroes the arena. A
 * fixed arena owns nothing, so only its bookkeeping is cleared.
 *
 * Parameters (AAPCS64):
 *   x0 = a (asm_arena *) - arena to destroy
 *============================================================================*/
    .globl asm_arena_destroy
    .type  asm_arena_destroy, %function
    .p2align 2
asm_arena_destroy:
    /* ---- prologue: preserve callee-saved registers and lr ---- */
    stp     x19, x20, [sp, #-16]!       /* x19 = a, x20 = chunk                  */
    stp     x21, x22, [sp, #-16]!       /* x21 = free callback, x22 = next link  */
    str     x30, [sp, #-16]!
    mov     x19, x0                     /* x19 = a                               */
    ldr     x21, [x19, #A_FREE]         /* x21 = free callback                   */
    ldr     x20, [x19, #A_CUR]          /* x20 = newest chunk                    */
    /* ---- free every chunk in the chain ---- */
.Ldestroy_free:
    cbz     x20, .Ldestroy_cleared      /* no more chunks -> clear structure     */
    ldr     x22, [x20, #C_NEXT]         /* x22 = older chunk link                */
    cbz     x21, .Ldestroy_skip         /* free callback set?                    */
    ldr     x0, [x20, #C_RAW]           /* arg1 = raw base                       */
    ldr     x1, [x20, #C_BSIZE]         /* arg2 = backing size                   */
    ldr     x2, [x19, #A_CTX]           /* arg3 = ctx                            */
    blr     x21                         /* free the chunk                        */
.Ldestroy_skip:
    mov     x20, x22                    /* advance to the next older chunk       */
    b       .Ldestroy_free
    /* ---- zero the whole 88-byte arena structure ---- */
.Ldestroy_cleared:
    stp     xzr, xzr, [x19, #0]
    stp     xzr, xzr, [x19, #16]
    stp     xzr, xzr, [x19, #32]
    stp     xzr, xzr, [x19, #48]
    stp     xzr, xzr, [x19, #64]
    str     xzr, [x19, #80]
    ldr     x30, [sp], #16
    ldp     x21, x22, [sp], #16
    ldp     x19, x20, [sp], #16
    ret
    .size asm_arena_destroy, .-asm_arena_destroy

/*==============================================================================
 * size_t asm_arena_used(const asm_arena *a)
 *------------------------------------------------------------------------------
 * Bytes handed out since the last reset.
 *============================================================================*/
    .globl asm_arena_used
    .type  asm_arena_used, %function
    .p2align 2
asm_arena_used:
    ldr     x0, [x0, #A_USED]           /* return a->used                        */
    ret
    .size asm_arena_used, .-asm_arena_used

/*==============================================================================
 * size_t asm_arena_peak(const asm_arena *a)
 *------------------------------------------------------------------------------
 * High-water mark of asm_arena_used() since the last reset.
 *============================================================================*/
    .globl asm_arena_peak
    .type  asm_arena_peak, %function
    .p2align 2
asm_arena_peak:
    ldr     x0, [x0, #A_PEAK]           /* return a->peak                        */
    ret
    .size asm_arena_peak, .-asm_arena_peak

/*==============================================================================
 * size_t asm_arena_remaining(const asm_arena *a)
 *------------------------------------------------------------------------------
 * Free bytes left in the current chunk.
 *============================================================================*/
    .globl asm_arena_remaining
    .type  asm_arena_remaining, %function
    .p2align 2
asm_arena_remaining:
    ldr     x1, [x0, #A_END]            /* remaining = end - ptr                 */
    ldr     x2, [x0, #A_PTR]
    sub     x0, x1, x2
    ret
    .size asm_arena_remaining, .-asm_arena_remaining

/*==============================================================================
 * size_t asm_arena_capacity(const asm_arena *a)
 *------------------------------------------------------------------------------
 * Total usable bytes currently backed by all chunks.
 *============================================================================*/
    .globl asm_arena_capacity
    .type  asm_arena_capacity, %function
    .p2align 2
asm_arena_capacity:
    ldr     x0, [x0, #A_TOTAL]          /* return a->total                       */
    ret
    .size asm_arena_capacity, .-asm_arena_capacity

GNU_STACK_NOTE
