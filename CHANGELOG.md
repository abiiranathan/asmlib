# Changelog

All notable changes to asmlib. The format follows
[Keep a Changelog](https://keepachangelog.com/), and the project adheres to
[Semantic Versioning](https://semver.org/) for the public API.

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
