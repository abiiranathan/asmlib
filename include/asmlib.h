/*==============================================================================
 * asmlib.h - public C interface to the asmlib memory/string library
 *------------------------------------------------------------------------------
 * SPDX-License-Identifier: MIT
 *============================================================================*/

/**
 * @file asmlib.h
 * @brief Umbrella header for the whole asmlib library.
 *
 * A drop-in, high-performance replacement for the hottest libc memory and
 * string routines, implemented in hand-written x86-64 (AVX2/BMI2) and
 * AArch64 (NEON) assembly, all behind the `asm_*` names declared here. The
 * freestanding math library and the vector/matrix/quaternion API are included
 * at the bottom, so `#include "asmlib.h"` is the whole public surface.
 *
 * @section asm_requirements Requirements
 *   - x86-64 (System V AMD64 ABI: Linux, *BSD, macOS) with AVX2 and BMI1
 *     (tzcnt) at run time. Query asm_cpu_has_avx2() before calling any of the
 *     vectors if you must support older CPUs. On hosted Linux the hot routines
 *     are resolved to AVX2 or the scalar fallback automatically (ELF IFUNC).
 *   - AArch64 (AAPCS64: Linux); NEON is baseline, so no feature check is
 *     needed (asm_cpu_has_avx2() returns 0 there).
 *
 * @section asm_linking Linking
 *   `-Iinclude` and link against `-lasmlib` (static or shared).
 *
 * @section asm_aliases Optional libc aliasing
 *   Define ::ASMLIB_ENABLE_LIBC_ALIASES before including this header to have
 *   the standard names (memcpy, strlen, ...) map to the `asm_*` implementations
 *   by way of macros. This lets an existing program use the library unchanged.
 */

#ifndef ASMLIB_H
#define ASMLIB_H

#include <stddef.h>
#include <stdint.h>
#include <stdarg.h>

#include "asmlib_version.h"

#ifdef __cplusplus
extern "C" {
#endif

/** @defgroup asm_runtime Runtime: version and CPU features
 *  @{ */

/**
 * @brief Runtime version string, "MAJOR.MINOR.PATCH".
 * @return A statically allocated NUL-terminated string (never NULL).
 */
const char* asm_version(void);

/**
 * @brief Platform / OS boundary.
 *
 * The OS-backed surface - asm_sys_mmap/munmap/alloc/free, the asm_malloc heap
 * and asm_arena_init_mmap - is built on raw Linux syscalls and is Linux-only.
 * Everything else (memory, string, comparison, search, ctype, arena over
 * caller memory, math, format, scan, vector/matrix) is freestanding: no OS, no
 * libc, linkable with `-nostdlib`. ::ASMLIB_OS_HEAP is 1 when compiling for
 * Linux, 0 elsewhere; the freestanding routines work either way.
 */
#if defined(__linux__) && !defined(ASMLIB_OS_HEAP)
#define ASMLIB_OS_HEAP 1
#endif
#if !defined(ASMLIB_OS_HEAP)
#define ASMLIB_OS_HEAP 0
#endif

/** @name CPU feature bits returned by asm_cpu_features()
 *  @{ */
#define ASMLIB_CPU_SSE2   (1u << 0) /**< Streaming SIMD Extensions 2        */
#define ASMLIB_CPU_AVX    (1u << 1) /**< AVX (and OS vector state enabled)  */
#define ASMLIB_CPU_AVX2   (1u << 2) /**< AVX2 integer/byte vectors          */
#define ASMLIB_CPU_BMI1   (1u << 3) /**< tzcnt / lzcnt / andn               */
#define ASMLIB_CPU_BMI2   (1u << 4) /**< mulx / rorx / pdep / pext          */
#define ASMLIB_CPU_ERMS   (1u << 5) /**< Enhanced REP MOVSB/STOSB           */
#define ASMLIB_CPU_POPCNT (1u << 6) /**< POPCNT                             */
#define ASMLIB_CPU_FMA    (1u << 7) /**< Fused multiply-add                 */
/** @} */

/**
 * @brief Return the feature bitmap for the current CPU/OS.
 * @return A mask of the `ASMLIB_CPU_*` bits.
 */
unsigned asm_cpu_features(void);

/**
 * @brief Convenience predicate for AVX2 usability.
 * @return Non-zero when AVX2 (and its OS vector state) is available.
 */
int asm_cpu_has_avx2(void);

/**
 * @brief Abort if the CPU lacks AVX2/BMI1 (x86-64 only).
 *
 * If the CPU lacks AVX2/BMI1, writes a short message to stderr and calls
 * `exit(2)` instead of faulting inside a vector routine. Call once at startup.
 * Uses raw Linux syscalls; on AArch64 it is unnecessary (NEON is baseline).
 */
void asm_cpu_require_avx2(void);

/** @} */

/** @defgroup asm_memory Memory primitives (memory.asm)
 *  @{ */

/** @brief Copy `n` bytes from `src` to `dst` (regions must not overlap).
 *  @return `dst`. */
void* asm_memcpy(void* dst, const void* src, size_t n);

/** @brief Copy `n` bytes from `src` to `dst` (regions must not overlap).
 *  @return `dst + n`. */
void* asm_mempcpy(void* dst, const void* src, size_t n);

/**
 * @brief Copy up to `n` bytes from `src` to `dst`, stopping after the byte
 *        equal to `(unsigned char)c`.
 * @return A pointer just past that byte in `dst`, or `NULL` if `c` was not
 *         found within `n` bytes.
 */
void* asm_memccpy(void* dst, const void* src, int c, size_t n);

/** @brief Copy `n` bytes from `src` to `dst`; the regions may overlap.
 *  @return `dst`. */
void* asm_memmove(void* dst, const void* src, size_t n);

/** @brief Fill `n` bytes at `dst` with the low byte of `c`.
 *  @return `dst`. */
void* asm_memset(void* dst, int c, size_t n);

/** @brief Zero `n` bytes at `dst`.
 *  @return `dst`. */
void* asm_bzero(void* dst, size_t n);

/** @brief Zero `n` bytes at `dst`; the out-of-line call cannot be elided by the
 *         compiler. */
void asm_explicit_bzero(void* dst, size_t n);

/** @brief Compare `n` bytes.
 *  @return `<0`, `0` or `>0` using unsigned byte values. */
int asm_memcmp(const void* a, const void* b, size_t n);

/** @brief First byte equal to `c` in the first `n` bytes.
 *  @return Pointer to it, or `NULL`. */
void* asm_memchr(const void* s, int c, size_t n);

/** @brief Last byte equal to `c` in the first `n` bytes.
 *  @return Pointer to it, or `NULL`. */
void* asm_memrchr(const void* s, int c, size_t n);

/** @} */

/** @defgroup asm_string String primitives (string.asm)
 *  @{ */

/** @brief Length of the NUL-terminated string `s`.
 *  @return The number of bytes before the terminating NUL. */
size_t asm_strlen(const char* s);

/** @brief Length of `s`, but never reads past `s + maxlen`.
 *  @return `min(strlen(s), maxlen)`. */
size_t asm_strnlen(const char* s, size_t maxlen);

/** @brief Copy at most `n` bytes of `src`, NUL-padding the remainder.
 *
 * The number of bytes written is bounded by `n`; unlike a bare `strcpy`, this
 * can never copy an unbounded amount into `dst`.
 * @return `dst`. */
char* asm_strncpy(char* dst, const char* src, size_t n);

/** @brief Like asm_strncpy(), but returns the terminating NUL when one was
 *         written, otherwise `dst + n` (POSIX stpncpy). */
char* asm_stpncpy(char* dst, const char* src, size_t n);

/** @brief Append at most `n` bytes of `src`, then NUL-terminate.
 *
 * The number of bytes appended is bounded by `n`; unlike a bare `strcat`, this
 * can never append an unbounded amount into `dst`.
 * @return `dst`. */
char* asm_strncat(char* dst, const char* src, size_t n);

/**
 * @brief BSD bounded copy.
 *
 * Copies at most `size - 1` bytes and always NUL-terminates when `size > 0`;
 * never writes past `dst[size - 1]`.
 * @return `strlen(src)`.
 */
size_t asm_strlcpy(char* dst, const char* src, size_t size);

/**
 * @brief BSD bounded append.
 *
 * Appends at most `size - strlen(dst) - 1` bytes, NUL-terminates, and never
 * writes past `dst[size - 1]`. When `dst` has no NUL within `size` it writes
 * nothing.
 * @return `min(size, strlen(dst)) + strlen(src)`.
 */
size_t asm_strlcat(char* dst, const char* src, size_t size);

/** @} */

/** @defgroup asm_cmp String comparison (strcmp.asm)
 *  @{ */

/** @brief Compare two NUL-terminated strings.
 *  @return `<0`, `0` or `>0` using unsigned char values. */
int asm_strcmp(const char* a, const char* b);

/** @brief Compare at most `n` bytes of two strings.
 *  @return `<0`, `0` or `>0`; `0` also when the first `n` bytes are equal. */
int asm_strncmp(const char* a, const char* b, size_t n);

/** @brief Case-insensitive comparison (C/POSIX/ASCII locale). */
int asm_strcasecmp(const char* a, const char* b);

/** @brief Case-insensitive comparison of at most `n` bytes. */
int asm_strncasecmp(const char* a, const char* b, size_t n);

/** @} */

/** @defgroup asm_search Searching (search.asm)
 *  @{ */

/** @brief First occurrence of `c` in `s` (including the NUL when `c == 0`).
 *  @return Pointer to it, or `NULL`. */
char* asm_strchr(const char* s, int c);

/** @brief Last occurrence of `c` in `s` (including the NUL when `c == 0`).
 *  @return Pointer to it, or `NULL`. */
char* asm_strrchr(const char* s, int c);

/** @brief First occurrence of `needle` inside `hay`.
 *  @return Pointer to it, or `NULL`; an empty `needle` returns `hay`. */
char* asm_strstr(const char* hay, const char* needle);

/** @brief Binary-safe substring search inside an explicit-length buffer.
 *  @return Pointer to the match, or `NULL`. */
void* asm_memmem(const void* hay, size_t hlen, const void* needle, size_t nlen);

/** @brief Length of the initial segment of `s` consisting of bytes in `accept`. */
size_t asm_strspn(const char* s, const char* accept);

/** @brief Length of the initial segment of `s` consisting of bytes not in
 *         `accept`. */
size_t asm_strcspn(const char* s, const char* accept);

/** @brief First byte of `s` that occurs in `accept`.
 *  @return Pointer to it, or `NULL`. */
char* asm_strpbrk(const char* s, const char* accept);

/** @} */

/** @defgroup asm_ctype Character classification and conversion (ctype.asm)
 *  Predicates return 1 for true and 0 for false.
 *  @{ */

int asm_toupper(int c);   /**< upper-case ASCII letter -> lower case */
int asm_tolower(int c);   /**< lower-case ASCII letter -> upper case */
int asm_isalpha(int c);   /**< A-Z or a-z                */
int asm_isdigit(int c);   /**< 0-9                       */
int asm_isalnum(int c);   /**< alpha or digit            */
int asm_isspace(int c);   /**< space, \t, \n, \v, \f, \r */
int asm_isupper(int c);   /**< A-Z                       */
int asm_islower(int c);   /**< a-z                       */
int asm_isxdigit(int c);  /**< hexadecimal digit         */
int asm_isprint(int c);   /**< 0x20..0x7E                */
int asm_iscntrl(int c);   /**< 0x00..0x1F or 0x7F        */
int asm_isgraph(int c);   /**< 0x21..0x7E                */
int asm_ispunct(int c);   /**< printable, non-alphanumeric */
int asm_isblank(int c);   /**< space or horizontal tab   */

/** @} */

/** @defgroup asm_format Integer formatting (format.asm)
 *  Bounded, NUL-terminating integer-to-string helpers. Each writes digits to
 *  `buf`, then a NUL when `cap > 0`, and never writes more than `cap` bytes.
 *  The return value is the number of characters the *full* representation
 *  needs, excluding the NUL, so `ret >= cap` means the output was truncated.
 *  With `cap == 0` nothing is written and only the length is returned.
 *
 *  Digits are written most-significant first. `base` must be 2..36 and uses
 *  `0-9` then `a-z`. Buffers must be large enough for the untruncated result if
 *  you care about the complete string; a 21-byte buffer covers any `uint64_t`
 *  in decimal, 65 bytes covers binary.
 *  @{ */

/** @brief Unsigned decimal. */
size_t asm_u64toa(uint64_t value, char* buf, size_t cap);

/** @brief Signed decimal; emits a leading '-' for negative values
 *         (`INT64_MIN` is fine). */
size_t asm_i64toa(int64_t value, char* buf, size_t cap);

/** @brief Unsigned in base 2..36 (lowercase letters).
 *  @return The length, or 0 for a bad base. */
size_t asm_u64toa_base(uint64_t value, char* buf, size_t cap, unsigned base);

/** @brief Unsigned hexadecimal without a "0x" prefix; uppercase when
 *         `uppercase` is non-zero. */
size_t asm_u64tohex(uint64_t value, char* buf, size_t cap, int uppercase);

/** @} */

/** @defgroup asm_snprintf Formatted output (format.asm / src/libc)
 *  A complete, freestanding C99 printf family. Semantics match C99 snprintf:
 *  at most `size - 1` bytes are written, a NUL is stored when `size > 0`, and
 *  the return value is the number of bytes that *would* have been written
 *  excluding the NUL (negative is never returned). Not locale aware and not
 *  async-signal-safe.
 *
 *  Supported conversions (an argument is consumed for each):
 *  | Spec | Meaning |
 *  | ---- | ------- |
 *  | `%%` | literal percent |
 *  | `%c` | int -> one byte |
 *  | `%s` | `char*` (`NULL` -> `"(null)"`), precision bounds the length |
 *  | `%p` | `void*` -> `"0x"` + hex (`NULL` -> `"(nil)"`) |
 *  | `%d` `%i` | signed decimal |
 *  | `%u` `%o` `%x` `%X` | unsigned, octal, hex (lower/upper) |
 *  | `%f` `%F` `%e` `%E` `%g` `%G` `%a` `%A` | floating point |
 *  | `%n` | store the count written so far |
 *
 *  Flags: `-` left-justify, `+` force sign, space sign, `#` alternate form,
 *  `0` zero-pad. Width and precision may be a decimal or `*`. Length modifiers:
 *  `hh`, `h`, `l`, `ll`, `z`, `j`, `t` for integers, and `L` for `long double`
 *  (narrowed to `double`; values needing extended precision are not exact).
 *  Floating point is correctly rounded (round half to even) with the exact
 *  decimal expansion of the binary value. @{ */

/** @brief Bounded formatted output; see the group contract. */
int asm_snprintf(char* dst, size_t size, const char* fmt, ...);

/** @brief `va_list` form of asm_snprintf(). */
int asm_vsnprintf(char* dst, size_t size, const char* fmt, va_list ap);

/** @brief Unbounded formatted output into `dst` (caller guarantees room). */
int asm_sprintf(char* dst, const char* fmt, ...);

/** @brief `va_list` form of asm_sprintf(). */
int asm_vsprintf(char* dst, const char* fmt, va_list ap);

/** @brief Allocate and format; `*strp` receives a malloc'd NUL-terminated
 *         string (release with asm_free). Returns the length or -1. */
int asm_asprintf(char** strp, const char* fmt, ...);

/** @brief `va_list` form of asm_asprintf(). */
int asm_vasprintf(char** strp, const char* fmt, va_list ap);

#if ASMLIB_OS_HEAP
/** @brief Formatted output to a file descriptor (Linux; raw write syscall). */
int asm_dprintf(int fd, const char* fmt, ...);

/** @brief `va_list` form of asm_dprintf(). */
int asm_vdprintf(int fd, const char* fmt, va_list ap);

/** @brief Formatted output to standard output (fd 1). */
int asm_printf(const char* fmt, ...);

/** @brief `va_list` form of asm_printf(). */
int asm_vprintf(const char* fmt, va_list ap);
#endif

/** @} */

/** @defgroup asm_sscanf Minimal, safe sscanf (format.asm / scan.asm)
 *  `int asm_sscanf(const char* src, const char* fmt, ...)`
 *
 *  A small, freestanding replacement for the common integer/string cases of
 *  sscanf. It never reads past the terminating NUL of `src`.
 *  @return The number of successful assignments, or `-1` on an input failure
 *          before the first conversion (like EOF) or on a malformed format.
 *
 *  Supported conversions (an argument is consumed unless `*`):
 *  | Spec | Meaning |
 *  | ---- | ------- |
 *  | `%%` | literal percent |
 *  | `%c` | width bytes (default 1) into `char*`; no whitespace skip, no NUL added |
 *  | `%s` | whitespace-delimited into `char*`; a width is REQUIRED and at most `width` bytes plus a NUL are written (buffer must hold width+1) |
 *  | `%d` `%i` | signed integer (`%i` auto-detects `0x`/`0X` hex, leading-0 octal) |
 *  | `%u` `%x` `%X` `%o` | unsigned |
 *  | `%p` | pointer as an optional `0x` prefix followed by hex |
 *
 *  Modifiers: `*` suppresses the assignment; a decimal width bounds the input
 *  field; `l`/`ll` select 64-bit for `d`/`i`/`u`/`x`/`X`/`o`. Overflowing
 *  values are clamped to the destination type's range. There is deliberately no
 *  floating point, scanset (`%[...]`), `m` allocation, or `%n`.
 *  @{ */

int asm_sscanf(const char* src, const char* fmt, ...);

/** @} */

/** @defgroup asm_arena Arena allocator (arena.asm)
 *  A chunked, resettable linear (bump) allocator. Every allocation is at least
 *  16-byte aligned and exhaustion returns `NULL` rather than overrunning
 *  memory. It is single-threaded.
 *
 *  The struct layout is part of the ABI; do not reorder the fields.
 *  @{ */

/** @brief Opaque arena chunk header. */
typedef struct asm_arena_chunk asm_arena_chunk;

/** @brief Chunked linear allocator state. */
typedef struct asm_arena {
    unsigned char* ptr;                              /**< next free byte in the current chunk */
    unsigned char* end;                              /**< end of the current chunk            */
    asm_arena_chunk* cur;                            /**< current (newest) chunk              */
    asm_arena_chunk* first;                          /**< first chunk; reset() rewinds to it  */
    void* (*alloc)(size_t size, void* ctx);          /**< backing allocator                   */
    void (*free)(void* ptr, size_t size, void* ctx); /**< release                             */
    void* ctx;                                       /**< backing allocator context           */
    size_t chunk;                                    /**< default size for new growable chunks */
    size_t total;                                    /**< usable bytes across all chunks      */
    size_t used;                                     /**< bytes handed out since last reset   */
    size_t peak;                                     /**< high-water mark of `used`           */
} asm_arena;

/** @brief Scoped rollback token for asm_arena_mark()/asm_arena_release(). */
typedef struct asm_mark {
    asm_arena_chunk* chunk;
    unsigned char* ptr;
    size_t used;
} asm_mark;

/**
 * @brief Initialise a fixed arena over caller-owned `buf` of `size` bytes.
 * @return 0 on success, or -1. The first 64 bytes are reserved for bookkeeping.
 */
int asm_arena_init(asm_arena* a, void* buf, size_t size);

/**
 * @brief Initialise a growable arena.
 * @param alloc Must return 16-byte aligned memory or NULL.
 * @param free  May be NULL.
 * @return 0, or -1.
 */
int asm_arena_init_grow(asm_arena* a, void* (*alloc)(size_t size, void* ctx),
                        void (*free)(void* ptr, size_t size, void* ctx), void* ctx,
                        size_t chunk_size);

/**
 * @brief Growable arena whose chunks come from anonymous mmap (Linux x86-64).
 *
 * Needs no libc and no caller-supplied allocator.
 * @return 0, or -1.
 */
int asm_arena_init_mmap(asm_arena* a, size_t chunk_size);

/** @brief Allocate at least `size` bytes (16-byte aligned), or `NULL`. */
void* asm_arena_alloc(asm_arena* a, size_t size);

/** @brief Allocate `size` bytes aligned to `align` (a power of two), or `NULL`. */
void* asm_arena_alloc_aligned(asm_arena* a, size_t size, size_t align);

/** @brief Allocate `count * size` zeroed bytes, or `NULL`. */
void* asm_arena_calloc(asm_arena* a, size_t count, size_t size);

/**
 * @brief Resize an allocation.
 *
 * Grows in place when it is the most recent block, otherwise moves and copies
 * `min(old, nw)` bytes. `ptr` may be NULL.
 */
void* asm_arena_realloc(asm_arena* a, void* ptr, size_t old, size_t nw);

/** @brief Snapshot the current position for scoped rollback. */
void asm_arena_mark(const asm_arena* a, asm_mark* m);

/**
 * @brief Roll back to a mark, releasing all newer chunks.
 * @return 0, or -1 if the mark does not belong to this arena.
 */
int asm_arena_release(asm_arena* a, const asm_mark* m);

/** @brief Release every chunk except the first and rewind to its start. */
void asm_arena_reset(asm_arena* a);

/** @brief Release all chunks (if a free callback is set) and clear the arena. */
void asm_arena_destroy(asm_arena* a);

/** @brief Bytes handed out since the last reset. */
size_t asm_arena_used(const asm_arena* a);

/** @brief High-water mark of asm_arena_used() since the last reset. */
size_t asm_arena_peak(const asm_arena* a);

/** @brief Free bytes remaining in the current chunk. */
size_t asm_arena_remaining(const asm_arena* a);

/** @brief Total usable bytes currently backed by all chunks. */
size_t asm_arena_capacity(const asm_arena* a);

/** @} */

/** @defgroup asm_sys Opaque OS memory primitives (sys.asm, Linux x86-64)
 *  Anonymous mmap/munmap. asm_sys_alloc()/asm_sys_free() match the arena
 *  callback signatures and can be passed to asm_arena_init_grow().
 *  @{ */

void* asm_sys_mmap(size_t size);                      /**< page-aligned or NULL  */
int asm_sys_munmap(void* ptr, size_t size);           /**< 0 or -errno           */
void* asm_sys_alloc(size_t size, void* ctx);          /**< arena alloc callback  */
void asm_sys_free(void* ptr, size_t size, void* ctx); /**< arena free callback   */

/** @} */

/** @defgroup asm_alloc malloc-style allocator (alloc.asm)
 *  A segregated free-list allocator served directly by mmap, with no libc
 *  dependency. Every pointer is 16-byte aligned.
 *
 *  @warning These manage their own heap; a pointer from asm_malloc() must be
 *  released with asm_free() and never with libc `free` (and vice versa). The
 *  allocator is single-threaded.
 *  @{ */

void* asm_malloc(size_t size);
void* asm_calloc(size_t count, size_t size);
void* asm_realloc(void* ptr, size_t size);
void asm_free(void* ptr);

/**
 * @brief Resize `ptr` to `count * size` bytes.
 * @return The new block, or `NULL` on 64-bit overflow of the product (leaving
 *         `ptr` valid).
 */
void* asm_reallocarray(void* ptr, size_t count, size_t size);

/** @brief Allocate `size` bytes aligned to `alignment` (a non-zero power of
 *         two). */
void* asm_aligned_alloc(size_t alignment, size_t size);

/**
 * @brief POSIX posix_memalign.
 * @return 0 on success, `EINVAL` (22) for a bad alignment or `ENOMEM` (12) on
 *         failure; `*memptr` is left untouched on both error paths.
 */
int asm_posix_memalign(void** memptr, size_t alignment, size_t size);

/** @brief Usable payload bytes in a block from asm_malloc(), or 0 for `NULL`. */
size_t asm_malloc_usable_size(void* ptr);

/**
 * @brief Flush the calling thread's thread-local cache back to the shared heap.
 * @return How many small blocks were returned.
 *
 * Call it from a thread-exit hook so a short-lived thread does not strand its
 * per-thread cache budget. The portable (wasm) backend has no cache and
 * returns 0.
 */
size_t asm_alloc_flush_tcache(void);

/** @} */

/** @defgroup asm_algo Sorting and searching (sort.asm / src/libc)
 *  libc-compatible `qsort`/`bsearch`. Elements are moved as raw bytes, so any
 *  element type works; the comparison function follows the libc contract.
 *  qsort is an introsort (median-of-three quicksort with an insertion-sort
 *  cutoff and a heapsort fallback), so it is O(n log n) worst case.
 *  @{ */

/** @brief Sort `nmemb` elements of `size` bytes each. */
void asm_qsort(void* base, size_t nmemb, size_t size,
               int (*compar)(const void*, const void*));

/** @brief Reentrant qsort (GNU signature: `compar(a, b, arg)`). */
void asm_qsort_r(void* base, size_t nmemb, size_t size,
                 int (*compar)(const void*, const void*, void*), void* arg);

/** @brief Binary search a sorted array.
 *  @return A pointer to a matching element, or `NULL`. */
void* asm_bsearch(const void* key, const void* base, size_t nmemb, size_t size,
                  int (*compar)(const void*, const void*));

/** @brief Reentrant bsearch (GNU signature: `compar(key, elem, arg)`). */
void* asm_bsearch_r(const void* key, const void* base, size_t nmemb, size_t size,
                    int (*compar)(const void*, const void*, void*), void* arg);

/** @} */

#ifdef __cplusplus
} /* extern "C" */
#endif

/**
 * @defgroup asm_aliases Optional libc name mapping
 * Map the standard libc names onto the `asm_*` routines. Define
 * ::ASMLIB_ENABLE_LIBC_ALIASES to activate. This is deliberately opt-in.
 * @{
 */
#ifdef ASMLIB_ENABLE_LIBC_ALIASES
#define memcpy      asm_memcpy
#define mempcpy     asm_mempcpy
#define memccpy     asm_memccpy
#define memmove     asm_memmove
#define memset      asm_memset
#define bzero       asm_bzero
#define explicit_bzero asm_explicit_bzero
#define memcmp      asm_memcmp
#define memchr      asm_memchr
#define memrchr     asm_memrchr
#define strlen      asm_strlen
#define strnlen     asm_strnlen
#define strncpy     asm_strncpy
#define stpncpy     asm_stpncpy
#define strncat     asm_strncat
#define strlcpy     asm_strlcpy
#define strlcat     asm_strlcat
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
#define reallocarray       asm_reallocarray
#define malloc_usable_size asm_malloc_usable_size
#define posix_memalign     asm_posix_memalign
#define aligned_alloc      asm_aligned_alloc
#define sprintf            asm_sprintf
#define snprintf           asm_snprintf
#define vsprintf           asm_vsprintf
#define vsnprintf          asm_vsnprintf
#define asprintf           asm_asprintf
#define vasprintf          asm_vasprintf
#if ASMLIB_OS_HEAP
#define printf             asm_printf
#define vprintf            asm_vprintf
#define dprintf            asm_dprintf
#define vdprintf           asm_vdprintf
#endif
#define qsort              asm_qsort
#define qsort_r            asm_qsort_r
#define bsearch            asm_bsearch
#define bsearch_r          asm_bsearch_r
#endif /* ASMLIB_ENABLE_LIBC_ALIASES */
/** @} */

/**
 * @addtogroup asm_umbrella
 * @{
 * The freestanding math library and the vector/matrix/quaternion API are pulled
 * in here so a program only needs `#include "asmlib.h"`. They are header-only
 * (static inline), so including them costs nothing unless used, and the linking
 * requirements are unchanged.
 * @}
 */
#include "asmlib_math.h"
#include "asmlib_vec.h"
#include "asmlib_matrix.h"

#endif /* ASMLIB_H */
