/*==============================================================================
 * alloc.S - malloc/calloc/realloc/free backed directly by mmap (AArch64)
 *------------------------------------------------------------------------------
 * SPDX-License-Identifier: MIT
 *
 * AArch64 port of src/alloc.asm. A compact segregated free-list allocator with
 * no libc dependency:
 *
 *   void  *asm_malloc (size_t size);
 *   void  *asm_calloc (size_t count, size_t size);
 *   void  *asm_realloc(void *ptr, size_t size);
 *   void   asm_free   (void *ptr);
 *   void  *asm_reallocarray(void *ptr, size_t count, size_t size);
 *   void  *asm_aligned_alloc(size_t alignment, size_t size);
 *   int    asm_posix_memalign(void **memptr, size_t alignment, size_t size);
 *   size_t asm_malloc_usable_size(void *ptr);
 *
 * Strategy
 * --------
 * * Requests up to SMALL_TOTAL_MAX (header + payload <= 4096) are rounded up to
 *   a 16-byte class and served from a per-class free list. An empty class is
 *   replenished by mapping a "run" and pushing every block in it onto the free
 *   list (a slab). Freed blocks go straight back onto their class list.
 * * Larger requests get their own page-rounded anonymous mapping, stored with
 *   its length so asm_free can munmap it exactly.
 * * Every returned pointer is 16-byte aligned. Blocks carry a 16-byte header
 *   immediately before the payload holding the class index (-1 for a large
 *   mapping, -2 for an aligned/indirect block) and, for large blocks, the
 *   mapped size. An indirect header stores the backing asm_malloc block so the
 *   over-aligned pointer frees exactly what it borrowed.
 * * Over-aligned requests bigger than 16 bytes are satisfied by allocating a
 *   backing block with room for the alignment slack, then stamping an indirect
 *   header in front of the aligned payload.
 *
 * Thread safety
 * -------------
 * Each thread keeps a small thread-local cache (tcache) of freed small blocks:
 * malloc pops from it and free pushes to it without taking malloc_lock, so the
 * uncontended common case stays a few instructions. The global spinlock then
 * only guards run refills, over-budget frees, large mappings and the aligned
 * machinery. The cache is bounded by a per-thread byte budget (TCACHE_BUDGET)
 * so memory cannot be retained without limit. The trade-off is that blocks
 * still parked in a thread's cache when that thread exits are not reclaimed:
 * flushing them would need a pthread/libc thread-exit hook, which this library
 * deliberately does not depend on.
 *
 * The cache lives in ELF local-exec TLS. The aarch64 build is static, so the
 * linker resolves the thread-pointer offsets directly; the runtime must have set
 * the thread pointer up (the malloc heap already targets Linux). The lock is a
 * simple acquire/release spinlock built from `ldaxr`/`stxr`, with `wfe` as the
 * contention hint. It is not async-signal-safe: do not call these routines from
 * a signal handler that may interrupt an allocation on the same thread.
 * Small-run memory is never returned to the kernel (like a slab); large blocks
 * are.
 *
 * AAPCS64 notes: arguments arrive in x0..x7 and the result leaves in x0;
 * x19..x28 are callee-saved and x30 (lr) is saved across any call. Registers
 * are paired with stp/ldp so the stack stays 16-byte aligned for calls.
 *============================================================================*/

#include "common_aarch64.inc"

#define SMALL_TOTAL_MAX 4096            /* header+payload at or below stays small */
#define RUN_SIZE        65536           /* target bytes per slab run              */
#define HDR             16              /* per-block header size in bytes         */
#define NUM_CLASSES     512             /* free-list slots (max class index 256)  */
#define INDIRECT        (-2)            /* aligned/indirect block marker          */
#define SIZE_MAX        (-1)            /* largest representable size_t           */
#define TC_CLASSES      (SMALL_TOTAL_MAX / HDR + 1) /* tcache bins (classes 0..256) */
#define TC_BYTES_OFF    (TC_CLASSES * 8) /* byte counter in the TLS block          */
#define TCACHE_BUDGET   (1024 * 1024)   /* cached payload bytes per thread        */

/* ASMLIB_ALLOC_DEBUG: a small block carries this magic in the otherwise-unused
 * second header word while it is on a free list, so freeing it twice traps
 * instead of corrupting the list. Large/indirect blocks cannot be checked. */
#ifdef ASMLIB_ALLOC_DEBUG
#define FREED_MAGIC     0xF4EEF4EEF4EEF4EE
#endif

    .bss
    .align 6
    .type malloc_freelist, %object
malloc_freelist:
    .skip NUM_CLASSES * 8               /* one singly-linked list per size class  */
    .size malloc_freelist, NUM_CLASSES * 8
    .align 6
    .type malloc_lock, %object
malloc_lock:
    .skip 4                             /* global spinlock: 0 = free, 1 = held    */
    .size malloc_lock, 4

/* Per-thread small-block cache (initial-exec/local-exec TLS, zero-filled by the
 * loader: one LIFO head per small size class followed by the byte counter). */
    .section .tbss,"awT",%nobits
    .align 6
    .globl asm_tcache
    .type asm_tcache, %tls_object
asm_tcache:
    .skip TC_CLASSES * 8                /* tcache_head[]                          */
    .skip 8                             /* tcache_bytes                           */
    .size asm_tcache, TC_CLASSES * 8 + 8

    .text

/*==============================================================================
 * internal: L_lock(void)
 *------------------------------------------------------------------------------
 * Acquires malloc_lock, spinning until it observes the lock free. ldaxr/stxr
 * form an atomic load-acquire/test-and-set; `wfe` is the contention hint. Only
 * the caller-saved scratch registers x9..x11 are clobbered, so the AAPCS64
 * argument registers x0..x7 survive the call (mirroring the x86 L_lock, which
 * clobbers only eax).
 *============================================================================*/
    .type  L_lock, %function
    .p2align 2
L_lock:
    adrp    x9, malloc_lock
    add     x9, x9, :lo12:malloc_lock
    mov     w10, #1                     /* value to store into the lock          */
.Llock_retry:
    ldaxr   w11, [x9]                   /* load-acquire exclusive                */
    cbnz    w11, .Llock_spin            /* already held -> back off              */
    stxr    w11, w10, [x9]              /* try to claim the lock                 */
    cbnz    w11, .Llock_retry           /* store failed -> retry                 */
    ret                                 /* lock acquired                         */
.Llock_spin:
    wfe                                 /* spin hint while contended             */
    b       .Llock_retry
    .size L_lock, .-L_lock

/*==============================================================================
 * internal: L_unlock(void)
 *------------------------------------------------------------------------------
 * Releases malloc_lock with a store-release. Only x9 is clobbered.
 *============================================================================*/
    .type  L_unlock, %function
    .p2align 2
L_unlock:
    adrp    x9, malloc_lock
    add     x9, x9, :lo12:malloc_lock
    stlr    wzr, [x9]                   /* mark the lock free (release)          */
    ret
    .size L_unlock, .-L_unlock

/*==============================================================================
 * internal: L_malloc(size_t size) -> void *
 *------------------------------------------------------------------------------
 * Unlocked core of asm_malloc. Returns a 16-byte aligned block of at least
 * size bytes, or NULL. Callers must already hold malloc_lock.
 *
 * Parameters (AAPCS64):
 *   x0 = size (size_t) - requested payload size (0 is treated as 1)
 * Returns:
 *   x0 = payload pointer, or NULL on overflow or mmap failure
 *============================================================================*/
    .type  L_malloc, %function
    .p2align 2
L_malloc:
    /* ---- prologue: preserve callee-saved registers and lr ---- */
    stp     x19, x20, [sp, #-16]!       /* x19 = scratch, x20 = total            */
    stp     x21, x30, [sp, #-16]!       /* x21 = class index                     */
    /* ---- normalise a zero-size request ---- */
    cbnz    x0, .Lmalloc_nonzero        /* malloc(0) -> a unique small block     */
    mov     x0, #1                      /* treat malloc(0) as 1 byte             */
.Lmalloc_nonzero:
    /* ---- size the payload and derive the class ---- */
    adds    x1, x0, #15                 /* align the payload to 16               */
    b.cs    .Lmalloc_fail               /* size overflow -> fail                 */
    and     x1, x1, #-16                /* x1 = 16-aligned payload               */
    adds    x20, x1, #HDR               /* total = aligned payload + header      */
    b.cs    .Lmalloc_fail               /* total overflow -> fail                */
    cmp     x20, #SMALL_TOTAL_MAX       /* small class?                          */
    b.hi    .Lmalloc_large              /* header + payload > small max -> large */
    /* ---- small class: pop from its free list ---- */
    lsr     x21, x20, #4                /* class index = total / 16              */
    adrp    x9, malloc_freelist
    add     x9, x9, :lo12:malloc_freelist
    ldr     x0, [x9, x21, lsl #3]       /* pop the free list                     */
    cbz     x0, .Lmalloc_run            /* free list empty -> replenish          */
    ldr     x10, [x0]                   /* x10 = next                            */
    str     x10, [x9, x21, lsl #3]      /* class head = next block               */
    sub     x11, x0, #HDR               /* stamp the class index                 */
    str     x21, [x11]
    str     xzr, [x11, #8]              /* clear large-size slot in header       */
    b       .Lmalloc_done               /* return the popped block               */
    /* ---- small class: replenish from a new run ---- */
.Lmalloc_run:
    mov     x0, x21                     /* replenish this class from a new run   */
    bl      L_alloc_run                 /* replenish the class and pop one       */
    b       .Lmalloc_done               /* return the block from the run         */
    /* ---- large: page-rounded anonymous mapping ---- */
.Lmalloc_large:
    mov     x19, x1                     /* x19 = aligned payload                 */
    add     x19, x19, #HDR              /* base + header                         */
    adds    x19, x19, #(PAGE_SIZE - 1)  /* page-round the mapping size           */
    b.cs    .Lmalloc_fail               /* round-up overflow -> fail             */
    and     x19, x19, #-PAGE_SIZE       /* page-round the mapping size           */
    mov     x0, x19                     /* arg1 = mapping size                   */
    bl      asm_sys_mmap                /* map the large block                   */
    cbz     x0, .Lmalloc_fail           /* mmap failed -> fail                   */
    mov     x1, #-1                     /* mark as a large mapping               */
    str     x1, [x0]
    str     x19, [x0, #8]               /* remember the mapped length            */
    add     x0, x0, #HDR                /* payload = base + header               */
.Lmalloc_done:
    ldp     x21, x30, [sp], #16
    ldp     x19, x20, [sp], #16
    ret
.Lmalloc_fail:
    mov     x0, xzr                     /* return NULL (failure)                 */
    ldp     x21, x30, [sp], #16
    ldp     x19, x20, [sp], #16
    ret
    .size L_malloc, .-L_malloc

/*==============================================================================
 * internal: L_malloc_fast(size_t size) -> void *
 *------------------------------------------------------------------------------
 * Front end shared by asm_malloc and asm_calloc. Small requests are served from
 * the calling thread's tcache without touching malloc_lock; a miss, a large
 * request or an overflow falls through to L_malloc under the lock.
 *
 * Parameters (AAPCS64):
 *   x0 = size (size_t) - requested payload size
 * Returns:
 *   x0 = payload pointer, or NULL
 *============================================================================*/
    .type  L_malloc_fast, %function
    .p2align 2
L_malloc_fast:
    /* ---- normalise a zero-size request (as L_malloc does) ---- */
    cbnz    x0, .Lmf_nonzero            /* malloc(0) -> a unique small block     */
    mov     x0, #1                      /* treat malloc(0) as 1 byte             */
.Lmf_nonzero:
    /* ---- size the payload and derive the class ---- */
    adds    x1, x0, #15                 /* align the payload to 16               */
    b.cs    .Lmf_slow                   /* size overflow -> let L_malloc fail    */
    and     x1, x1, #-16                /* x1 = 16-aligned payload               */
    adds    x2, x1, #HDR                /* total = aligned payload + header      */
    b.cs    .Lmf_slow                   /* total overflow -> locked path         */
    cmp     x2, #SMALL_TOTAL_MAX        /* small class?                          */
    b.hi    .Lmf_slow                   /* large -> locked path                  */
    /* ---- small: pop from the thread-local cache (no lock) ---- */
    lsr     x3, x2, #4                  /* class index = total / 16              */
    mrs     x9, tpidr_el0               /* x9 = thread pointer                   */
    add     x9, x9, :tprel_hi12:asm_tcache
    add     x9, x9, :tprel_lo12_nc:asm_tcache   /* x9 = this thread's tcache    */
    ldr     x4, [x9, x3, lsl #3]        /* tc_head[class] (x0 still holds size)  */
    cbz     x4, .Lmf_slow               /* empty -> locked refill path           */
    ldr     x10, [x4]                   /* next = block->next                    */
    str     x10, [x9, x3, lsl #3]       /* tc_head[class] = next                 */
    lsl     x10, x3, #4                 /* class bytes = class * 16              */
    ldr     x11, [x9, #TC_BYTES_OFF]    /* tc_bytes                              */
    sub     x11, x11, x10               /* tc_bytes -= class bytes               */
    str     x11, [x9, #TC_BYTES_OFF]
    sub     x11, x4, #HDR               /* stamp the class index                 */
    str     x3, [x11]
    str     xzr, [x11, #8]              /* clear the large-size slot             */
    mov     x0, x4                      /* return the cached block               */
    ret
    /* ---- miss / large / overflow: take the lock ---- */
.Lmf_slow:
    stp     x19, x30, [sp, #-16]!       /* preserve scratch + lr, keep aligned   */
    bl      L_lock                      /* enter the critical section            */
    bl      L_malloc                    /* allocate under the lock               */
    mov     x19, x0                     /* stash the result across the unlock    */
    bl      L_unlock                    /* leave the critical section            */
    mov     x0, x19                     /* restore the result                    */
    ldp     x19, x30, [sp], #16
    ret
    .size L_malloc_fast, .-L_malloc_fast

/*==============================================================================
 * void *asm_malloc(size_t size)
 *------------------------------------------------------------------------------
 * Thread-safe front end: thread-local fast path with a locked fallback.
 *
 * Parameters (AAPCS64):
 *   x0 = size (size_t) - requested payload size
 * Returns:
 *   x0 = payload pointer, or NULL
 *============================================================================*/
    .globl asm_malloc
    .type  asm_malloc, %function
    .p2align 2
asm_malloc:
    b       L_malloc_fast               /* share the fast + locked front end     */
    .size asm_malloc, .-asm_malloc

/*==============================================================================
 * internal: L_free(void *ptr) -> void
 *------------------------------------------------------------------------------
 * Unlocked core of asm_free. Releases a block from asm_malloc (ptr may be NULL).
 * Callers must already hold malloc_lock.
 *
 * Parameters (AAPCS64):
 *   x0 = ptr (void *) - block previously returned by asm_malloc
 *============================================================================*/
    .type  L_free, %function
    .p2align 2
L_free:
    /* ---- NULL is a no-op ---- */
    cbz     x0, .Lfree_ret              /* free(NULL) is a no-op                 */
    /* ---- recover the class index from the header ---- */
    ldr     x1, [x0, #-HDR]             /* class index, -1 or -2                 */
    cmn     x1, #1                      /* large mapping marker?                 */
    b.eq    .Lfree_large                /* yes -> munmap it                      */
    cmn     x1, #2                      /* aligned/indirect marker?              */
    b.eq    .Lfree_indirect             /* yes -> release the backing block      */
    /* ---- small: push the block onto its class list ---- */
    adrp    x9, malloc_freelist
    add     x9, x9, :lo12:malloc_freelist
    ldr     x10, [x9, x1, lsl #3]       /* x10 = old list head                   */
    str     x10, [x0]                   /* block->next = old head                */
    str     x0, [x9, x1, lsl #3]        /* class head = this block               */
.Lfree_ret:
    ret                                 /* return (small block recycled)         */
    /* ---- indirect: free the backing block instead ---- */
.Lfree_indirect:
    ldr     x0, [x0, #-HDR + 8]         /* x0 = orig backing block               */
    cbz     x0, .Lfree_ret              /* orig == NULL -> nothing to release    */
    str     x30, [sp, #-16]!            /* preserve lr, keep rsp aligned         */
    bl      L_free                      /* recurse (orig is never indirect)      */
    ldr     x30, [sp], #16
    ret
    /* ---- large: unmap the whole mapping ---- */
.Lfree_large:
    ldr     x1, [x0, #-HDR + 8]         /* mapped length                         */
    sub     x0, x0, #HDR                /* mapping base                          */
    str     x30, [sp, #-16]!            /* preserve lr, keep rsp aligned         */
    bl      asm_sys_munmap              /* release the mapping (under the lock)  */
    ldr     x30, [sp], #16
    ret
    .size L_free, .-L_free

/*==============================================================================
 * void asm_free(void *ptr)
 *------------------------------------------------------------------------------
 * Thread-safe front end. A small block is parked on the calling thread's tcache
 * (without malloc_lock) while that stays within TCACHE_BUDGET; over-budget
 * frees, large mappings and indirect blocks go through L_free under the lock.
 *
 * Parameters (AAPCS64):
 *   x0 = ptr (void *) - block previously returned by asm_malloc
 *============================================================================*/
    .globl asm_free
    .type  asm_free, %function
    .p2align 2
asm_free:
    /* ---- NULL is a no-op ---- */
    cbz     x0, .Lasmfree_ret           /* free(NULL) is a no-op                 */
    /* ---- recover the class index from the header ---- */
    ldr     x1, [x0, #-HDR]             /* class index, -1 or -2                 */
    cmn     x1, #1                      /* large mapping marker?                 */
    b.eq    .Lasmfree_slow              /* yes -> release under the lock         */
    cmn     x1, #2                      /* aligned/indirect marker?              */
    b.eq    .Lasmfree_slow              /* yes -> release under the lock         */
#ifdef ASMLIB_ALLOC_DEBUG
    /* ---- debug: catch a double free of a small block ---- */
    ldr     x9, =FREED_MAGIC
    ldr     x10, [x0, #-HDR + 8]
    cmp     x10, x9
    b.eq    .Lasmfree_double
    str     x9, [x0, #-HDR + 8]
#endif
    /* ---- small: park it on this thread's cache if there is budget ---- */
    lsl     x2, x1, #4                  /* class bytes = class * 16              */
    mrs     x9, tpidr_el0               /* x9 = thread pointer                   */
    add     x9, x9, :tprel_hi12:asm_tcache
    add     x9, x9, :tprel_lo12_nc:asm_tcache   /* x9 = this thread's tcache    */
    ldr     x10, [x9, #TC_BYTES_OFF]    /* tc_bytes                              */
    add     x10, x10, x2                /* projected total                       */
    mov     x11, #TCACHE_BUDGET
    cmp     x10, x11                    /* over the per-thread budget?           */
    b.hi    .Lasmfree_slow              /* yes -> give it to the global heap     */
    str     x10, [x9, #TC_BYTES_OFF]    /* commit the new total                  */
    ldr     x10, [x9, x1, lsl #3]       /* old head                              */
    str     x10, [x0]                   /* block->next = old head                */
    str     x0, [x9, x1, lsl #3]        /* tc_head[class] = block                */
.Lasmfree_ret:
    ret                                 /* return (block cached or NULL)         */
#ifdef ASMLIB_ALLOC_DEBUG
.Lasmfree_double:
    brk     #0                          /* trap: double free of a small block    */
#endif
    /* ---- large/indirect: take the lock ---- */
.Lasmfree_slow:
    str     x30, [sp, #-16]!            /* preserve lr, keep rsp aligned         */
    bl      L_lock                      /* enter the critical section            */
    bl      L_free                      /* release under the lock                */
    bl      L_unlock                    /* leave the critical section            */
    ldr     x30, [sp], #16
    ret
    .size asm_free, .-asm_free

/*==============================================================================
 * size_t asm_alloc_flush_tcache(void)
 *------------------------------------------------------------------------------
 * Move every block parked in the calling thread's tcache back onto the shared
 * class lists and return how many were returned. Call it from a thread-exit
 * hook so a short-lived thread does not strand its per-thread cache budget.
 *============================================================================*/
    .globl asm_alloc_flush_tcache
    .type  asm_alloc_flush_tcache, %function
    .p2align 2
asm_alloc_flush_tcache:
    stp     x19, x20, [sp, #-16]!       /* count, tcache base                    */
    stp     x21, x22, [sp, #-16]!       /* free-list base, class index           */
    str     x30, [sp, #-16]!
    mrs     x20, tpidr_el0
    add     x20, x20, :tprel_hi12:asm_tcache
    add     x20, x20, :tprel_lo12_nc:asm_tcache   /* x20 = this thread's tcache */
    ldr     x9, [x20, #TC_BYTES_OFF]
    cbz     x9, .Lflush_none
    mov     x19, #0                     /* returned block count                  */
    bl      L_lock                      /* enter the critical section            */
    adrp    x21, malloc_freelist
    add     x21, x21, :lo12:malloc_freelist
    mov     x22, #0                     /* class index                           */
.Lflush_class:
    ldr     x0, [x20, x22, lsl #3]      /* tcache head for this class            */
    cbz     x0, .Lflush_next
    str     xzr, [x20, x22, lsl #3]     /* detach the chain                      */
.Lflush_block:
    ldr     x1, [x0]                    /* next                                  */
    ldr     x2, [x21, x22, lsl #3]      /* global head                           */
    str     x2, [x0]                    /* block->next = global head             */
    str     x0, [x21, x22, lsl #3]      /* global head = block                   */
    add     x19, x19, #1
    mov     x0, x1
    cbnz    x0, .Lflush_block
.Lflush_next:
    add     x22, x22, #1
    cmp     x22, #TC_CLASSES
    b.lo    .Lflush_class
    str     xzr, [x20, #TC_BYTES_OFF]   /* cache is empty again                  */
    bl      L_unlock                    /* leave the critical section            */
    mov     x0, x19
    ldr     x30, [sp], #16
    ldp     x21, x22, [sp], #16
    ldp     x19, x20, [sp], #16
    ret
.Lflush_none:
    mov     x0, #0                      /* nothing cached                        */
    ldr     x30, [sp], #16
    ldp     x21, x22, [sp], #16
    ldp     x19, x20, [sp], #16
    ret
    .size asm_alloc_flush_tcache, .-asm_alloc_flush_tcache

/*==============================================================================
 * void *asm_calloc(size_t count, size_t size)
 *------------------------------------------------------------------------------
 * Allocates count*size zeroed bytes, or NULL on overflow/exhaustion.
 *
 * Parameters (AAPCS64):
 *   x0 = count (size_t) - element count
 *   x1 = size  (size_t) - element size in bytes
 * Returns:
 *   x0 = zeroed block, or NULL on overflow or allocation failure
 *============================================================================*/
    .globl asm_calloc
    .type  asm_calloc, %function
    .p2align 2
asm_calloc:
    /* ---- prologue: preserve callee-saved registers and lr ---- */
    stp     x19, x20, [sp, #-16]!       /* x19 = total, x20 = block              */
    str     x30, [sp, #-16]!
    /* ---- count * size with overflow check ---- */
    umulh   x2, x0, x1                  /* high half of count * size             */
    cbnz    x2, .Lcalloc_fail           /* product overflowed 64 bits -> fail    */
    mul     x19, x0, x1                 /* x19 = total bytes                     */
    cbnz    x19, .Lcalloc_go            /* count*size == 0?                      */
    mov     x19, #1                     /* treat zero request as 1 byte          */
.Lcalloc_go:
    /* ---- allocate (thread-local fast path, else under the lock) ---- */
    mov     x0, x19                     /* arg1 = total bytes                    */
    bl      L_malloc_fast               /* allocate the block                    */
    mov     x20, x0                     /* keep the block                        */
    /* ---- zero the block (it is on no free list) ---- */
    cbz     x20, .Lcalloc_fail          /* allocation failed -> return NULL      */
    mov     x0, x20                     /* arg1 = block                          */
    mov     w1, #0                      /* fill byte = 0                         */
    mov     x2, x19                     /* arg3 = total bytes                    */
    bl      asm_memset                  /* zero it                               */
    mov     x0, x20                     /* return the block                      */
    b       .Lcalloc_done
.Lcalloc_fail:
    mov     x0, xzr                     /* return NULL (failure)                 */
.Lcalloc_done:
    ldr     x30, [sp], #16
    ldp     x19, x20, [sp], #16
    ret
    .size asm_calloc, .-asm_calloc

/*==============================================================================
 * internal: L_usable_size(void *ptr) -> size_t
 *------------------------------------------------------------------------------
 * Unlocked core of asm_malloc_usable_size. Usable payload bytes in a block from
 * asm_malloc, or 0 for NULL. Callers must already hold malloc_lock.
 *
 * Parameters (AAPCS64):
 *   x0 = ptr (void *) - block previously returned by asm_malloc, or NULL
 * Returns:
 *   x0 = usable payload bytes, or 0 when ptr is NULL
 *============================================================================*/
    .type  L_usable_size, %function
    .p2align 2
L_usable_size:
    /* ---- NULL has no usable bytes ---- */
    cbz     x0, .Lusable_null           /* ptr == NULL -> 0                      */
    /* ---- decode the header marker ---- */
    ldr     x1, [x0, #-HDR]             /* class index, -1 or -2                 */
    cmn     x1, #1                      /* large mapping marker?                 */
    b.eq    .Lusable_large              /* yes -> mapped length in header        */
    cmn     x1, #2                      /* aligned/indirect marker?              */
    b.eq    .Lusable_indirect           /* yes -> ask the backing block          */
    /* ---- small class: usable = class_size - header ---- */
    lsl     x0, x1, #4                  /* class size                            */
    sub     x0, x0, #HDR                /* minus the block header                */
    ret
.Lusable_large:
    ldr     x0, [x0, #-HDR + 8]         /* mapped length                         */
    sub     x0, x0, #HDR                /* minus the block header                */
    ret
.Lusable_indirect:
    /* ---- indirect: backing usable minus the alignment offset ---- */
    ldr     x2, [x0, #-HDR + 8]         /* x2 = orig backing block               */
    ldr     x1, [x2, #-HDR]             /* backing class index (never indirect)  */
    cmn     x1, #1                      /* backing is a large mapping?           */
    b.eq    .Lusable_ind_large
    lsl     x3, x1, #4                  /* backing class size                    */
    sub     x3, x3, #HDR                /* backing usable                        */
    b       .Lusable_ind_sub            /* apply the alignment offset            */
.Lusable_ind_large:
    ldr     x3, [x2, #-HDR + 8]         /* backing mapped length                 */
    sub     x3, x3, #HDR                /* backing usable                        */
.Lusable_ind_sub:
    sub     x0, x0, x2                  /* x0 = ptr - orig (alignment offset)    */
    sub     x0, x3, x0                  /* usable -= offset                      */
    ret
.Lusable_null:
    mov     x0, xzr                     /* return 0                              */
    ret
    .size L_usable_size, .-L_usable_size

/*==============================================================================
 * size_t asm_malloc_usable_size(void *ptr)
 *------------------------------------------------------------------------------
 * Thread-safe front end: holds malloc_lock while L_usable_size reads the header.
 *
 * Parameters (AAPCS64):
 *   x0 = ptr (void *) - block previously returned by asm_malloc, or NULL
 * Returns:
 *   x0 = usable payload bytes, or 0 when ptr is NULL
 *============================================================================*/
    .globl asm_malloc_usable_size
    .type  asm_malloc_usable_size, %function
    .p2align 2
asm_malloc_usable_size:
    stp     x19, x30, [sp, #-16]!       /* preserve lr, keep rsp aligned         */
    bl      L_lock                      /* enter the critical section            */
    bl      L_usable_size               /* read the header under the lock        */
    mov     x19, x0                     /* stash the result across the unlock    */
    bl      L_unlock                    /* leave the critical section            */
    mov     x0, x19                     /* restore the result                    */
    ldp     x19, x30, [sp], #16
    ret
    .size asm_malloc_usable_size, .-asm_malloc_usable_size

/*==============================================================================
 * internal: L_realloc(void *ptr, size_t size) -> void *
 *------------------------------------------------------------------------------
 * Unlocked core of asm_realloc. Grows or shrinks a block. Keeps the pointer
 * when the request fits the existing usable size, otherwise allocates, copies
 * min(old,new) and frees. Over-aligned (indirect) blocks always move through
 * L_malloc. ptr NULL behaves like L_malloc(size); size 0 frees and returns
 * NULL. Callers must already hold malloc_lock.
 *
 * Parameters (AAPCS64):
 *   x0 = ptr  (void *) - existing block, or NULL
 *   x1 = size (size_t) - requested new payload size
 * Returns:
 *   x0 = resized block, or NULL on overflow or allocation failure
 *============================================================================*/
    .type  L_realloc, %function
    .p2align 2
L_realloc:
    /* ---- prologue: preserve callee-saved registers and lr ---- */
    stp     x19, x20, [sp, #-16]!       /* x19 = ptr,  x20 = new size            */
    stp     x21, x22, [sp, #-16]!       /* x21 = old usable, x22 = new block     */
    stp     x23, x24, [sp, #-16]!       /* x23 = orig backing, x24 = offset      */
    str     x30, [sp, #-16]!
    mov     x19, x0                     /* x19 = ptr                             */
    mov     x20, x1                     /* x20 = new size                        */
    /* ---- handle NULL and zero-size special cases ---- */
    cbz     x19, .Lrealloc_alloc        /* realloc(NULL, n) == malloc(n)         */
    cbz     x20, .Lrealloc_free_null    /* realloc(p, 0) frees p                 */
    /* ---- recover the old usable size from the header ---- */
    ldr     x2, [x19, #-HDR]            /* class index, -1 or -2                 */
    cmn     x2, #1                      /* large mapping marker?                 */
    b.eq    .Lrealloc_large_old         /* yes -> size stored in header          */
    cmn     x2, #2                      /* aligned/indirect marker?              */
    b.eq    .Lrealloc_indirect_old      /* yes -> usable comes from backing block*/
    /* ---- small class: usable = class*16 - header ---- */
    lsl     x2, x2, #4                  /* class size                            */
    sub     x21, x2, #HDR               /* usable = class_size - header          */
    b       .Lrealloc_have_old
.Lrealloc_large_old:
    ldr     x2, [x19, #-HDR + 8]        /* mapped length                         */
    sub     x21, x2, #HDR               /* usable = mapped - header              */
    b       .Lrealloc_have_old
.Lrealloc_indirect_old:
    /* ---- indirect: old usable = backing usable - (ptr - orig) ---- */
    ldr     x23, [x19, #-HDR + 8]       /* x23 = orig backing block              */
    mov     x0, x23                     /* arg1 = orig                           */
    bl      L_usable_size               /* x0 = backing usable                   */
    sub     x24, x19, x23               /* x24 = ptr - orig (header offset)      */
    sub     x21, x0, x24                /* x21 = old usable                      */
.Lrealloc_have_old:
    /* ---- size the requested payload ---- */
    adds    x22, x20, #15               /* needed payload = align16(new)         */
    b.cs    .Lrealloc_fail              /* overflow -> fail                      */
    and     x22, x22, #-16              /* x22 = 16-aligned new size             */
    /* ---- in-place fit check ---- */
    cmp     x22, x21                    /* does it fit in place?                 */
    b.ls    .Lrealloc_inplace           /* fits in place -> keep pointer         */
    /* ---- allocate a new block, copy and free the old ---- */
    mov     x0, x20                     /* allocate a new block                  */
    bl      L_malloc
    cbz     x0, .Lrealloc_fail          /* failed -> return NULL                 */
    mov     x22, x0                     /* x22 = new block                       */
    mov     x2, x21                     /* copy min(old usable, new)             */
    cmp     x2, x20
    csel    x2, x2, x20, ls             /* old usable <= new size ? old : new    */
    mov     x0, x22                     /* arg1 = destination                    */
    mov     x1, x19                     /* arg2 = source                         */
    bl      asm_memcpy                  /* copy the live prefix                  */
    mov     x0, x19                     /* release the old block                 */
    bl      L_free
    mov     x0, x22                     /* return the new block                  */
    b       .Lrealloc_done
.Lrealloc_inplace:
    mov     x0, x19                     /* return ptr (unchanged)                */
    b       .Lrealloc_done
.Lrealloc_alloc:
    mov     x0, x20                     /* arg1 = new size                       */
    bl      L_malloc                    /* realloc(NULL,n) -> malloc(n)          */
    b       .Lrealloc_done
.Lrealloc_free_null:
    mov     x0, x19                     /* arg1 = ptr                            */
    bl      L_free                      /* release the block                     */
    mov     x0, xzr                     /* return NULL                           */
    b       .Lrealloc_done
.Lrealloc_fail:
    mov     x0, xzr                     /* return NULL (failure)                 */
.Lrealloc_done:
    ldr     x30, [sp], #16
    ldp     x23, x24, [sp], #16
    ldp     x21, x22, [sp], #16
    ldp     x19, x20, [sp], #16
    ret
    .size L_realloc, .-L_realloc

/*==============================================================================
 * void *asm_realloc(void *ptr, size_t size)
 *------------------------------------------------------------------------------
 * Thread-safe front end: holds malloc_lock for the whole of L_realloc.
 *
 * Parameters (AAPCS64):
 *   x0 = ptr  (void *) - existing block, or NULL
 *   x1 = size (size_t) - requested new payload size
 * Returns:
 *   x0 = resized block, or NULL
 *============================================================================*/
    .globl asm_realloc
    .type  asm_realloc, %function
    .p2align 2
asm_realloc:
    stp     x19, x30, [sp, #-16]!       /* preserve lr, keep rsp aligned         */
    bl      L_lock                      /* enter the critical section            */
    bl      L_realloc                   /* resize under the lock                 */
    mov     x19, x0                     /* stash the result across the unlock    */
    bl      L_unlock                    /* leave the critical section            */
    mov     x0, x19                     /* restore the result                    */
    ldp     x19, x30, [sp], #16
    ret
    .size asm_realloc, .-asm_realloc

/*==============================================================================
 * void *asm_reallocarray(void *ptr, size_t count, size_t size)
 *------------------------------------------------------------------------------
 * Overflow-checked asm_realloc. When count != 0 and size > SIZE_MAX/count the
 * product would wrap; NULL is returned and ptr is left untouched. Otherwise the
 * request is forwarded to the internal L_realloc under a single lock.
 *
 * Parameters (AAPCS64):
 *   x0 = ptr   (void *) - existing block, or NULL
 *   x1 = count (size_t) - element count
 *   x2 = size  (size_t) - element size in bytes
 * Returns:
 *   x0 = resized block, or NULL on overflow or allocation failure
 *============================================================================*/
    .globl asm_reallocarray
    .type  asm_reallocarray, %function
    .p2align 2
asm_reallocarray:
    /* ---- count == 0: the product is 0 -> realloc(ptr, 0) ---- */
    cbz     x1, .Lreallocarray_zero     /* count == 0 -> forward a zero request  */
    /* ---- overflow check: size > SIZE_MAX / count ? ---- */
    mov     x3, #SIZE_MAX               /* x3 = SIZE_MAX                         */
    udiv    x3, x3, x1                  /* x3 = SIZE_MAX / count                 */
    cmp     x2, x3                      /* size > SIZE_MAX / count?              */
    b.hi    .Lreallocarray_overflow     /* yes -> the product would wrap         */
    /* ---- product is safe: count * size ---- */
    mul     x1, x1, x2                  /* arg2 = count * size (high half 0)     */
    b       .Lreallocarray_locked
.Lreallocarray_zero:
    mov     x1, xzr                     /* arg2 = 0                              */
.Lreallocarray_locked:
    /* ---- serialise the resize with the rest of the heap ---- */
    stp     x19, x30, [sp, #-16]!       /* preserve lr, keep rsp aligned         */
    bl      L_lock                      /* enter the critical section            */
    bl      L_realloc                   /* resize under the lock                 */
    mov     x19, x0                     /* stash the result across the unlock    */
    bl      L_unlock                    /* leave the critical section            */
    mov     x0, x19                     /* restore the result                    */
    ldp     x19, x30, [sp], #16
    ret
.Lreallocarray_overflow:
    mov     x0, xzr                     /* return NULL without touching ptr      */
    ret
    .size asm_reallocarray, .-asm_reallocarray

/*==============================================================================
 * internal: L_aligned_alloc(size_t alignment, size_t size) -> void *
 *------------------------------------------------------------------------------
 * Unlocked core of asm_aligned_alloc. Allocates size bytes whose address is a
 * multiple of alignment (a non-zero power of two), or NULL on invalid alignment
 * or allocation failure. Callers must already hold malloc_lock.
 *
 * Parameters (AAPCS64):
 *   x0 = alignment (size_t) - required alignment (power of two)
 *   x1 = size      (size_t) - requested payload size
 * Returns:
 *   x0 = aligned block, or NULL on invalid alignment or failure
 *============================================================================*/
    .type  L_aligned_alloc, %function
    .p2align 2
L_aligned_alloc:
    /* ---- validate the alignment (non-zero power of two) ---- */
    cbz     x0, .Laligned_bad           /* alignment == 0 -> invalid             */
    sub     x2, x0, #1                  /* x2 = alignment - 1                    */
    tst     x0, x2                      /* more than one bit set?                */
    b.ne    .Laligned_bad               /* not a power of two -> invalid         */
    cmp     x0, #16                     /* alignment <= 16?                      */
    b.hi    .Laligned_big               /* over-aligned -> indirect block        */
    /* ---- alignment <= 16: L_malloc is already 16-byte aligned ---- */
    mov     x0, x1                      /* arg1 = size                           */
    b       L_malloc                    /* tail-call malloc(size)                */
    /* ---- over-aligned: carve an indirect block ---- */
.Laligned_big:
    /* ---- prologue: preserve callee-saved registers and lr ---- */
    stp     x19, x20, [sp, #-16]!       /* x19 = alignment, x20 = size           */
    stp     x21, x22, [sp, #-16]!       /* x21 = total, x22 = orig backing        */
    stp     x23, x30, [sp, #-16]!       /* x23 = aligned payload                 */
    mov     x19, x0                     /* x19 = alignment                       */
    mov     x20, x1                     /* x20 = size                            */
    /* ---- total = size + alignment + header (with overflow checks) ---- */
    adds    x21, x20, x19               /* total = size + alignment              */
    b.cs    .Laligned_fail
    adds    x21, x21, #HDR              /* total += header                       */
    b.cs    .Laligned_fail
    /* ---- allocate the backing block ---- */
    mov     x0, x21                     /* arg1 = total bytes                    */
    bl      L_malloc                    /* orig = malloc(total)                  */
    cbz     x0, .Laligned_fail          /* failed -> return NULL                 */
    mov     x22, x0                     /* x22 = orig backing block              */
    /* ---- p = align_up(orig + header, alignment) ---- */
    add     x1, x22, #HDR               /* x1 = orig + header                    */
    sub     x2, x19, #1                 /* x2 = alignment - 1                    */
    add     x1, x1, x2                  /* x1 = orig + header + alignment - 1    */
    mvn     x2, x2                      /* x2 = ~(alignment - 1)                 */
    and     x23, x1, x2                 /* x23 = align_up(orig + header, align)  */
    /* ---- stamp the indirect header just before p ---- */
    sub     x3, x23, #HDR               /* x3 = p - header                       */
    mov     x4, #INDIRECT               /* qword0 = indirect marker              */
    str     x4, [x3]
    str     x22, [x3, #8]               /* qword1 = orig backing block           */
    mov     x0, x23                     /* return the aligned payload            */
    b       .Laligned_done
.Laligned_fail:
    mov     x0, xzr                     /* return NULL (failure)                 */
.Laligned_done:
    ldp     x23, x30, [sp], #16
    ldp     x21, x22, [sp], #16
    ldp     x19, x20, [sp], #16
    ret
.Laligned_bad:
    mov     x0, xzr                     /* return NULL (bad alignment)           */
    ret
    .size L_aligned_alloc, .-L_aligned_alloc

/*==============================================================================
 * void *asm_aligned_alloc(size_t alignment, size_t size)
 *------------------------------------------------------------------------------
 * Thread-safe front end: holds malloc_lock for the whole of L_aligned_alloc.
 *
 * Parameters (AAPCS64):
 *   x0 = alignment (size_t) - required alignment (power of two)
 *   x1 = size      (size_t) - requested payload size
 * Returns:
 *   x0 = aligned block, or NULL on invalid alignment or failure
 *============================================================================*/
    .globl asm_aligned_alloc
    .type  asm_aligned_alloc, %function
    .p2align 2
asm_aligned_alloc:
    stp     x19, x30, [sp, #-16]!       /* preserve lr, keep rsp aligned         */
    bl      L_lock                      /* enter the critical section            */
    bl      L_aligned_alloc             /* allocate under the lock               */
    mov     x19, x0                     /* stash the result across the unlock    */
    bl      L_unlock                    /* leave the critical section            */
    mov     x0, x19                     /* restore the result                    */
    ldp     x19, x30, [sp], #16
    ret
    .size asm_aligned_alloc, .-asm_aligned_alloc

/*==============================================================================
 * int asm_posix_memalign(void **memptr, size_t alignment, size_t size)
 *------------------------------------------------------------------------------
 * POSIX posix_memalign: stores an `alignment`-aligned block of `size` bytes at
 * *memptr and returns 0; returns EINVAL(22) for an alignment that is not a
 * power of two or is below sizeof(void*), and ENOMEM(12) on allocation failure.
 * *memptr is left untouched on both error paths.
 *
 * Parameters (AAPCS64):
 *   x0 = memptr    (void **) - out-parameter receiving the block
 *   x1 = alignment (size_t)  - required alignment (power of two, >= 8)
 *   x2 = size      (size_t)  - requested payload size
 * Returns:
 *   w0 = 0 on success, EINVAL(22) on bad alignment, ENOMEM(12) on failure
 *============================================================================*/
    .globl asm_posix_memalign
    .type  asm_posix_memalign, %function
    .p2align 2
asm_posix_memalign:
    /* ---- prologue: preserve the out-parameter and lr ---- */
    stp     x19, x30, [sp, #-16]!
    mov     x19, x0                     /* x19 = memptr                          */
    /* ---- validate the alignment (non-zero power of two, >= sizeof(void*)) ---- */
    cbz     x1, .Lposix_einval          /* alignment == 0 -> EINVAL              */
    sub     x3, x1, #1                  /* x3 = alignment - 1                    */
    tst     x1, x3                      /* more than one bit set?                */
    b.ne    .Lposix_einval              /* not a power of two -> EINVAL          */
    cmp     x1, #8                      /* alignment < sizeof(void*)?            */
    b.lo    .Lposix_einval              /* too small -> EINVAL                   */
    /* ---- allocate under the lock and hand the block back ---- */
    bl      L_lock                      /* enter the critical section            */
    mov     x0, x1                      /* arg1 = alignment                      */
    mov     x1, x2                      /* arg2 = size                           */
    bl      L_aligned_alloc             /* p = aligned_alloc(align, size)        */
    cbz     x0, .Lposix_enomem          /* failed -> release the lock, ENOMEM    */
    str     x0, [x19]                   /* *memptr = p (only on success)         */
    bl      L_unlock                    /* leave the critical section            */
    mov     w0, #0                      /* return 0 (success)                    */
    b       .Lposix_done
.Lposix_enomem:
    bl      L_unlock                    /* leave the critical section            */
    mov     w0, #12                     /* ENOMEM                                */
    b       .Lposix_done
.Lposix_einval:
    mov     w0, #22                     /* EINVAL (no lock taken)                */
.Lposix_done:
    ldp     x19, x30, [sp], #16
    ret
    .size asm_posix_memalign, .-asm_posix_memalign

/*==============================================================================
 * internal: L_alloc_run(size_t class_index) -> void *block
 *------------------------------------------------------------------------------
 * Maps a fresh run, threads every block onto the class free list and returns
 * one block (or NULL). The run memory is retained for later reuse.
 *
 * Parameters (AAPCS64):
 *   x0 = class_index (size_t) - size class whose free list is replenished
 * Returns:
 *   x0 = one block from the new run, or NULL on mmap failure
 *============================================================================*/
    .type  L_alloc_run, %function
    .p2align 2
L_alloc_run:
    /* ---- prologue: preserve callee-saved registers and lr ---- */
    stp     x19, x20, [sp, #-16]!       /* x19 = class, x20 = class size         */
    stp     x21, x22, [sp, #-16]!       /* x21 = run size, x22 = run base        */
    stp     x23, x24, [sp, #-16]!       /* x23 = block count, x24 = current blk  */
    str     x30, [sp, #-16]!
    mov     x19, x0                     /* x19 = class index                     */
    /* ---- derive the class size and run size ---- */
    lsl     x20, x19, #4                /* x20 = class size                      */
    mov     x21, #RUN_SIZE              /* x21 = target run size                 */
    lsl     x2, x20, #2                 /* run size = max(RUN_SIZE, 4*class)     */
    cmp     x2, x21
    csel    x21, x2, x21, hi            /* 4*class > RUN_SIZE ? 4*class : RUN    */
    /* ---- map the run ---- */
    mov     x0, x21                     /* arg1 = run size                       */
    bl      asm_sys_mmap                /* map the run                           */
    cbz     x0, .Lrun_fail              /* mmap failed -> fail                   */
    mov     x22, x0                     /* x22 = run base                        */
    /* ---- compute how many blocks fit ---- */
    udiv    x23, x21, x20               /* nblocks = run_size / class_size       */
    cbz     x23, .Lrun_fail             /* zero blocks -> fail                   */
    adrp    x9, malloc_freelist         /* x9 = free-list base                   */
    add     x9, x9, :lo12:malloc_freelist
    mov     x3, xzr                     /* block counter                         */
    mov     x24, x22                    /* current block                         */
    /* ---- thread every block onto the class free list ---- */
.Lrun_link:
    add     x4, x24, #HDR               /* payload                               */
    ldr     x5, [x9, x19, lsl #3]       /* link onto the free list               */
    str     x5, [x4]                    /* block->next = old head                */
    str     x4, [x9, x19, lsl #3]       /* class head = this block               */
    add     x24, x24, x20               /* next block                            */
    add     x3, x3, #1                  /* ++block counter                       */
    cmp     x3, x23                     /* threaded every block?                 */
    b.lo    .Lrun_link                  /* no -> thread the next                 */
    /* ---- pop one block for the caller ---- */
    ldr     x0, [x9, x19, lsl #3]       /* pop one for the caller                */
    ldr     x4, [x0]                    /* x4 = next block                       */
    str     x4, [x9, x19, lsl #3]       /* class head = remainder                */
    sub     x5, x0, #HDR                /* stamp its class                       */
    str     x19, [x5]
    str     xzr, [x5, #8]               /* clear large-size slot                 */
    b       .Lrun_done
.Lrun_fail:
    mov     x0, xzr                     /* return NULL (failure)                 */
.Lrun_done:
    ldr     x30, [sp], #16
    ldp     x23, x24, [sp], #16
    ldp     x21, x22, [sp], #16
    ldp     x19, x20, [sp], #16
    ret
    .size L_alloc_run, .-L_alloc_run

GNU_STACK_NOTE
