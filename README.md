# asmlib — a high-performance x86-64 assembly replacement for libc string/memory routines

[![CI](https://github.com/abiiranathan/asmlib/actions/workflows/ci.yml/badge.svg)](https://github.com/abiiranathan/asmlib/actions/workflows/ci.yml)

`asmlib` is a hand-written NASM library for x86-64 (System V AMD64 ABI) that
replaces the hottest C library memory and string functions with AVX2/BMI2
implementations. It is small, self-contained (no dependencies beyond the
assembler and linker), thoroughly tested against libc, and packaged with a C
header plus static and shared libraries.

```
src/        NASM sources (one module per area)
src/aarch64/ hand-written AArch64 assembly port (same API, NEON)
src/math/   freestanding C math library (no libc; builds for wasm32)
src/libc/   portable C memory/string/allocator backend for wasm/freestanding
include/    asmlib.h — the public C API; asmlib_math.h — the math API
tests/      differential + page-boundary + arena + malloc + math + portable suites
bench/      asmlib vs. libc micro-benchmarks, arena/malloc vs. malloc
examples/   a practical word-frequency analyser built on asmlib
```

## Highlights

* **Memory, string, comparison, search, ctype, an arena allocator and a
  malloc-style heap** — 71 routines in all, no libc dependency anywhere.
* **AVX2 / BMI1 / BMI2** where they win: 32-byte vector scans, `tzcnt`/`bsr`
  bit-indexing, branchless ASCII case folding.
* **OS memory from raw syscalls.** `mmap`/`munmap` wrappers (Linux x86-64) let
  both the arena and the malloc heap obtain memory with no libc and no
  caller-supplied allocator.
* **Chunked, resettable arena allocator** with alignment, mark/release and
  optional growth. 8–34x faster than `malloc`/`free` for the bursts arenas
  exist for.
* **malloc/calloc/realloc/free** on a segregated free-list heap backed by
  `mmap`; 6–12x faster than glibc's allocator for burst workloads.
* **Freestanding math library** for WebAssembly and bare-metal targets: 112
  double- and single-precision routines (`sin`/`sinf`, `log`/`logf`,
  `pow`/`powf`, `cbrt`, `erf`, …) in portable C with no libc, no `libm`, no
  `errno` and no global state, differential-tested against the host `libm`
  and broadly at glibc speed.
* **Page-safe**: every speculative read is either in-bounds for the requested
  length or a naturally aligned vector load that cannot straddle a page.
  A dedicated guard-page test proves this by placing buffers against a
  `PROT_NONE` page.
* **Differential tested**: 7M+ checks pass against the host libc over
  exhaustive and randomised inputs, including all alignments and edge sizes.
* **Two usage modes**: call the `asm_*` names, or define
  `ASMLIB_ENABLE_LIBC_ALIASES` to transparently replace the standard names.
* **Two architectures**: the hand-written assembly is available for x86-64
  (NASM, AVX2) and AArch64 (GNU as, NEON), exposing the same `asm_*` API; the
  AArch64 build is cross-compiled and verified under QEMU in CI.
* **WebAssembly-ready.** A portable C backend (`src/libc/`) brings the memory,
  string and allocator API to freestanding targets, and `make wasm` links it
  with the math library into `build/asmlib.wasm` — a no-import module exporting
  the standard libc/libm names.

## Requirements

* x86-64 CPU with **AVX2** and **BMI1** (`tzcnt`). The library does not fall
  back to scalar code, so query support first if you must run on older CPUs:
  the native math kernels are also compiled with FMA (`-mfma`), which is
  implied by AVX2 on every real CPU; the wasm32 build uses no FMA.

  ```c
  #include "asmlib.h"
  if (!asm_cpu_has_avx2()) { /* use libc instead */ }
  ```

* NASM 2.14+ (developed with 3.02), a C compiler, `ar`, and GNU `ld`.

## Build

```sh
make            # build/build/libasmlib.a and build/libasmlib.so
make test       # run the full test suite
make test-asan  # run it under AddressSanitizer + UndefinedBehaviorSanitizer
make test-valgrind  # run it under valgrind memcheck (OOB + leak checks)
make bench      # run the string/memory benchmark vs. libc
make bench-arena    # arena and asm_malloc vs. libc malloc (same binary)
make bench-alloc    # alias for bench-arena
make example    # run the word-frequency example
make test-math  # run the freestanding double-precision math differential tests
make test-libc  # run the portable (wasm) memory/string/allocator tests
make test-mt    # run the multithreaded allocator stress tests
make bench-math # benchmark the math library against the host libm
make wasm       # build the freestanding wasm32 module (math + portable libc)
make wasm-lib   # build the double-pendulum library module (clean C ABI)
make wasm-serve # serve the browser double-pendulum UI on :8000
make wasm-example   # non-interactive check of the pendulum library module
make aarch64        # cross-build the AArch64 port (aarch64-linux-gnu-gcc)
make test-aarch64   # run the AArch64 suites under qemu-aarch64-static
make clean
```

## Using the library

```c
#include "asmlib.h"

char  dst[64];
size_t n = asm_strlen("hello");
asm_memcpy(dst, "hello", n + 1);
int same = (asm_strcmp(dst, "hello") == 0);
```

Compile and link:

```sh
cc -O2 -Iinclude app.c -Lbuild -lasmlib -Wl,-rpath,$PWD/build
# or statically:
cc -O2 -Iinclude app.c build/libasmlib.a
```

To replace libc transparently in an existing source file:

```c
#define ASMLIB_ENABLE_LIBC_ALIASES 1
#include "asmlib.h"
/* memcpy, strlen, strcmp, ... now expand to the asm_* implementations */
```

## API

### Memory (`memory.asm`)
| Function | Notes |
|---|---|
| `void *asm_memcpy(void *dst, const void *src, size_t n)` | non-overlapping |
| `void *asm_memmove(void *dst, const void *src, size_t n)` | overlap-safe |
| `void *asm_mempcpy(void *dst, const void *src, size_t n)` | returns `dst + n` |
| `void *asm_memccpy(void *dst, const void *src, int c, size_t n)` | stops after `c` |
| `void *asm_memset(void *dst, int c, size_t n)` | |
| `void *asm_bzero(void *dst, size_t n)` | |
| `void asm_explicit_bzero(void *dst, size_t n)` | secure zero, never elided |
| `int asm_memcmp(const void *a, const void *b, size_t n)` | unsigned bytes |
| `void *asm_memchr(const void *s, int c, size_t n)` | first match |
| `void *asm_memrchr(const void *s, int c, size_t n)` | last match |

### String (`string.asm`)
`asm_strlen`, `asm_strnlen`, `asm_strncpy`, `asm_strncat`, `asm_stpncpy`,
`asm_strlcpy`, `asm_strlcat`.
The unbounded `strcpy`, `stpcpy` and `strcat` are deliberately not provided;
use the length-bounded `strlcpy`/`strlcat` or `strncpy`/`strncat` so a
destination buffer cannot be overrun.

### Comparison (`strcmp.asm`)
`asm_strcmp`, `asm_strncmp`, `asm_strcasecmp`, `asm_strncasecmp`
(case-insensitive variants use ASCII/C-locale folding).

### Searching (`search.asm`)
`asm_strchr`, `asm_strrchr`, `asm_strstr`, `asm_memmem`, `asm_strspn`,
`asm_strcspn`, `asm_strpbrk`.

### Character classification (`ctype.asm`)
`asm_toupper`, `asm_tolower`, `asm_isalpha`, `asm_isdigit`, `asm_isalnum`,
`asm_isspace`, `asm_isupper`, `asm_islower`, `asm_isxdigit`, `asm_isprint`,
`asm_iscntrl`, `asm_isgraph`, `asm_ispunct`, `asm_isblank`.
Predicates return `1` for true and `0` for false.

### CPU (`cpu.asm`)
`unsigned asm_cpu_features(void)` and `int asm_cpu_has_avx2(void)`.

### Arena allocator (`arena.asm`)

A chunked, resettable linear (bump) allocator for temporary/scratch memory.

| Function | Purpose |
|---|---|
| `asm_arena_init(a, buf, size)` | fixed arena over caller memory |
| `asm_arena_init_grow(a, alloc, free, ctx, chunk_size)` | growable arena |
| `asm_arena_init_mmap(a, chunk_size)` | growable arena backed by `mmap` |
| `asm_arena_alloc(a, size)` | 16-byte aligned block |
| `asm_arena_alloc_aligned(a, size, align)` | power-of-two aligned block |
| `asm_arena_calloc(a, count, size)` | zeroed block |
| `asm_arena_realloc(a, ptr, old, new)` | in-place growth when last |
| `asm_arena_mark(a, &m)` / `asm_arena_release(a, &m)` | scoped rollback |
| `asm_arena_reset(a)` | release all but the first chunk, rewind |
| `asm_arena_destroy(a)` | release everything |
| `asm_arena_used/peak/remaining/capacity(a)` | statistics |

Every allocation is at least 16-byte aligned and exhaustion returns `NULL`
instead of overrunning. `reset()` is O(number of chunks) and is the tool for
per-frame/per-request scratch spaces; `mark`/`release` gives nested scopes.
The backing callbacks are `alloc(size, ctx)` and `free(ptr, size, ctx)` — the
size is passed so `munmap`-style backends can release exactly.

```c
#include "asmlib.h"

asm_arena a;
asm_arena_init_mmap(&a, 1 << 16);          /* chunks straight from the kernel */

char *name = asm_arena_alloc(&a, 64);
int  *nums = asm_arena_calloc(&a, 100, sizeof *nums);
nums      = asm_arena_realloc(&a, nums, 100 * sizeof *nums, 200 * sizeof *nums);

asm_mark m;
asm_arena_mark(&a, &m);
for (int i = 0; i < 1000; i++) asm_arena_alloc(&a, 32);  /* scratch */
asm_arena_release(&a, &m);                               /* free the scratch */

asm_arena_reset(&a);          /* or rewind the whole arena at once */
asm_arena_destroy(&a);        /* release every chunk */
```

### malloc-style heap (`alloc.asm`)

A segregated free-list allocator served directly by `mmap`, for when memory
must be freed individually rather than in bulk.

| Function | Purpose |
|---|---|
| `asm_malloc(size)` | 16-byte aligned block |
| `asm_calloc(count, size)` | zeroed block |
| `asm_realloc(ptr, size)` | grow/shrink, preserving contents |
| `asm_reallocarray(ptr, count, size)` | overflow-checked resize |
| `asm_free(ptr)` | release a block |
| `asm_malloc_usable_size(ptr)` | usable bytes in a block |
| `asm_posix_memalign(&p, align, size)` | aligned block, POSIX return code |
| `asm_aligned_alloc(align, size)` | aligned block, C11 |

Small requests come from per-size-class slab runs replenished by `mmap`;
requests above 4080 bytes get an individual page-rounded mapping. Pointers
from `asm_malloc` must be released with `asm_free` (and not with libc `free`).
The heap is thread-safe: a single global spinlock serialises the free lists and
the large-mapping path, so `asm_malloc`/`asm_free`/`asm_realloc`/… may be called
concurrently from multiple threads in one address space. (The lock is a
spinlock, so the allocator is not async-signal-safe, and the arena allocator
remains single-threaded by design.) Small-class runs are retained for reuse.
`asm_posix_memalign`/`asm_aligned_alloc` support any power-of-two alignment
via a small indirect header, and the resulting pointers are released normally
with `asm_free` (and may be passed to `asm_realloc`).

```c
char *buf = asm_malloc(256);
buf = asm_realloc(buf, 1024);
asm_free(buf);
```

### Math (`src/math/`)

A **freestanding, libc-free double-precision math library** designed to run in
WebAssembly (and any freestanding target) as a drop-in `libm`. It is written in
portable C11 with no external dependencies at all: no libc, no `libm`, no
`errno`, no floating-point environment and no global state. It only needs the
compiler and the FFI-free C runtime.

By default every routine is `asm_`-prefixed so it can coexist with the host
`libm` during differential testing. Compiling with `-DASMLIB_MATH_STD_NAMES`
instead exposes the standard names, which is what `make wasm` does so the
resulting module can be linked anywhere that expects `sin`, `log`, `pow`, ….

| Group | Functions |
|---|---|
| Sign / select | `fabs`, `copysign`, `fmin`, `fmax`, `fdim` |
| Rounding | `floor`, `ceil`, `trunc`, `round`, `rint`, `nearbyint` |
| Decompose / scale | `frexp`, `modf`, `ldexp`, `scalbn`, `ilogb`, `logb` |
| Arithmetic | `fmod`, `remainder`, `sqrt`, `cbrt`, `hypot` |
| Exp / log / pow | `exp`, `exp2`, `expm1`, `log`, `log2`, `log10`, `log1p`, `pow` |
| Trig / inverse | `sin`, `cos`, `tan`, `sincos`, `asin`, `acos`, `atan`, `atan2` |
| Hyperbolic / inverse | `sinh`, `cosh`, `tanh`, `asinh`, `acosh`, `atanh` |
| Step / integer / misc | `nextafter`, `remquo`, `lrint`, `llrint`, `lround`, `llround`, `nan` |
| FMA / special | `fma`, `erf`, `erfc`, `tgamma`, `lgamma` |

All routines take and return IEEE-754 binary64. Results are **faithful**: every
routine is within 1 ulp of the true result, except `sinh`, `tanh` and `erfc`,
which reach 2 ulp in narrow bands (the bounds musl documents for its fast
formulas); `fma` is correctly rounded. Special values follow IEEE-754 (NaN
propagates, infinities and signed zero behave as `<math.h>` requires; no
function sets `errno`). `rint` and `nearbyint` always round to nearest-even
because the library never touches the floating-point environment — the only
mode WebAssembly has.

Every routine also has a **single-precision variant** (`asm_sinf`, `asm_expf`,
`asm_powf`, `asm_atan2f`, …; the standard `sinf`/`expf`/… names under
`ASMLIB_MATH_STD_NAMES`). The float routines promote to double and round once
to float, which is faithful (≤1 ulp) and keeps one implementation of each
algorithm; `fmaf` is a correctly-rounded port.

The exponential, logarithmic, power, hyperbolic and `cbrt`/`hypot` kernels are
fast table/polynomial implementations adapted from musl libc (MIT licensed; see
`src/math/NOTICE`), with a small compatibility header (`src/math/upstream.h`)
that lets the same sources build freestanding here. That keeps the library at
glibc-class speed rather than trading it away for portability.

```c
#include "asmlib_math.h"

double r = asm_hypot(3.0, 4.0);        /* 5.0 */
double y = asm_pow(2.0, 10.0);         /* 1024.0 */
double s, c; asm_sincos(0.5, &s, &c);  /* one shared reduction */
```

`make test-math` builds each family and compares it against the host `libm`
over special values and millions of randomised inputs, reporting the worst ULP
difference. `cbrt` is checked independently by cubing the result in
`long double` (glibc's own `cbrt` is up to 3 ulp off), so its accuracy does not
depend on the host libm. `make wasm` compiles every math and `src/libc` source
to `wasm32` and links `build/asmlib.wasm`; the module has **no imports** and
exports the standard names (`sin`, `exp`, …, `memcpy`, `strlen`, `malloc`, …),
so it is a drop-in freestanding libm + libc subset for WebAssembly.

## Design notes

* **ABI.** All routines follow the System V AMD64 ABI. The leaf routines use
  only caller-saved registers; the wrappers that call other routines preserve
  `rbx`/`r12`–`r15` and keep the stack 16-byte aligned at every `call`.
* **`vzeroupper`.** Every path that executes AVX instructions issues
  `vzeroupper` before returning, avoiding AVX→SSE transition penalties in the
  caller.
* **Page safety.** `strlen` and the single-pointer scanners align down to a
  32-byte boundary so a load can never cross a page. The 128-byte unrolled
  `strlen` additionally checks that the four vectors stay inside the current
  page and otherwise falls back to single 32-byte vectors. Bounded operations
  (`strnlen`, `memchr`, `memmem`, …) only read fully-contained blocks before a
  scalar finish.
* **Comparison tricks.** `strcmp`/`strncmp` compare 32 bytes per AVX2 step
  inside a page-crossing-safe window, detecting the NUL and the first
  difference with two vector compares and `tzcnt` (3.7-5x faster than the
  SWAR byte-loop they replaced, and faster than glibc's two-way `strcmp`).
  `memcmp` unrolls eight 32-byte vectors
  per iteration (all 16 YMM registers) and folds the equality masks with a
  `vpand` tree before a single `vpmovmskb`.
* **Case-insensitive compares.** `strcasecmp`/`strncasecmp` fold 32 bytes at
  a time with AVX2 (`vpsubb`/`vpminub`/`vpcmpeqb`/`vpand`/`vpor`), and
  amortise the page-safety check over the whole run of full vectors that
  stays inside the current page instead of testing every iteration.
* **Searching.** `memmem`/`strstr` make a single pass over 32-byte aligned
  blocks, matching the first **two** needle bytes with two vector compares so
  only genuine two-byte candidates reach the full `memcmp`. A final scalar
  check covers the last byte of each block. `strstr` special-cases a
  one-byte needle to `strchr`, so it never computes `strlen(haystack)` when a
  match can be found immediately.
* **Accept sets.** `strspn`/`strcspn`/`strpbrk` build a 256-byte membership
  table on the stack, so scanning is a single linear pass.
* **Cache behaviour.** `memset` uses ERMS `rep stosb` for fills of 4 KiB or
  more, and `memcpy` picks the copy engine by size — plain 256-byte AVX2
  below 96 KiB, ERMS `rep movsb` from 96 to 256 KiB, and non-temporal
  128-byte stores (with an `sfence`) above 256 KiB when the destination is
  32-byte aligned. Those thresholds (and the NT block size) were chosen from
  measurements on the target CPU: plain copies saturate the cache hierarchy
  up to L2, ERMS wins in the L3 range, and streaming stores avoid
  read-for-ownership traffic once both buffers exceed it.
* **`strchr` aligns down.** Instead of walking to a 32-byte boundary one byte
  at a time, the head block is loaded from the aligned address below `s` and
  the bytes before `s` are masked off with a shift — the same trick `strlen`
  uses, so unaligned strings cost one vector instead of up to 31 scalar steps.
* **Arena.** Chunks carry a 48-byte header (backing pointer, chain link,
  usable capacity, backing size, data pointer); allocations bump a pointer
  and round the size up to 16 bytes. Growing keeps the caller's allocator, so
  the allocator itself has no dependency on `malloc`; `asm_arena_init_mmap`
  supplies one backed by anonymous `mmap`. `reset` frees every chunk after the
  first in one pass; a `mark` records the chunk, pointer and byte count so
  `release` can rewind and reclaim precisely. The free callback receives the
  chunk's backing size so `munmap` can unmap it exactly.
* **OS memory and the malloc heap.** `sys.asm` holds the only platform
  specific code — raw `mmap`/`munmap` syscalls (Linux x86-64). `alloc.asm`
  builds `malloc`/`calloc`/`realloc`/`free` on top: requests up to 4080 bytes
  are rounded to a 16-byte size class and served from a per-class free list
  replenished by a slab run; larger requests get their own page-rounded
  mapping. Every block is 16-byte aligned and carries a 16-byte header with
  its class (or the mapping length), so `free` needs no size argument. The
  heap is thread-safe (spinlock) and retains small-class runs.

### Performance approach

`strlen` reduces eight aligned vectors per iteration with a `vpminub` tree
(4 ALU ops per 128 bytes instead of 7), `memcmp` and `memcpy` unroll to 256
bytes, `strcasecmp` folds 32 bytes per AVX2 step, and small
`memchr`/`memcmp` sizes use overlapping page-safe vector windows rather than
byte loops. Against glibc the memory routines are at or near parity, `memchr`
is consistently faster, `memmem` is several times faster than libc's, and the
case-insensitive compares went from 20-50x slower to parity for short strings
and about 0.5-0.8x for long ones. `strstr` (which glibc implements with a
dedicated two-way algorithm) is within roughly 0.6-0.8x.

## Testing

`make test` runs `tests/test_asmlib.c`, which:

1. compares every routine against its libc counterpart across sizes, offsets
   and random contents (about 3 million assertions);
2. exercises all small sizes and valid alignments, including `n == 0`;
3. mmaps buffers so their final byte abuts a `PROT_NONE` guard page and
   catches any `SIGSEGV` with a handler, proving there are no out-of-bounds
   reads or writes (this is how the `strlen` page-boundary fallback is
   verified);
4. sanity-checks the CPU feature detection.

and `tests/test_arena.c`, which covers fixed, growable and mmap-backed arenas,
alignment, exhaustion returning `NULL`, `calloc`/`realloc`, `mark`/`release`,
`reset` and a randomised overlap stress test (every block is tagged and
re-verified so any overlap or corruption is caught).

`tests/test_alloc.c` covers the malloc-style heap: alignment, `calloc`
zeroing, `realloc` in place and across the small/large boundary, and a
200,000-operation randomised alloc/free/realloc stress test with content
tagging. `make test` also runs the multithreaded stress tests
(`tests/test_alloc_mt.c` and `tests/test_portable_alloc_mt.c`): several threads
run millions of mixed allocate/free/realloc operations with per-block tags and
report any corruption, exercising both allocators' locks.

`make test-math` runs one differential binary per math family
(`tests/test_math_*.c`). Each compares the implementation against the host
`libm` over a table of IEEE-754 special values and up to a million randomised
inputs, failing if the worst-case ULP difference exceeds 1 (`sinh`/`tanh` allow
2, the bound musl documents for its fast formulas). `cbrt` is checked by cubing
the result in `long double` instead of against glibc, whose `cbrt` is itself up
to 3 ulp off.

Three helper targets exercise the same suites under dynamic analysis:

* `make test-asan` builds with `-fsanitize=address,undefined` (and leak
  detection) and runs it. This catches any harness bug and any heap/stack
  corruption; the current suite is clean.
* `make test-valgrind` runs `valgrind --tool=memcheck` with `--error-exitcode=99`
  and full leak checking. It is clean (0 errors, 0 leaks). The target passes
  `--undef-value-errors=no`: valgrind cannot model AVX2 register definedness,
  so it emits spurious "uninitialised value" reports for any SIMD string
  routine (it flags glibc's own routines the same way), while invalid
  reads/writes and leaks are still detected.

Both tools found and helped fix issues during development, including a
harness bug where a string pointer was offset past the terminating NUL.

## Benchmark

`make bench` reports nanoseconds/call for asmlib vs. glibc and the speedup
(`> 1.00x` means asmlib is faster). Results are hardware-dependent and noisy;
on the development machine (Intel Comet Lake, glibc 2.44) the library is now
broadly at parity: `memchr` is consistently faster, mid/large `memcpy`,
`memset` and `memcmp` are around 1.0x, and glibc remains somewhat ahead on
the most heavily optimised `strstr` (two-way) and on the smallest sizes where
call overhead dominates. The benchmark makes the trade-offs visible and
guards against regressions.

`make bench-arena` (alias `make bench-alloc`) compares the arena and the
malloc heap against glibc `malloc`/`free`. Both use only raw `mmap` — there is
no libc allocator on their side. On the development machine (best of 9 trials,
ns per operation):

```
workload                              asm       malloc   speedup
arena   1000 x 64B                   3.54        29.06     8.22x
arena   4000 mixed 8..512B           3.35        62.24    18.60x
arena   1000 x 64B +memset           5.16        30.76     5.96x
malloc  1000 x 64B                   5.07        29.20     5.76x
malloc  4000 mixed 8..512B           5.80        69.72    12.01x
2048 x 1KiB fill+release (us)        15.40       521.73    33.87x
```

The arena wins because allocation is a pointer bump, the memory is contiguous
(cache-predictable), and a reset is one rewind rather than thousands of
`free` calls. The malloc heap wins over glibc on burst workloads because its
per-class free lists are a couple of instructions. The trade-offs — the arena
reclaims in bulk or to a mark, and the arena stays single-threaded while the
malloc heap takes a lock, are the usual ones for these designs.

`make bench-math` runs `bench/math_bench.c`, which times every math routine
against the host `libm` on representative inputs (best of 7, ns/call). On the
development machine (glibc 2.44):

```
function         libm     asmlib   speedup
sqrt             2.18       2.15     1.01x
cbrt            21.98      10.67     2.06x
fmod            13.72      14.72     0.93x
exp              7.01       6.85     1.02x
exp2             5.41       5.66     0.96x
expm1            5.96      10.23     0.58x
log              7.01       7.47     0.94x
log2             6.92       8.11     0.85x
pow             23.60      22.95     1.03x
sin             20.23      26.95     0.75x
cos             28.84      27.99     1.03x
tan             27.03      26.07     1.04x
asin            12.24      12.67     0.97x
atan2           26.78      26.97     0.99x
cosh            13.46       9.82     1.37x
sinh            14.84      28.17     0.53x
tanh             6.64       9.68     0.69x
asinh           28.45      20.70     1.37x
```

`cbrt` is more than twice as fast, `pow`/`exp`/`cos`/`tan`/`cosh`/`asinh` are
at or above parity, and the rest sit within roughly 0.6-1.0x of glibc's
hand-tuned kernels. Native builds use FMA (implied by AVX2) for the kernels
that support it; the wasm32 build stays FMA-free and uses the portable
fallbacks, so the same sources run unchanged there. The earlier double-double
kernels (which cost 20-60x for `exp`/`pow`/`sinh`) are gone.

### Profiling with perf

`make perfbench` builds `bench/perfbench.c`, a harness that runs **one
operation per invocation** so `perf` attribution is unambiguous:

```sh
perf record -o /tmp/p.data ./build/perfbench strcmp 100000
perf report -i /tmp/p.data --no-children --sort=symbol --stdio
perf stat    -e task-clock,cycles,instructions ./build/perfbench memcpy 100000
```

That harness drove the latest round of tuning: it showed `strcmp`'s 8-byte
SWAR loop at 0.69 cycles/byte (4.6x slower than glibc), `memmem` spending 21%
of its scan in the scalar last-byte check, and `strchr` burning 44% of a
short scan stepping to alignment. The first two and the third led to the
AVX2 `strcmp`, the ERMS/NT `memcpy` geometry, and the align-down `strchr`
respectively.

## Example

`examples/example.c` — a word-frequency analyser that reads a text file (or
builds a synthetic corpus) and:

* counts bytes, lines and words with `asm_memchr`, `asm_strspn`, `asm_strcspn`;
* lower-cases and stores tokens with `asm_tolower`/`asm_memcpy`;
* maintains an open-addressing hash table keyed with `asm_strcmp`;
* counts substring occurrences with the SIMD `asm_memmem`;
* demonstrates `asm_strcasecmp`.

```
$ make example
== asmlib word-frequency example ==
  corpus      : 2900000 bytes, 1 lines
  words       : 540000 total, 21 unique
  top words:
    the          80000
    ...
  occurrences of "lazy dog": 40000
  strcasecmp("Hello", "hELLo") = 0
```

### Double-pendulum WebAssembly demo

`examples/double_pendulum.c` is built as a **library** module and driven from a
browser UI rather than a script. It integrates a chaotic double pendulum with
RK4 and exposes a small C ABI — `dp_init`, `dp_step`, `dp_state`, `dp_tip_x`,
`dp_tip_y`, `dp_energy_drift`, `dp_buffer` — exported explicitly (no
`--export-all`), while the module supplies all its math (`sin`, `cos`, `fabs`)
and, through the portable backend, `malloc`/`free`. There are **no imports**:
the browser provides nothing.

```sh
make wasm-lib     # build examples/web/double_pendulum.wasm (a clean ABI)
make wasm-serve   # serve examples/web/ at http://localhost:8000
```

`examples/web/index.html` is a self-contained page (canvas + controls) that
loads the module, steps the simulation once per animation frame through
`dp_step`, and draws the rods, bobs and a fading trace. The UI shows live
energy drift and angular velocities — a visible, real-world check that the
library's math and memory routines are correct under continuous use.

For a non-interactive check of the same ABI, `make wasm-example` runs
`examples/double_pendulum.js`:

```
$ make wasm-example
== asmlib wasm double-pendulum library ==
  module          : 13207 bytes, 0 imports
  samples         : 200000 steps (100.0 s)
  wall time       : 264.8 ms  (0.8M steps/s)
  energy drift    : 6.319e-11
  tip x range     : [-1.9919, 2.0000]
  tip y range     : [-1.9996, 0.4828]
  max reach       : 2.0000 m (bound 2 m)
OK: library ABI conserved energy and stayed physical
```

The driver checks the module is import-free, the RK4 integrator conserves
energy to ~1e-9 relative, the tip never leaves the 2 m arm reach, and the
single-precision path stays finite. The same source builds natively (host
libm) for cross-checking.

## Freestanding and portability

The string/memory routines and the arena's fixed and callback modes have no
OS or libc dependency and link under `-nostdlib`. The only platform-specific
code is `src/sys.asm` (Linux x86-64 `mmap`/`munmap`); on bare metal or another
OS, pass your own `alloc`/`free` to `asm_arena_init_grow` and skip
`asm_arena_init_mmap` and `asm_malloc`. The test/benchmark harnesses use libc,
but the library itself does not.

The math library (`src/math/`) is freestanding by construction: it calls no
libc or `libm`, sets no `errno`, uses no floating-point environment and keeps
no global state, so a `wasm32` build (or any freestanding target) links with
nothing.

`src/libc/` is a portable C implementation of the same memory, string and
allocator API (`memcpy`, `strlen`, `strlcpy`, `malloc`, `posix_memalign`, …)
for targets where the NASM code cannot run. It is freestanding (no libc) and
its allocator serves a first-fit free list from `__heap_base`,
growing WebAssembly linear memory with `memory.grow` on demand (a fixed static
pool is used in the native tests). The portable allocator is also thread-safe
(C11 atomics; a no-op lock on wasm builds without threads). `make test-libc`
differentially tests it
against the host libc, including a guard-page suite; `make wasm` links it
together with the math library into `build/asmlib.wasm`, a **complete
freestanding libc-subset + libm** module with no imports. The arena allocator
is not yet available on wasm (it is NASM today); the portable `malloc` is the
wasm allocator.

## AArch64 port

The API in `include/asmlib.h` is architecture-neutral, and the library now has
a hand-written **AArch64** implementation in `src/aarch64/` (GNU assembly, NEON)
covering the whole string/memory/search/ctype/arena/malloc surface — the same
`asm_*` symbols as the x86-64 NASM build:

```
src/aarch64/  common_aarch64.inc  sys.S  memory.S  string.S  strcmp.S
              search.S  ctype.S  cpu.S  arena.S  alloc.S
```

It follows AAPCS64 (arguments `x0..x7`, callee-saved `x19..x29`, 16-byte stack)
and uses the AArch64 `mmap`/`munmap` syscalls. `asm_cpu_has_avx2()` returns 0
(those feature bits are x86-only).

Build and test it by cross-compiling and running the *same* differential suites
under QEMU user-mode emulation:

```sh
make aarch64        # cross-build build/aarch64/libasmlib.a
make test-aarch64   # build + run test_asmlib/test_arena/test_alloc under qemu
```

Requires `aarch64-linux-gnu-gcc` (gcc-aarch64-linux-gnu) and `qemu-aarch64-static`
(qemu-user-static). All three suites pass on AArch64 (7.56M + 423 + 1,225 checks,
0 failures), and CI runs this on every push.

## License

MIT — see [`LICENSE`](LICENSE). Portions of `src/math/` are adapted from musl
libc and carry their own MIT notice in [`src/math/NOTICE`](src/math/NOTICE).
Provided as-is, without warranty.
