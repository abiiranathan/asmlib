# asmlib — hand-written x86-64 and AArch64 assembly, plus a freestanding wasm build

[![CI](https://github.com/abiiranathan/asmlib/actions/workflows/ci.yml/badge.svg)](https://github.com/abiiranathan/asmlib/actions/workflows/ci.yml)

`asmlib` replaces the hottest C library memory, string, comparison, search,
ctype and allocator routines with hand-written assembly — twice over: an x86-64
backend (NASM, AVX2/BMI2) and an AArch64 backend (GNU assembly, NEON), exposing
the same `asm_*` API. A portable C backend (`src/libc/`) and a libc-free math
library (`src/math/`) bring that same surface to WebAssembly and other
freestanding targets. It is small, self-contained (nothing beyond the assembler,
compiler and linker), thoroughly tested against libc, and packaged as one C
header (`asmlib.h`, which also pulls in the math and vector/matrix APIs) plus
static and shared libraries.

```
src/        NASM sources (memory, string, comparison, search, ctype, alloc, format, scan)
src/aarch64/ hand-written AArch64 assembly port (same API, NEON)
src/math/   freestanding C math library (no libc; builds for wasm32)
src/libc/   portable C memory/string/allocator/format/scan backend for wasm/freestanding
include/    asmlib.h / asmlib_math.h / asmlib_vec.h / asmlib_matrix.h
tests/      differential + page-boundary + arena + malloc + format + scan + linalg + math
bench/      asmlib vs. libc micro-benchmarks (routines, allocators, formatting, scanning)
examples/   word-frequency analyser + wasm double-pendulum and image-editor demos
```

## Platforms

| Target | Backend | Toolchain |
|---|---|---|
| x86-64 (System V AMD64) | `src/*.asm` — NASM, AVX2/BMI | NASM 2.14+ (3.02 tested), C compiler, `ar`, GNU `ld` |
| AArch64 (AAPCS64) | `src/aarch64/*.S` — GNU assembly, NEON | `aarch64-linux-gnu-gcc`; `qemu-aarch64-static` to run the tests |
| WebAssembly (wasm32) | `src/libc/` + `src/math/` — portable C | `clang --target=wasm32-unknown-unknown`, `wasm-ld` |
| other freestanding | `src/libc/` + `src/math/` — portable C | any C11 compiler |

The x86-64 and AArch64 backends expose the identical `asm_*` API (77 routines
each) and are validated by the same differential suites; WebAssembly and other
freestanding targets get the memory/string/allocator/format/scan API plus the
math library.

## Highlights

* **Memory, string, comparison, search, ctype, an arena allocator, a
  malloc-style heap, and formatting/scanning helpers** — 77 routines in all, no
  libc dependency anywhere.
* **SIMD where it wins.** 32-byte AVX2/BMI scans (`vpsubb`, `vpminub`,
  `tzcnt`/`bsr`) on x86-64 and NEON (`cmeq`/`umaxv`, `ldp`/`stp`) on AArch64,
  both with branchless ASCII case folding.
* **One library, any x86-64.** The memory/string/comparison/search entry
  points are resolved by the dynamic loader (ELF IFUNC on hosted Linux) to AVX2
  or to a portable scalar implementation, so a single binary degrades gracefully
  on pre-Haswell CPUs with **no per-call dispatch cost**;
  `#include "asmlib.h"` is the whole API.
* **OS memory from raw syscalls.** `mmap`/`munmap` wrappers (Linux x86-64 and
  AArch64) let both the arena and the malloc heap obtain memory with no libc
  and no caller-supplied allocator.
* **Chunked, resettable arena allocator** with alignment, mark/release and
  optional growth. 3–20x faster than `malloc`/`free` for the bursts arenas
  exist for, and 30–45x faster for a bulk reset of thousands of blocks.
* **malloc/calloc/realloc/free** on a segregated free-list heap backed by
  `mmap`; roughly 5–8x faster than glibc's allocator for burst workloads.
* **Fast, safe formatting and scanning.** Bounded
  `asm_u64toa`/`asm_i64toa`/`asm_u64tohex` converters, `asm_snprintf`
  (1.5–4x glibc) and `asm_sscanf` (2–3x glibc). Every `%s`/`%c` read is bounded
  by a required width and the scanner never reads past the input's NUL; no
  floating point, precision or locale.
* **Vector, matrix and quaternion math.** `asmlib_vec.h` and `asmlib_matrix.h` port
the solidc Vec2/3/4, Mat3/Mat4 and Quat API (~200 operations) to a
freestanding, header-only library built on asmlib's own math routines — no
libc, no libm, and it compiles on x86-64, AArch64 and wasm32.
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
* **Three portability tiers**: native x86-64 (NASM) and AArch64 (GNU as)
  assembly behind one `asm_*` API — the AArch64 build is cross-compiled and run
  under QEMU in CI — plus a portable C backend (`src/libc/`) for WebAssembly and
  other freestanding targets.
* **WebAssembly-ready**: `make wasm` links the portable backend with the math
  library into `build/asmlib.wasm`, a no-import module exporting the standard
  libc/libm names.

## Runtime requirements

One library runs on any x86-64 CPU. The memory/string/comparison/search entry
points are **resolved once, by the loader**: on hosted Linux x86-64 each public
symbol is an ELF indirect function (`src/dispatch_ifunc.c`, `STT_GNU_IFUNC`)
whose resolver returns the hand-written AVX2 routine when the CPU has AVX2 + the
OS enables its state, otherwise the portable scalar routine (the same code the
wasm build uses). There is no branch on the hot path. On other hosts a portable
forwarder is used (`src/dispatch.c`), which probes AVX2 + BMI1 lazily on the
first call. Either way there is no error, no environment variable, no separate
library. `asm_cpu_has_avx2()` reports the choice; `asm_cpu_require_avx2()` is
available if a program would rather fail fast (message + `exit(2)`) than run the
slower path.

`make test-fallback` runs the differential suites under QEMU with a CPU that has
no AVX2 (Nehalem), which exercises the scalar path end to end. For a purely
scalar build there is also `make scalar-lib` → `build/libasmlib_scalar.a` (the
portable C backend, no SSE4.1/FMA, same `asm_*` names); the `-nostdlib`
freestanding test links that archive, since IFUNC relocations need a C runtime.

The native math kernels additionally use FMA (`-mfma`), which AVX2 implies on
every real CPU; the wasm32 build uses no FMA. On AArch64, NEON is part of the
baseline ISA, so no feature check is needed — `asm_cpu_has_avx2()` returns 0
there by design.

## Build

```sh
make            # build/build/libasmlib.a and build/libasmlib.so
make test       # run the full test suite
make test-asan  # run it under AddressSanitizer + UndefinedBehaviorSanitizer
make fuzz       # libFuzzer: converters, snprintf, sscanf, linalg (needs clang)
make test-valgrind  # run it under valgrind memcheck (OOB + leak checks)
make bench      # run the string/memory benchmark vs. libc
make bench-arena    # arena and asm_malloc vs. libc malloc (same binary)
make bench-alloc    # alias for bench-arena
make bench-format   # asm_snprintf / asm_u64toa vs. libc snprintf
make bench-scan     # asm_sscanf vs. libc sscanf
make example    # run the word-frequency example
make test-math  # run the freestanding double-precision math differential tests
make test-libc  # run the portable (wasm) memory/string/allocator tests
make test-freestanding  # -nostdlib smoke: arena/math/format/scan/linalg, no OS
make scalar-lib # non-AVX2 fallback library (portable C backend)
make test-scalar    # run the portable tests against the scalar library
make test-fallback  # run the differential suites with no AVX2 (under qemu)
make test-mt    # run the multithreaded allocator stress tests
make bench-math # benchmark the math library against the host libm
make wasm       # build the freestanding wasm32 module (math + portable libc)
make wasm-lib   # build the double-pendulum library module (clean C ABI)
make wasm-serve # serve the browser double-pendulum UI on :8000
make wasm-example   # non-interactive check of the pendulum library module
make wasm-image     # build the image-editing wasm module
make wasm-image-example # non-interactive check of the image module
make wasm-image-serve   # serve the image-editor UI on :8000
make aarch64        # cross-build the AArch64 port (aarch64-linux-gnu-gcc)
make test-aarch64   # run the AArch64 suites under qemu-aarch64-static
make docs       # build the HTML API reference (Doxygen) -> build/docs/html
make clean
```

### With CMake

The library (static, shared and the scalar fallback) and its install rules can
also be driven by CMake, as an alternative to the Makefile:

```sh
cmake -S . -B build-cmake
cmake --build build-cmake
cmake --install build-cmake --prefix /usr/local
```

This installs the headers, `libasmlib.{a,so}`, `libasmlib_scalar.a`, a
relocatable `asmlib.pc`, and a CMake package config. Consumers can then use

```cmake
find_package(asmlib 1.0 REQUIRED)
target_link_libraries(app PRIVATE asmlib::asmlib)          # shared
# target_link_libraries(app PRIVATE asmlib::asmlib_static) # static
# target_link_libraries(app PRIVATE asmlib::asmlib_scalar) # scalar fallback
```

or, straight from a checkout, `add_subdirectory(path/to/asmlib)` and link the
same targets (install rules are off when it is embedded).

CMake builds the same two hand-written backends as the Makefile, selected from
the target processor: x86-64 (NASM, with the AVX2/scalar dispatch) and AArch64
(GNU as, NEON). Cross-compiling to AArch64 uses the bundled toolchain file:

```sh
cmake -S . -B build-aarch64 -DCMAKE_TOOLCHAIN_FILE=cmake/toolchain-aarch64.cmake
cmake --build build-aarch64
```

The test suite, wasm and fuzzing targets stay on `make`.

## Installing

`make install [PREFIX=/usr/local] [DESTDIR=stage] [LIBDIR=...] [INCLUDEDIR=...]`
installs the headers, the static and shared libraries, the scalar fallback
library and an `asmlib.pc` pkg-config file:

```sh
make install PREFIX=/usr/local DESTDIR=/tmp/stage
cc $(pkg-config --cflags asmlib) app.c $(pkg-config --libs asmlib)
make uninstall PREFIX=/usr/local DESTDIR=/tmp/stage
```

The CMake build installs the same layout plus a package config
(`find_package(asmlib)` → `asmlib::asmlib`); see [With CMake](#with-cmake).

The version is defined in `include/asmlib_version.h` (`ASMLIB_VERSION_STRING`,
`ASMLIB_VERSION_NUMBER`) and available at run time from `asm_version()`.

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

### Formatting (`format.asm`)

Bounded integer-to-string converters plus a small, fast snprintf. All are
freestanding (no libc) and implemented for x86-64, AArch64 and the portable C
backend.

| Function | Purpose |
|---|---|
| `asm_u64toa(value, buf, cap)` | unsigned decimal |
| `asm_i64toa(value, buf, cap)` | signed decimal (`-` for negatives) |
| `asm_u64toa_base(value, buf, cap, base)` | base 2..36, lowercase |
| `asm_u64tohex(value, buf, cap, uppercase)` | hexadecimal, no `0x` |
| `asm_snprintf(dst, size, fmt, ...)` | minimal snprintf |

Each converter writes at most `cap` bytes (including a NUL when `cap > 0`) and
returns the length the full representation needs, so `ret >= cap` flags
truncation; `cap == 0` writes nothing and returns only the length.

`asm_snprintf` follows C99 snprintf's return value and bounds. It supports
`%%`, `%c`, `%s` (NULL prints `(null)`), `%p` (`0x` + lowercase hex, NULL prints
`(nil)`), `%d`/`%i`, `%u`, `%x`/`%X` and `%o`, with the `-` (left) and `0`
(zero-pad) flags, a decimal width, and the `l`/`ll` length modifiers for 64-bit
integers. Anything else after `%` is copied through literally and consumes no
argument. There is deliberately **no** floating point, precision, `*`, locale or
`%n`.

```c
#include "asmlib.h"

char buf[32];
asm_u64toa(18446744073709551615ULL, buf, sizeof buf);   /* "18446744073709551615" */
asm_i64toa(-42, buf, sizeof buf);                       /* "-42" */
asm_u64tohex(0xdeadbeef, buf, sizeof buf, 1);           /* "DEADBEEF" */
asm_snprintf(buf, sizeof buf, "id=%05d n=%-8s x=0x%08x", 7, "bob", 0xabc);
/* "id=00007 n=bob      x=0x00000abc" */
```

### Scanning (`scan.asm`)

A small, safe counterpart to `asm_snprintf`:

`int asm_sscanf(const char* src, const char* fmt, ...)` returns the number of
successful assignments, or `-1` on input failure before the first conversion
or a malformed format. It never reads past `src`'s NUL.

| Conversion | Meaning |
|---|---|
| `%%` | literal `%` |
| `%c` | `width` bytes (default 1) into `char*`; no whitespace skip, no NUL |
| `%s` | whitespace-delimited, NUL-terminated; a width is required (unless suppressed) and at most `width` bytes plus a NUL are written |
| `%d` `%i` | signed integer; `%i` auto-detects `0x`/leading-`0` |
| `%u` `%x` `%X` `%o` | unsigned |
| `%p` | pointer as optional `0x` + hex |

`*` suppresses the assignment, a decimal width bounds the field, and `l`/`ll`
select 64-bit integers. Overflow saturates to the destination type. There is no
floating point, scanset, `%n` or `m`. Supported by the x86-64, AArch64 and
portable backends.

```c
int n; char name[32];
int got = asm_sscanf("id=42 name=zed", "id=%d name=%15s", &n, name);
/* got == 2, n == 42, name == "zed" */
```

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
The heap is thread-safe: each thread keeps a **thread-local cache** of freed
small blocks (initial-exec TLS on x86-64, local-exec on AArch64), so the hot
`asm_malloc`/`asm_free` path touches no lock at all; a single global spinlock
only serialises run refills, over-budget frees, large mappings and the aligned
machinery. The cache is bounded by a per-thread byte budget (1 MiB) so memory
cannot grow without limit. A thread that exits with a partially filled cache
would strand it; call `asm_alloc_flush_tcache()` from a pthread key destructor
(a thread-exit hook) to return those blocks to the shared heap — the portable
wasm backend has no cache and returns 0. (The lock makes the allocator not
async-signal-safe, and the arena allocator remains single-threaded by design.)
Small-class runs are retained for reuse.
`asm_posix_memalign`/`asm_aligned_alloc` support any power-of-two alignment
via a small indirect header, and the resulting pointers are released normally
with `asm_free` (and may be passed to `asm_realloc`).

Building the library with `-DASMLIB_ALLOC_DEBUG` (NASM `-D` for the x86-64
backend, the C define for the portable one) hardens the heap: the native
allocator traps on a double free of a small block, and the portable backend
also fills freed/fresh payloads with `0xDD`/`0xCD`, rejects misaligned or
foreign pointers, and reports live block/byte counts via
`asm_alloc_debug_live_blocks()`/`asm_alloc_debug_live_bytes()`.

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

### Vector, matrix and quaternion math (`asmlib_vec.h`, `asmlib_matrix.h`)

A port of the solidc `vec.h`/`matrix.h` API: `asm_vec2`/`asm_vec3`/`asm_vec4`
storage types, `asm_simd_vec2`/`asm_simd_vec3`/`asm_simd_vec4` compute types,
`asm_mat3`/`asm_mat4` and `asm_quat`, with ~200 operations (add/sub/mul, dot,
cross, normalise, project/reject, reflect/refract, lerp, rotations, matrix
multiply/inverse/transpose/determinant, perspective/look-at/unproject, and
quaternion axis-angle/euler/mul/slerp conversions).

The headers are header-only and freestanding: they call asmlib's own
`asm_sqrtf`/`asm_sinf`/`asm_cosf`/`asm_atan2f`/`asm_expf`/`asm_tanhf`/… routines
(via `ASM_MATH`), so there is no libc and no libm. The freestanding math objects
are linked into `libasmlib.a`/`libasmlib.so`, so a native program only needs
`-lasmlib`; for the wasm module compile the headers with
`-DASMLIB_MATH_STD_NAMES` to match the exported names.

```c
#include "asmlib_matrix.h"

asm_simd_vec3 n = asm_vec3_normalize(asm_vec3_load((asm_vec3){3, 4, 12}));
asm_mat4 view  = asm_mat4_look_at(asm_vec3_load((asm_vec3){0, 0, 5}),
                                  asm_vec3_load((asm_vec3){0, 0, 0}),
                                  asm_vec3_load((asm_vec3){0, 1, 0}));
asm_quat q     = asm_quat_from_axis_angle((asm_vec3){0, 1, 0}, 0.7f);
asm_simd_vec3 r = asm_quat_rotate_vec3(q, n);
```

The SIMD abstraction is a portable scalar implementation (the same `asm_simd_*`
shim used by the original), so the code compiles unchanged everywhere; the
compiler auto-vectorises the component-wise loops. One deliberate fix: the
reference `mat4_inverse` returns `-M⁻¹` for rotation/scale matrices, so asmlib
uses a Gauss–Jordan inverse instead.

## Design notes

The notes below describe the x86-64 backend; the AArch64 port mirrors the same
design using NEON and AAPCS64 (see [AArch64 port](#aarch64-port)).

* **ABI.** On x86-64, all routines follow the System V AMD64 ABI. The leaf
  routines use only caller-saved registers; the wrappers that call other
  routines preserve `rbx`/`r12`–`r15` and keep the stack 16-byte aligned at
  every `call`.
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
* **OS memory and the malloc heap.** The only platform-specific code is the
  raw `mmap`/`munmap` syscall layer — `src/sys.asm` on Linux x86-64,
  `src/aarch64/sys.S` on Linux AArch64. `alloc` builds
  `malloc`/`calloc`/`realloc`/`free` on top: requests up to 4080 bytes
  are rounded to a 16-byte size class and served from a per-class free list
  replenished by a slab run; larger requests get their own page-rounded
  mapping. Every block is 16-byte aligned and carries a 16-byte header with
  its class (or the mapping length), so `free` needs no size argument. Each
  thread caches its own freed small blocks in TLS for a lock-free hot path;
  a global spinlock guards the shared lists and retains small-class runs.

### Performance approach

The x86-64 backend reduces eight aligned vectors per iteration in `strlen`
with a `vpminub` tree (4 ALU ops per 128 bytes instead of 7), unrolls `memcmp`
and `memcpy` to 256 bytes, folds 32 bytes per AVX2 step in `strcasecmp`, and
uses overlapping page-safe vector windows for small `memchr`/`memcmp` sizes
instead of byte loops. The AArch64 port mirrors these choices in NEON
(`cmeq`/`umaxv` reductions, `ldp`/`stp` block moves).

Measured against glibc 2.44 on the development machine, `memchr` is
consistently faster (≈1.1–1.2x from 128 bytes up) and mid/large `memcpy`,
`memset` and `memcmp` are at parity (≈0.95–1.2x). glibc keeps the edge on
`strlen` (≈0.5–0.8x under 64 KiB) and on its two-way `strstr` (≈0.4–0.65x),
and `memmem` is several times faster than libc's.

## Testing

`make test` runs `tests/test_asmlib.c`, which:

1. compares every routine against its libc counterpart across sizes, offsets
   and random contents (about 7.5 million checks);
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
run millions of mixed allocate/free/realloc operations with per-block tags,
hand blocks to each other to free cross-thread, and report any corruption,
exercising both allocators' locks and the thread-local caches.
`tests/test_alloc_threads.c` churns 32 short-lived threads and flushes each
thread's cache on exit. `tests/test_alloc_debug.c` and
`tests/test_portable_alloc_debug.c` build the allocators with
`ASMLIB_ALLOC_DEBUG` and fork to prove a double free (and, for the portable
backend, a misaligned pointer) traps.

`tests/test_format.c` differentially checks every supported `asm_snprintf`
conversion against the host `snprintf` — byte for byte and by return value —
across values, flags, widths, length modifiers and buffer sizes (including
truncation and `size == 0`), exercises the converters against a hand-written
reference and 50,000 random 64-bit values, and places buffers against a
`PROT_NONE` guard page to prove the writes never exceed `cap`. The same source
also validates the portable C backend via `make test-libc`.

`tests/test_scan.c` differentially checks every supported `asm_sscanf`
conversion against the host `sscanf` — return value and parsed value — over
integers (all bases, signs, prefixes, overflow, truncation), strings, chars,
suppression, literals and whitespace, and uses guard pages to prove the source
is never read past its NUL and that `%s`/`%c` never write past the declared
width. It runs under `make test`, `test-aarch64`, `test-libc` and `test-asan`.

`tests/test_linalg.c` checks the vector/matrix/quaternion port against
hand-computed values, a small independent scalar reference and algebraic
identities: cross/dot/normalisation, `M * M⁻¹ = I` for Mat3 and Mat4,
perspective/look-at/unproject round-trips, and quaternion rotation agreeing
with the equivalent matrix. It runs under `make test`, `test-aarch64` and
`test-asan`.

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

`make fuzz` builds and runs the libFuzzer targets in `fuzz/` (number
converters, `asm_snprintf`, `asm_sscanf` and the vector/matrix/quaternion
math) under AddressSanitizer + UBSan. Each target compares against the host
libc where the subset matches and checks its invariants otherwise. CI runs a
short budget on every push; see `ROADMAP.md` for the production punch list.

## Benchmark

[`docs/BENCHMARKS.md`](docs/BENCHMARKS.md) is the methodology and results page:
it documents the harnesses, the measurement setup (clocks, iteration counts,
best-of-N, how builtin substitution is defeated), the environment, and the
published results for the arena/malloc heap, math, formatting and scanning.
`make bench` prints the live memory/string comparison against glibc (`> 1.00x`
means asmlib is faster); `make bench-arena`, `make bench-math`,
`make bench-format` and `make bench-scan` cover the rest, and `make perfbench`
drives `perf` attribution.

Results are hardware-dependent and noisy. On the development machine (Intel
Comet Lake, glibc 2.44) `memchr` is consistently faster and mid/large `memcpy`,
`memset` and `memcmp` are at parity, while glibc keeps an edge on `strlen` and
its two-way `strstr`; the arena beats glibc `malloc`/`free` by roughly 5-20x
(and ~45x for a bulk reset) and the malloc heap by 5-8x, and `asm_snprintf`,
`asm_u64toa` and `asm_sscanf` are 1.5-4x faster.

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
  wall time       : 209.4 ms  (1.0M steps/s)
  energy drift    : 6.319e-11
  tip x range     : [-1.9919, 2.0000]
  tip y range     : [-1.9996, 0.4828]
  max reach       : 2.0000 m (bound 2 m)
  f32 final speed : 5.5722 rad/s
OK: library ABI conserved energy and stayed physical
```

The driver checks the module is import-free, the RK4 integrator conserves
energy to ~1e-9 relative, the tip never leaves the 2 m arm reach, and the
single-precision path stays finite. The same source builds natively (host
libm) for cross-checking.

### Image-editing WebAssembly demo

`examples/image_edit.c` is a second wasm **library** module that edits RGBA8
images using the vector/matrix headers (`asm_vec3`/`asm_vec4`, `asm_mat3`) and
the asmlib math routines. It exports a small C ABI:

| Function | Operation |
|---|---|
| `ie_adjust(px, n, brightness, contrast, saturation)` | colour grading with `asm_vec3` |
| `ie_grayscale(px, n)` / `ie_invert(px, n)` | Rec.709 luma / channel inversion |
| `ie_convolve3(src, dst, w, h, kernel[9], bias)` | 3×3 kernel held in an `asm_mat3` |
| `ie_box_blur(src, dst, w, h)` / `ie_sharpen(...)` | ready-made kernels |
| `ie_warp(src, w, h, dst, ow, oh, m[9])` | affine warp, bilinear via `asm_vec4_lerp` |
| `ie_rotate(src, w, h, dst, angle)` | rotation about the centre |

Like the pendulum module it is freestanding (no imports) and supplies its own
math and `malloc`/`free`.

```sh
make wasm-image         # build build/image_edit.wasm
make wasm-image-example # node driver: checks every operation
make wasm-image-serve   # open http://localhost:8000/image_edit.html
```

`examples/web/image_edit.html` is a self-contained editor (canvas, sliders for
brightness/contrast/saturation/rotation, grayscale/invert/blur/sharpen/edge
buttons, PNG download, and image upload) that copies pixels through the module.
The `make wasm-image-example` driver checks grayscale makes R=G=B, double
invert is the identity, `adjust(1,1,1)` and the identity kernel/rotation are
no-ops, blur/sharpen leave a flat image flat, and blur smooths an edge.

## Freestanding and portability

The library has exactly one OS boundary: the syscall module (`src/sys.asm` on
x86-64, `src/aarch64/sys.S` on AArch64). Everything else is freestanding — no
OS, no libc.

| Layer | OS / libc | Notes |
|---|---|---|
| `asm_sys_mmap`/`munmap`/`alloc`/`free` | Linux syscalls | the only platform-specific code |
| `asm_arena_init_mmap` | Linux syscalls | lives in the sys module, so `arena.asm` stays OS-free |
| `asm_malloc` heap | Linux syscalls + TLS | needs a runtime that set up the thread pointer |
| memory / string / comparison / search / ctype | none | link under `-nostdlib` |
| arena (`asm_arena_init`, `asm_arena_init_grow`) | none | caller memory or caller `alloc`/`free` callbacks; pulls no syscalls |
| math (`src/math/`) | none | no `errno`, no FP environment, no global state |
| format / scan | none | |
| vector / matrix / quaternion | none | header-only on the math routines |

`ASMLIB_OS_HEAP` in `asmlib.h` is 1 on Linux and 0 elsewhere, so callers can
guard the OS-backed routines. On bare metal or another OS, use
`asm_arena_init`/`asm_arena_init_grow` and skip the heap, `asm_sys_*` and
`asm_arena_init_mmap`. `make test-freestanding` links `tests/test_freestanding.c`
with **`-nostdlib -static`** (its own `_start`, exit by raw syscall) and
exercises the arena, string/memory/ctype, math, formatters/scanner and linalg —
the resulting binary contains no `asm_sys_*`/`asm_malloc` symbol at all. The
test/benchmark harnesses use libc, but the library itself does not.

The math library (`src/math/`) is freestanding by construction: it calls no
libc or `libm`, sets no `errno`, uses no floating-point environment and keeps
no global state, so a `wasm32` build (or any freestanding target) links with
nothing.

`src/libc/` is a portable C implementation of the same memory, string,
allocator, formatting and scanning API (`memcpy`, `strlen`, `strlcpy`, `malloc`,
`asm_u64toa`, `snprintf`, …) for targets where the assembly backends do not
run. It is freestanding (no libc) and its allocator serves a first-fit free
list from `__heap_base`, growing WebAssembly linear memory with `memory.grow`
on demand (a fixed static pool is used in the native tests). The portable
allocator is also thread-safe (C11 atomics; a no-op lock on wasm builds without
threads). `make test-libc` differentially tests it against the host libc,
including a guard-page suite; `make wasm` links it together with the math
library into `build/asmlib.wasm`, a **complete freestanding libc-subset + libm**
module with no imports. The arena allocator is not available on wasm yet (only
the assembly backends implement it); the portable `malloc` is the wasm
allocator.

## AArch64 port

The API in `include/asmlib.h` is architecture-neutral, and the library now has
a hand-written **AArch64** implementation in `src/aarch64/` (GNU assembly, NEON)
covering the whole string/memory/search/ctype/arena/malloc/format/scan surface — the
same `asm_*` symbols as the x86-64 NASM build:

```
src/aarch64/  common_aarch64.inc  sys.S  memory.S  string.S  strcmp.S
              search.S  ctype.S  cpu.S  arena.S  alloc.S  format.S  scan.S
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
