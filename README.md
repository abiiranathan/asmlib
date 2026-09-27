# asmlib — a high-performance x86-64 assembly replacement for libc string/memory routines

`asmlib` is a hand-written NASM library for x86-64 (System V AMD64 ABI) that
replaces the hottest C library memory and string functions with AVX2/BMI2
implementations. It is small, self-contained (no dependencies beyond the
assembler and linker), thoroughly tested against libc, and packaged with a C
header plus static and shared libraries.

```
src/        NASM sources (one module per area)
include/    asmlib.h — the public C API
tests/      differential + page-boundary test suite
bench/      asmlib vs. libc micro-benchmark
examples/   a practical word-frequency analyser built on asmlib
```

## Highlights

* **39 routines** covering memory, string, comparison, searching and ctype.
* **AVX2 / BMI1 / BMI2** where they win: 32-byte vector scans, `tzcnt`/`bsr`
  bit-indexing, branchless ASCII case folding.
* **Page-safe**: every speculative read is either in-bounds for the requested
  length or a naturally aligned vector load that cannot straddle a page.
  A dedicated guard-page test proves this by placing buffers against a
  `PROT_NONE` page.
* **Differential tested**: **3,013,989** checks pass against the host libc over
  exhaustive and randomised inputs, including all alignments and edge sizes.
* **Two usage modes**: call the `asm_*` names, or define
  `ASMLIB_ENABLE_LIBC_ALIASES` to transparently replace the standard names.

## Requirements

* x86-64 CPU with **AVX2** and **BMI1** (`tzcnt`). The library does not fall
  back to scalar code, so query support first if you must run on older CPUs:

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
make bench      # run the benchmark
make example    # run the word-frequency example
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
| `void *asm_memset(void *dst, int c, size_t n)` | |
| `void *asm_bzero(void *dst, size_t n)` | |
| `int asm_memcmp(const void *a, const void *b, size_t n)` | unsigned bytes |
| `void *asm_memchr(const void *s, int c, size_t n)` | first match |
| `void *asm_memrchr(const void *s, int c, size_t n)` | last match |

### String (`string.asm`)
`asm_strlen`, `asm_strnlen`, `asm_strcpy`, `asm_stpcpy`, `asm_strncpy`,
`asm_strcat`, `asm_strncat`.

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
* **Comparison tricks.** `strcmp`/`strncmp` use SWAR zero-byte detection and
  `tzcnt` to find the first difference without a byte loop, guarding the
  wider load against page crossing. `memcmp` unrolls eight 32-byte vectors
  per iteration (all 16 YMM registers) and folds the equality masks with a
  `vpand` tree before a single `vpmovmskb`.
* **Searching.** `memmem`/`strstr` make a single pass over 32-byte aligned
  blocks, matching the first **two** needle bytes with two vector compares so
  only genuine two-byte candidates reach the full `memcmp`. A final scalar
  check covers the last byte of each block.
* **Accept sets.** `strspn`/`strcspn`/`strpbrk` build a 256-byte membership
  table on the stack, so scanning is a single linear pass.
* **Cache behaviour.** `memset` uses ERMS `rep stosb` for fills of 4 KiB or
  more, and `memcpy` uses non-temporal stores (with an `sfence`) for copies
  of 2 MiB or more when the destination is 32-byte aligned, avoiding
  read-for-ownership traffic.

### Performance approach

`strlen` reduces eight aligned vectors per iteration with a `vpminub` tree
(4 ALU ops per 128 bytes instead of 7), `memcmp` and `memcpy` unroll to 256
bytes, and small `memchr`/`memcmp` sizes use overlapping page-safe vector
windows rather than byte loops. Against glibc the results are now broadly
comparable: memory routines are at or near parity for medium and large sizes,
`memchr` is typically faster, and string scans are within roughly 1.5-2x of
glibc's highly tuned `strstr`.

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

Two helper targets exercise the same suite under dynamic analysis:

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

## Porting to AArch64

The API in `include/asmlib.h` is architecture-neutral. A future `src/aarch64/`
module can implement the same `asm_*` symbols with NEON/AdvSIMD (e.g. `ld1`,
`cmeq`, `umaxv`) and the `Makefile` can select the target with a variable,
leaving the tests, benchmark, example and header unchanged.

## License

Provided as-is for use and modification. No warranty.
