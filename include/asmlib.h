/*==============================================================================
 * asmlib.h - public C interface to the x86-64 NASM assembly library
 *------------------------------------------------------------------------------
 * SPDX-License-Identifier: MIT
 *
 * A drop-in, high-performance replacement for the hottest libc memory and
 * string routines, implemented in hand-written AVX2/BMI2 assembly.
 *
 * Requirements
 * ------------
 *   - x86-64 (System V AMD64 ABI: Linux, *BSD, macOS).
 *   - AVX2 and BMI1 (tzcnt) at run time. Query asm_cpu_has_avx2() before
 *     calling any of the vectors if you must support older CPUs.
 *
 * Linking
 * -------
 *   -Iinclude  and link against -lasmlib (static or shared).
 *
 * Optional libc aliasing
 * ----------------------
 *   Define ASMLIB_ENABLE_LIBC_ALIASES before including this header to have the
 *   standard names (memcpy, strlen, ...) map to the asm_* implementations by
 *   way of macros. This lets an existing program use the library unchanged.
 *============================================================================*/

#ifndef ASMLIB_H
#define ASMLIB_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/*------------------------------------------------------------------------------
 * Runtime CPU feature bits returned by asm_cpu_features().
 *----------------------------------------------------------------------------*/
#define ASMLIB_CPU_SSE2   (1u << 0) /* Streaming SIMD Extensions 2          */
#define ASMLIB_CPU_AVX    (1u << 1) /* AVX (and OS vector state enabled)    */
#define ASMLIB_CPU_AVX2   (1u << 2) /* AVX2 integer/byte vectors            */
#define ASMLIB_CPU_BMI1   (1u << 3) /* tzcnt / lzcnt / andn                 */
#define ASMLIB_CPU_BMI2   (1u << 4) /* mulx / rorx / pdep / pext            */
#define ASMLIB_CPU_ERMS   (1u << 5) /* Enhanced REP MOVSB/STOSB             */
#define ASMLIB_CPU_POPCNT (1u << 6) /* POPCNT                               */
#define ASMLIB_CPU_FMA    (1u << 7) /* Fused multiply-add                   */

/* Return the feature bitmap for the current CPU/OS. */
unsigned asm_cpu_features(void);

/* Convenience predicate: non-zero when AVX2 is usable. */
int asm_cpu_has_avx2(void);

/*==============================================================================
 * Memory primitives (memory.asm)
 *============================================================================*/

/* Copy n bytes from src to dst (must not overlap). Returns dst. */
void* asm_memcpy(void* dst, const void* src, size_t n);

/* Copy n bytes from src to dst; the regions may overlap. Returns dst. */
void* asm_memmove(void* dst, const void* src, size_t n);

/* Fill n bytes at dst with the low byte of c. Returns dst. */
void* asm_memset(void* dst, int c, size_t n);

/* Zero n bytes at dst. Returns dst. */
void* asm_bzero(void* dst, size_t n);

/* Compare n bytes. Returns <0, 0 or >0 using unsigned byte values. */
int asm_memcmp(const void* a, const void* b, size_t n);

/* First byte equal to c in the first n bytes, or NULL. */
void* asm_memchr(const void* s, int c, size_t n);

/* Last byte equal to c in the first n bytes, or NULL. */
void* asm_memrchr(const void* s, int c, size_t n);

/*==============================================================================
 * String primitives (string.asm)
 *============================================================================*/

/* Length of the NUL-terminated string s. */
size_t asm_strlen(const char* s);

/* Length of s, but never reads past s + maxlen. */
size_t asm_strnlen(const char* s, size_t maxlen);

/* Copy at most n bytes of src, NUL-padding the remainder. Returns dst.
 * The number of bytes written is bounded by n; unlike asm_strcpy (removed),
 * this can never copy an unbounded amount into dst. */
char* asm_strncpy(char* dst, const char* src, size_t n);

/* Append at most n bytes of src, then NUL-terminate. Returns dst.
 * The number of bytes appended is bounded by n; unlike asm_strcat (removed),
 * this can never append an unbounded amount into dst. */
char* asm_strncat(char* dst, const char* src, size_t n);

/*==============================================================================
 * String comparison (strcmp.asm)
 *============================================================================*/

/* Compare two NUL-terminated strings. */
int asm_strcmp(const char* a, const char* b);

/* Compare at most n bytes of two strings. */
int asm_strncmp(const char* a, const char* b, size_t n);

/* Case-insensitive comparison (C/POSIX/ASCII locale). */
int asm_strcasecmp(const char* a, const char* b);

/* Case-insensitive comparison of at most n bytes. */
int asm_strncasecmp(const char* a, const char* b, size_t n);

/*==============================================================================
 * Searching (search.asm)
 *============================================================================*/

/* First occurrence of c in s (including the NUL when c == 0), or NULL. */
char* asm_strchr(const char* s, int c);

/* Last occurrence of c in s (including the NUL when c == 0), or NULL. */
char* asm_strrchr(const char* s, int c);

/* First occurrence of needle inside hay, or NULL. Empty needle returns hay. */
char* asm_strstr(const char* hay, const char* needle);

/* Binary-safe substring search inside an explicit-length buffer. */
void* asm_memmem(const void* hay, size_t hlen, const void* needle, size_t nlen);

/* Length of the initial segment of s consisting of bytes from accept. */
size_t asm_strspn(const char* s, const char* accept);

/* Length of the initial segment of s consisting of bytes NOT in accept. */
size_t asm_strcspn(const char* s, const char* accept);

/* First byte of s that occurs in accept, or NULL. */
char* asm_strpbrk(const char* s, const char* accept);

/*==============================================================================
 * Character classification and conversion (ctype.asm)
 *------------------------------------------------------------------------------
 * Predicates return 1 for true and 0 for false.
 *============================================================================*/

int asm_toupper(int c);  /* upper-case ASCII letter -> lower case  */
int asm_tolower(int c);  /* lower-case ASCII letter -> upper case  */
int asm_isalpha(int c);  /* A-Z or a-z                              */
int asm_isdigit(int c);  /* 0-9                                     */
int asm_isalnum(int c);  /* alpha or digit                          */
int asm_isspace(int c);  /* space, \t, \n, \v, \f, \r               */
int asm_isupper(int c);  /* A-Z                                     */
int asm_islower(int c);  /* a-z                                     */
int asm_isxdigit(int c); /* hexadecimal digit                       */
int asm_isprint(int c);  /* 0x20..0x7E                              */
int asm_iscntrl(int c);  /* 0x00..0x1F or 0x7F                      */
int asm_isgraph(int c);  /* 0x21..0x7E                              */
int asm_ispunct(int c);  /* printable, non-alphanumeric             */
int asm_isblank(int c);  /* space or horizontal tab                 */

/*==============================================================================
 * Arena allocator (arena.asm)
 *------------------------------------------------------------------------------
 * A chunked, resettable linear (bump) allocator. Every allocation is at
 * least 16-byte aligned and exhaustion returns NULL rather than overrunning
 * memory. It is single-threaded.
 *
 * The struct layout is part of the ABI; do not reorder the fields.
 *============================================================================*/

typedef struct asm_arena_chunk asm_arena_chunk; /* opaque */

typedef struct asm_arena {
    unsigned char* ptr;                              /* next free byte in the current chunk      */
    unsigned char* end;                              /* end of the current chunk                 */
    asm_arena_chunk* cur;                            /* current (newest) chunk                   */
    asm_arena_chunk* first;                          /* first chunk; reset() rewinds to it       */
    void* (*alloc)(size_t size, void* ctx);          /* backing allocator */
    void (*free)(void* ptr, size_t size, void* ctx); /* release   */
    void* ctx;                                       /* backing allocator context                */
    size_t chunk;                                    /* default size for new growable chunks     */
    size_t total;                                    /* usable bytes across all chunks           */
    size_t used;                                     /* bytes handed out since the last reset    */
    size_t peak;                                     /* high-water mark of `used`                */
} asm_arena;

/* Scoped rollback token for asm_arena_mark/asm_arena_release. */
typedef struct asm_mark {
    asm_arena_chunk* chunk;
    unsigned char* ptr;
    size_t used;
} asm_mark;

/* Initialise a fixed arena over caller-owned buf of `size` bytes.
 * The first 64 bytes are reserved for bookkeeping. Returns 0, or -1. */
int asm_arena_init(asm_arena* a, void* buf, size_t size);

/* Initialise a growable arena. alloc(size, ctx) must return 16-byte aligned
 * memory or NULL; free(ptr, size, ctx) may be NULL. Returns 0, or -1. */
int asm_arena_init_grow(asm_arena* a, void* (*alloc)(size_t size, void* ctx),
                        void (*free)(void* ptr, size_t size, void* ctx), void* ctx,
                        size_t chunk_size);

/* Growable arena whose chunks come from anonymous mmap (Linux x86-64). This
 * needs no libc and no caller-supplied allocator. Returns 0, or -1. */
int asm_arena_init_mmap(asm_arena* a, size_t chunk_size);

/* Allocate at least `size` bytes (16-byte aligned), or NULL. */
void* asm_arena_alloc(asm_arena* a, size_t size);

/* Allocate `size` bytes aligned to `align` (a power of two), or NULL. */
void* asm_arena_alloc_aligned(asm_arena* a, size_t size, size_t align);

/* Allocate count*size zeroed bytes, or NULL. */
void* asm_arena_calloc(asm_arena* a, size_t count, size_t size);

/* Resize an allocation. Grows in place when it is the most recent block,
 * otherwise moves and copies min(old, nw) bytes. ptr may be NULL. */
void* asm_arena_realloc(asm_arena* a, void* ptr, size_t old, size_t nw);

/* Snapshot the current position for scoped rollback. */
void asm_arena_mark(const asm_arena* a, asm_mark* m);

/* Roll back to a mark, releasing all newer chunks. Returns 0, or -1 if the
 * mark does not belong to this arena. */
int asm_arena_release(asm_arena* a, const asm_mark* m);

/* Release every chunk except the first and rewind to its start. */
void asm_arena_reset(asm_arena* a);

/* Release all chunks (if a free callback is set) and clear the arena. */
void asm_arena_destroy(asm_arena* a);

/* Bytes handed out since the last reset. */
size_t asm_arena_used(const asm_arena* a);

/* High-water mark of asm_arena_used() since the last reset. */
size_t asm_arena_peak(const asm_arena* a);

/* Free bytes remaining in the current chunk. */
size_t asm_arena_remaining(const asm_arena* a);

/* Total usable bytes currently backed by all chunks. */
size_t asm_arena_capacity(const asm_arena* a);

/*==============================================================================
 * Opaque OS memory primitives (sys.asm, Linux x86-64)
 *------------------------------------------------------------------------------
 * Anonymous mmap/munmap. asm_sys_alloc/asm_sys_free match the arena callback
 * signatures and can be passed to asm_arena_init_grow().
 *============================================================================*/

void* asm_sys_mmap(size_t size);                      /* page-aligned or NULL */
int asm_sys_munmap(void* ptr, size_t size);           /* 0 or -errno          */
void* asm_sys_alloc(size_t size, void* ctx);          /* arena alloc callback */
void asm_sys_free(void* ptr, size_t size, void* ctx); /* arena free cb   */

/*==============================================================================
 * malloc-style allocator (alloc.asm)
 *------------------------------------------------------------------------------
 * A segregated free-list allocator served directly by mmap, with no libc
 * dependency. Every pointer is 16-byte aligned.
 *
 * IMPORTANT: these manage their own heap; a pointer from asm_malloc must be
 * released with asm_free and never with libc free (and vice versa). The
 * allocator is single-threaded.
 *============================================================================*/

void* asm_malloc(size_t size);
void* asm_calloc(size_t count, size_t size);
void* asm_realloc(void* ptr, size_t size);
void asm_free(void* ptr);

#ifdef __cplusplus
} /* extern "C" */
#endif

/*==============================================================================
 * Optional: map the standard libc names onto the asm_* routines.
 * Define ASMLIB_ENABLE_LIBC_ALIASES to activate. This is deliberately opt-in.
 *============================================================================*/
#ifdef ASMLIB_ENABLE_LIBC_ALIASES
#define memcpy      asm_memcpy
#define memmove     asm_memmove
#define memset      asm_memset
#define bzero       asm_bzero
#define memcmp      asm_memcmp
#define memchr      asm_memchr
#define memrchr     asm_memrchr
#define strlen      asm_strlen
#define strnlen     asm_strnlen
#define strncpy     asm_strncpy
#define strncat     asm_strncat
#define strcmp      asm_strcmp
#define strncmp     asm_strncmp
#define strcasecmp  asm_strcasecmp
#define strncasecmp asm_strncasecmp
#define strchr      asm_strchr
#define strrchr     asm_strrchr
#define strstr      asm_strstr
#define memmem      asm_memmem
#define strspn      asm_strspn
#define strcspn     asm_strcspn
#define strpbrk     asm_strpbrk
#define toupper     asm_toupper
#define tolower     asm_tolower
#define isalpha     asm_isalpha
#define isdigit     asm_isdigit
#define isalnum     asm_isalnum
#define isspace     asm_isspace
#define isupper     asm_isupper
#define islower     asm_islower
#define isxdigit    asm_isxdigit
#define isprint     asm_isprint
#define iscntrl     asm_iscntrl
#define isgraph     asm_isgraph
#define ispunct     asm_ispunct
#define isblank     asm_isblank
#endif /* ASMLIB_ENABLE_LIBC_ALIASES */

#endif /* ASMLIB_H */
