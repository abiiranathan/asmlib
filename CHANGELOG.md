# Changelog

All notable changes to asmlib. The format follows
[Keep a Changelog](https://keepachangelog.com/), and the project adheres to
[Semantic Versioning](https://semver.org/) for the public API.

## [Unreleased]

### Added
- Full C99 `printf` family in the freestanding C engine (`src/libc/printf.c`),
  linked into every backend: `snprintf`/`vsnprintf`, `sprintf`/`vsprintf`,
  `asprintf`/`vasprintf`, and (native, via a raw `write` syscall) `dprintf`/
  `vdprintf`, `printf`/`vprintf`. Supports `%f`/`%e`/`%g`/`%a` (and upper-case
  forms) with **correctly rounded** output (round half to even, exact decimal
  expansion), the full flag set (`-+ #0`), `*` width/precision, and the `hh h l
  ll z j t L` length modifiers, plus `%n`. `asm_snprintf` is now fully
  C99-compliant instead of a bounded integer subset.
- `qsort`/`qsort_r` and `bsearch`/`bsearch_r` (`src/libc/sort.c`), an introsort
  with an insertion-sort cutoff and a heapsort fallback, available on all
  backends.
- `asm_sys_write` (raw `write(2)`) on x86-64 and AArch64.
- A differential `tests/test_sort.c` and an expanded `tests/test_format.c`
  (floating point, precision, `*`, `%n`, `dprintf`) run on x86-64, AArch64 and
  the portable backend.
- `tgamma` now evaluates its Lanczos series and exponential in double-double
  arithmetic (including the coefficients): positive arguments are within 1 ulp
  (previously up to 8 ulp); negative arguments via reflection are within a few
  ulp. Works freestanding on x86-64, AArch64 and wasm32 (FMA when available,
  Dekker splitting otherwise).

### Changed
- The hand-written `asm_snprintf` was removed from `src/format.asm` and
  `src/aarch64/format.S`; the assembly backends keep the fast bounded integer
  formatters and share the portable C printf engine for full compliance.

## [1.0.0] - 2026-09-28

First release. One C header (`asmlib.h`) and one library for x86-64, AArch64,
WebAssembly and freestanding targets.

### Added
- Hand-written x86-64 memory/string/comparison/search/ctype routines (NASM,
  AVX2/BMI2) and an AArch64 port (GNU assembly, NEON) behind the same `asm_*`
  API: `memcpy`/`memset`/`memmove`/`memcmp`/`memchr`/`memrchr`, the bounded
  string routines, `strcmp`/`strcasecmp`, `strchr`/`strstr`/`memmem`/`strspn`/
  `strcspn`/`strpbrk`, and the ctype predicates.
- A chunked arena allocator (fixed, growable with caller callbacks, and
  `mmap`-backed) and a segregated free-list `malloc` heap with a bounded
  thread-local cache (`asm_alloc_flush_tcache` for thread-exit flushing).
- A freestanding double- and single-precision math library (`src/math/`) and a
  portable C memory/string/allocator backend (`src/libc/`) for wasm32 and other
  freestanding targets; `make wasm` links the no-import module.
- Fast bounded integer formatters (`asm_u64toa`/`asm_i64toa`/`asm_u64tohex`) and
  a minimal `asm_snprintf`, plus a safe `asm_sscanf`.
- Header-only Vec2/3/4, Mat3/Mat4 and quaternion math (`asmlib_vec.h`,
  `asmlib_matrix.h`) on the library's math, with an independent-reference test.
- Automatic x86-64 dispatch: on hosted Linux the loader resolves each public
  symbol to AVX2 or a portable scalar fallback via ELF IFUNC (`STT_GNU_IFUNC`,
  `src/dispatch_ifunc.c`) with no per-call cost; other hosts use the lazy
  `src/dispatch.c` forwarder. `asm_cpu_require_avx2()` and a fully scalar
  `libasmlib_scalar.a` are also available.
- `ASMLIB_ALLOC_DEBUG` allocator hardening (double-free trap; portable poison,
  bad-pointer checks and live-object counts).
- Differential + guard-page + multithreaded test suites, an `-nostdlib`
  freestanding test, libFuzzer targets, benchmarks, CMake-free `make install`
  with DESTDIR/PREFIX and a `pkg-config` file.
- `SECURITY.md` and `CONTRIBUTING.md`, a Doxygen API reference (`make docs`,
  `Doxyfile`, documented public headers) and `docs/BENCHMARKS.md` (methodology
  and published results).
- A CMake build (`CMakeLists.txt`) alongside the Makefile: builds both the
  x86-64 and AArch64 backends (x86-64 cross-compilation via
  `cmake/toolchain-aarch64.cmake`) and installs a `find_package(asmlib)` package
  (`asmlib::asmlib`, `asmlib::asmlib_static`, `asmlib::asmlib_scalar`) and a
  relocatable `asmlib.pc`.
- MIT license; portions of `src/math/` are adapted from musl (see
  `src/math/NOTICE`).

[1.0.0]: https://github.com/abiiranathan/asmlib/releases/tag/v1.0.0
