/*==============================================================================
 * alloc.c - portable, freestanding C allocator
 *------------------------------------------------------------------------------
 * SPDX-License-Identifier: MIT
 *
 * A portable implementation of the allocator half of portable.h for targets
 * where the x86-64 NASM heap (src/alloc.asm) cannot run - WebAssembly and other
 * freestanding platforms. It depends on nothing but <stddef.h>/<stdint.h> and
 * the compiler's WebAssembly memory builtins; there is no libc underneath.
 *
 *   void  *asm_malloc (size_t size);
 *   void  *asm_calloc (size_t count, size_t size);
 *   void  *asm_realloc(void *ptr, size_t size);
 *   void   asm_free   (void *ptr);
 *   void  *asm_reallocarray(void *ptr, size_t count, size_t size);
 *   size_t asm_malloc_usable_size(void *ptr);
 *   void  *asm_aligned_alloc(size_t alignment, size_t size);
 *   int    asm_posix_memalign(void **memptr, size_t alignment, size_t size);
 *
 * (The asm_ prefix is dropped when the source is compiled with
 *  -DASMLIB_LIBC_STD_NAMES, exactly as the rest of src/libc is.)
 *
 * Strategy
 * --------
 * * A single contiguous region is carved into blocks. Each block starts with a
 *   16-byte header (a size and a flags word) and the payload that follows is
 *   16-byte aligned. Free blocks are threaded onto one address-ordered,
 *   doubly-linked free list; adjacent free blocks are coalesced on free.
 * * malloc is a first-fit search of that list. A block is split when the
 *   remainder can still hold a minimum block, otherwise it is handed out whole.
 * * The region itself is:
 *     - on wasm32, the linear memory after the linker symbol __heap_base; when
 *       the free list cannot satisfy a request the memory is grown with
 *       __builtin_wasm_memory_grow() by whole 64 KiB pages, and
 *     - everywhere else, a static byte array (16 MiB), initialised lazily.
 * * Over-aligned requests (alignment > 16) are served by allocating a plain
 *   backing block with slack, aligning a pointer inside it and stamping an
 *   "indirect" header in front of the aligned payload. free/realloc/
 *   malloc_usable_size detect that header and operate on the backing block, so
 *   every aligned pointer is fully interchangeable with a plain one.
 *
 * IMPORTANT: the allocator is single-threaded and keeps its heap start and
 * free list in global state, just like the asm heap. A pointer returned here
 * must be released with asm_free and never with a host free (and vice versa).
 *============================================================================*/

#include "portable.h"

#include <stddef.h>
#include <stdint.h>

/*------------------------------------------------------------------------------
 * Tunables and layout
 *----------------------------------------------------------------------------*/
#define POOL_ALIGN    16u                             /* payload alignment       */
#define POOL_HDR      16u                             /* per-block header size    */
#define POOL_MIN      32u                             /* smallest block (hdr + 2 ptrs) */
#define BLK_FREE      1u                              /* block is on the free list */
#define BLK_INDIRECT  2u                              /* header belongs to an aligned block */

#define POOL_EINVAL   22                              /* EINVAL                   */
#define POOL_ENOMEM   12                              /* ENOMEM                   */

#if !defined(__wasm__)
#  ifndef ASM_PORTABLE_HEAP_SIZE
#    define ASM_PORTABLE_HEAP_SIZE (16u * 1024u * 1024u)
#  endif
#endif

/* A block header. The size is the whole block (header + payload) for a normal
 * block, or the byte offset from the backing payload to an aligned pointer for
 * an indirect header. The padding keeps the header 16 bytes on 32-bit wasm. */
typedef struct pool_block pool_block;
struct pool_block {
    size_t size;
    size_t flags;
#if SIZE_MAX <= 0xFFFFFFFFu
    size_t pad0;
    size_t pad1;
#endif
};

/* Free-list links live in the payload of a free block. may_alias lets us store
 * pointers into memory that is otherwise seen as a byte array. */
typedef struct pool_block *pool_link __attribute__((may_alias));

static unsigned char *pool_start;   /* region base (16-byte aligned)   */
static unsigned char *pool_end;     /* one past the region             */
static pool_block   *pool_free;     /* address-ordered free-list head  */
static int           pool_ready;    /* lazy initialisation latch       */

#if defined(__wasm__)
extern unsigned char __heap_base;   /* linker-provided heap start      */
#else
_Alignas(16) static unsigned char pool_heap[ASM_PORTABLE_HEAP_SIZE];
#endif

/*------------------------------------------------------------------------------
 * Small helpers
 *----------------------------------------------------------------------------*/
static size_t align_up(size_t n, size_t a) {
    return (n + (a - 1)) & ~(a - 1);
}

static int add_ovf(size_t a, size_t b, size_t *out) {
    if (a > (size_t)-1 - b) return 1;
    *out = a + b;
    return 0;
}

static int mul_ovf(size_t a, size_t b, size_t *out) {
    if (a != 0 && b > (size_t)-1 / a) return 1;
    *out = a * b;
    return 0;
}

static void mem_fill(void *dst, int c, size_t n) {
    unsigned char *d = (unsigned char *)dst;
    while (n--) *d++ = (unsigned char)c;
}

static void mem_copy(void *dst, const void *src, size_t n) {
    unsigned char *d = (unsigned char *)dst;
    const unsigned char *s = (const unsigned char *)src;
    while (n--) *d++ = *s++;
}

static void *blk_payload(pool_block *b) {
    return (unsigned char *)b + POOL_HDR;
}

static pool_block *blk_header(void *p) {
    return (pool_block *)((unsigned char *)p - POOL_HDR);
}

static pool_link *blk_links(pool_block *b) {
    return (pool_link *)(void *)((unsigned char *)b + POOL_HDR);
}

static pool_block *blk_next(pool_block *b) { return blk_links(b)[0]; }
static pool_block *blk_prev(pool_block *b) { return blk_links(b)[1]; }
static void blk_set_next(pool_block *b, pool_block *v) { blk_links(b)[0] = v; }
static void blk_set_prev(pool_block *b, pool_block *v) { blk_links(b)[1] = v; }

/*------------------------------------------------------------------------------
 * Address-ordered free list with coalescing
 *----------------------------------------------------------------------------*/
static void fl_insert(pool_block *b) {
    pool_block *prev = NULL;
    pool_block *cur = pool_free;

    while (cur != NULL && (uintptr_t)cur < (uintptr_t)b) {
        prev = cur;
        cur = blk_next(cur);
    }
    blk_set_next(b, cur);
    blk_set_prev(b, prev);
    if (prev != NULL) blk_set_next(prev, b);
    else pool_free = b;
    if (cur != NULL) blk_set_prev(cur, b);
}

static void fl_remove(pool_block *b) {
    pool_block *prev = blk_prev(b);
    pool_block *next = blk_next(b);

    if (prev != NULL) blk_set_next(prev, next);
    else pool_free = next;
    if (next != NULL) blk_set_prev(next, prev);
}

static void fl_coalesce(pool_block *b) {
    pool_block *next = blk_next(b);

    if (next != NULL && (unsigned char *)b + b->size == (unsigned char *)next) {
        b->size += next->size;
        fl_remove(next);
    }
    {
        pool_block *prev = blk_prev(b);
        if (prev != NULL && (unsigned char *)prev + prev->size == (unsigned char *)b) {
            prev->size += b->size;
            fl_remove(b);
        }
    }
}

static pool_block *fl_search(size_t total) {
    pool_block *b = pool_free;

    while (b != NULL) {
        if (b->size >= total) return b;
        b = blk_next(b);
    }
    return NULL;
}

/*------------------------------------------------------------------------------
 * Heap region: initialisation and growth
 *----------------------------------------------------------------------------*/
static int heap_init(void) {
#if defined(__wasm__)
    size_t base = (size_t)&__heap_base;
    pool_start = (unsigned char *)align_up(base, POOL_ALIGN);
    pool_end = (unsigned char *)((size_t)__builtin_wasm_memory_size(0) * (size_t)65536u);
    if ((uintptr_t)pool_end < (uintptr_t)pool_start) pool_end = pool_start;
#else
    pool_start = pool_heap;
    pool_end = pool_heap + sizeof(pool_heap);
#endif
    pool_free = NULL;
    pool_ready = 1;

    if ((size_t)(pool_end - pool_start) >= POOL_MIN) {
        pool_block *b = (pool_block *)pool_start;
        b->size = (size_t)(pool_end - pool_start);
        b->flags = BLK_FREE;
        fl_insert(b);
    }
    return 1;
}

static int heap_grow(size_t bytes) {
#if defined(__wasm__)
    size_t want;
    size_t have;
    size_t pages;

    if (add_ovf((size_t)pool_end, bytes, &want)) return 0;
    have = (size_t)__builtin_wasm_memory_size(0) * (size_t)65536u;
    if (want <= have) {
        pool_end = (unsigned char *)have;
        return 1;
    }
    pages = (want - have + 65535u) / 65536u;
    if (__builtin_wasm_memory_grow(0, pages) == (size_t)-1) return 0;
    pool_end = (unsigned char *)((size_t)__builtin_wasm_memory_size(0) * (size_t)65536u);
    return 1;
#else
    unsigned char *limit = pool_heap + sizeof(pool_heap);
    if (bytes > (size_t)(limit - pool_end)) return 0;
    pool_end += bytes;
    return 1;
#endif
}

/* Append `total` fresh bytes at the top of the region and fold them into the
 * free list (coalescing with a free top block when there is one). */
static int heap_more(size_t total) {
    unsigned char *old = pool_end;

    if (!heap_grow(total)) return 0;
    {
        pool_block *b = (pool_block *)old;
        b->size = (size_t)(pool_end - old);
        b->flags = BLK_FREE;
        fl_insert(b);
        fl_coalesce(b);
    }
    return 1;
}

/*------------------------------------------------------------------------------
 * Usable payload of an allocated pointer (normal or indirect)
 *----------------------------------------------------------------------------*/
static size_t block_usable(void *ptr) {
    pool_block *h = blk_header(ptr);

    if (h->flags & BLK_INDIRECT) {
        pool_block *backing = blk_header((unsigned char *)ptr - h->size);
        return backing->size - h->size;
    }
    return h->size - POOL_HDR;
}

/*------------------------------------------------------------------------------
 * void *asm_malloc(size_t size)
 *------------------------------------------------------------------------------
 * Returns a 16-byte aligned block of at least size bytes, or NULL.
 *----------------------------------------------------------------------------*/
void *ASM_LIBC(malloc)(size_t size) {
    size_t need;
    size_t total;
    pool_block *b;

    if (!pool_ready && !heap_init()) return NULL;
    if (size == 0) size = 1;

    if (add_ovf(size, POOL_ALIGN - 1, &need)) return NULL;
    need &= ~(size_t)(POOL_ALIGN - 1);
    if (add_ovf(need, POOL_HDR, &total)) return NULL;
    if (total < POOL_MIN) total = POOL_MIN;

    b = fl_search(total);
    if (b == NULL) {
        if (!heap_more(total)) return NULL;
        b = fl_search(total);
        if (b == NULL) return NULL;
    }
    fl_remove(b);

    if (b->size >= total + POOL_MIN) {
        pool_block *rest = (pool_block *)((unsigned char *)b + total);
        rest->size = b->size - total;
        rest->flags = BLK_FREE;
        b->size = total;
        fl_insert(rest);
        fl_coalesce(rest);
    }
    b->flags = 0;
    return blk_payload(b);
}

/*------------------------------------------------------------------------------
 * void *asm_calloc(size_t count, size_t size)
 *------------------------------------------------------------------------------
 * Allocates count*size zeroed bytes. The product is overflow-checked and NULL
 * is returned on wrap.
 *----------------------------------------------------------------------------*/
void *ASM_LIBC(calloc)(size_t count, size_t size) {
    size_t total;
    void *p;

    if (mul_ovf(count, size, &total)) return NULL;
    p = ASM_LIBC(malloc)(total);
    if (p == NULL) return NULL;
    mem_fill(p, 0, total);
    return p;
}

/*------------------------------------------------------------------------------
 * void asm_free(void *ptr)
 *------------------------------------------------------------------------------
 * Releases a block (ptr may be NULL). Indirect (over-aligned) pointers are
 * resolved to their backing block and released there.
 *----------------------------------------------------------------------------*/
void ASM_LIBC(free)(void *ptr) {
    pool_block *h;

    if (ptr == NULL) return;
    h = blk_header(ptr);
    if (h->flags & BLK_INDIRECT) {
        ASM_LIBC(free)((unsigned char *)ptr - h->size);
        return;
    }
    h->flags = BLK_FREE;
    fl_insert(h);
    fl_coalesce(h);
}

/*------------------------------------------------------------------------------
 * void *asm_realloc(void *ptr, size_t size)
 *------------------------------------------------------------------------------
 * Reallocates ptr to size bytes. The block is kept in place when size still
 * fits its usable payload, otherwise it is moved and the live prefix copied.
 * realloc(NULL, n) == malloc(n); realloc(p, 0) frees p and returns NULL.
 *----------------------------------------------------------------------------*/
void *ASM_LIBC(realloc)(void *ptr, size_t size) {
    void *np;
    size_t usable;
    size_t copy;

    if (ptr == NULL) return ASM_LIBC(malloc)(size);
    if (size == 0) {
        ASM_LIBC(free)(ptr);
        return NULL;
    }
    usable = block_usable(ptr);
    if (size <= usable) return ptr;

    np = ASM_LIBC(malloc)(size);
    if (np == NULL) return NULL;
    copy = usable < size ? usable : size;
    mem_copy(np, ptr, copy);
    ASM_LIBC(free)(ptr);
    return np;
}

/*------------------------------------------------------------------------------
 * void *asm_reallocarray(void *ptr, size_t count, size_t size)
 *------------------------------------------------------------------------------
 * Overflow-checked realloc of count*size bytes; NULL on overflow with ptr left
 * valid.
 *----------------------------------------------------------------------------*/
void *ASM_LIBC(reallocarray)(void *ptr, size_t count, size_t size) {
    size_t total;

    if (mul_ovf(count, size, &total)) return NULL;
    return ASM_LIBC(realloc)(ptr, total);
}

/*------------------------------------------------------------------------------
 * size_t asm_malloc_usable_size(void *ptr)
 *------------------------------------------------------------------------------
 * Usable payload bytes in a block, or 0 for NULL.
 *----------------------------------------------------------------------------*/
size_t ASM_LIBC(malloc_usable_size)(void *ptr) {
    if (ptr == NULL) return 0;
    return block_usable(ptr);
}

/*------------------------------------------------------------------------------
 * internal: aligned_new(alignment, size)
 *------------------------------------------------------------------------------
 * Alignment <= 16 is already guaranteed by malloc. Larger alignments carve an
 * aligned pointer out of a plain backing block and stamp an indirect header in
 * front of it; the header records the offset back to the backing payload.
 *----------------------------------------------------------------------------*/
static void *aligned_new(size_t alignment, size_t size) {
    size_t slack;
    size_t total;
    size_t payload;
    void *base;
    unsigned char *p;
    pool_block *h;

    if (alignment <= POOL_ALIGN) return ASM_LIBC(malloc)(size);

    if (add_ovf(alignment, 2u * POOL_HDR, &slack)) return NULL;
    if (add_ovf(size, POOL_ALIGN - 1, &payload)) return NULL;
    payload &= ~(size_t)(POOL_ALIGN - 1);
    if (add_ovf(payload, slack, &total)) return NULL;

    base = ASM_LIBC(malloc)(total);
    if (base == NULL) return NULL;

    p = (unsigned char *)align_up((size_t)base + 2u * POOL_HDR, alignment);
    h = (pool_block *)(p - POOL_HDR);
    h->flags = BLK_INDIRECT;
    h->size = (size_t)(p - (unsigned char *)base);
    return p;
}

/*------------------------------------------------------------------------------
 * void *asm_aligned_alloc(size_t alignment, size_t size)
 *------------------------------------------------------------------------------
 * Allocates size bytes aligned to `alignment` (a non-zero power of two), or
 * NULL on an invalid alignment or failure. Any size is accepted.
 *----------------------------------------------------------------------------*/
void *ASM_LIBC(aligned_alloc)(size_t alignment, size_t size) {
    if (alignment == 0 || (alignment & (alignment - 1)) != 0) return NULL;
    return aligned_new(alignment, size);
}

/*------------------------------------------------------------------------------
 * int asm_posix_memalign(void **memptr, size_t alignment, size_t size)
 *------------------------------------------------------------------------------
 * 0 on success, EINVAL(22) for an alignment that is not a power of two or is
 * below sizeof(void*), ENOMEM(12) on failure. *memptr is left untouched on the
 * error paths.
 *----------------------------------------------------------------------------*/
int ASM_LIBC(posix_memalign)(void **memptr, size_t alignment, size_t size) {
    void *p;

    if (alignment == 0 || (alignment & (alignment - 1)) != 0 ||
        alignment < sizeof(void *)) return POOL_EINVAL;

    p = aligned_new(alignment, size);
    if (p == NULL) return POOL_ENOMEM;
    *memptr = p;
    return 0;
}
