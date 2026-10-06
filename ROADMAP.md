# asmlib — roadmap to production

Turns the library from a strong foundation into something shippable. Ordered by
value/effort. Status: `[ ]` todo · `[~]` in progress · `[x]` done.

## Phase 1 — Assurance: fuzzing and independent validation
- [x] libFuzzer targets: number converters, `asm_snprintf`, `asm_sscanf`, the
      vector/matrix/quaternion math (`fuzz/fuzz_{convert,format,scan,linalg}.c`).
- [x] `make fuzz` target and a CI job that runs each target for a short budget
      (`FUZZ_TIME`, default 10 s). ~16M executions in 80 s clean on the dev
      machine; a first run caught a too-small harness buffer, not a library bug.
- [x] Independent linalg references (cofactor determinant/inverse, quaternion
      vs. Rodrigues) so the port is validated against something other than
      itself.

## Phase 2 — Allocator hardening
- [x] Debug build (`ASMLIB_ALLOC_DEBUG`): the native heap traps (`ud2`/`brk`)
      on a double free of a small block; the portable backend additionally
      poisons payloads (0xCD/0xDD), rejects misaligned/foreign pointers and
      reports live block/byte counts for leak checks. Native poison/padding and
      leak counters remain (portable has them; native has double-free only).
- [x] tcache thread-exit story: public `asm_alloc_flush_tcache()` returns the
      calling thread's cached blocks to the shared heap; documented and covered
      by `tests/test_alloc_threads.c` (32 short-lived threads flush on exit).
- [~] Lock contention: the tcache already keeps the hot path lock-free, so the
      global spinlock is only hit on refills/over-budget frees. Deferred:
      per-class locks are only worth it under heavy multi-class contention,
      which the benchmark does not yet reproduce; measure first.

## Phase 3 — Platform contract
- [x] Compile-time guard + docs: `ASMLIB_OS_HEAP` is 1 on Linux and 0
      elsewhere, and `README.md` has an OS-boundary table. The syscall layer and
      `asm_malloc` are declared Linux-only.
- [x] Freestanding arena/callback path first-class: `asm_arena_init_mmap` moved
      out of `arena.asm`/`arena.S` into the sys module, so an arena over caller
      memory links with no syscalls. `make test-freestanding` links
      `tests/test_freestanding.c` with `-nostdlib -static` (own `_start`, raw
      syscall exit) and the binary contains no `asm_sys_*`/`asm_malloc` symbol.
- [ ] (later) macOS/BSD syscall backends for the heap and `asm_arena_init_mmap`.

## Phase 4 — x86-64 feature dispatch
- [x] Automatic runtime dispatch: `src/dispatch.c` exports the public `asm_*`
      memory/string/comparison/search names and forwards to the AVX2 or scalar
      implementation based on a lazily cached `asm_cpu_has_avx2()`. One
      `libasmlib.a` runs on any x86-64 — no error, no flag, no second library.
      The AVX2 modules are built under an `asm_avx2_` symbol prefix and the
      portable C half under `asm_scalar_` (`objcopy --prefix-symbols`).
- [x] `asm_cpu_require_avx2()` remains for programs that prefer to fail fast
      (message + `exit(2)`) over the slower path.
- [x] `make test-fallback` runs the differential suites under QEMU with a
      no-AVX2 CPU (Nehalem), exercising the scalar path end to end (in CI).
- [x] `make scalar-lib` still builds a fully scalar `libasmlib_scalar.a` for
      freestanding/explicit use (it now bundles the arena, ctype and cpu
      objects, so the `-nostdlib` freestanding test links it).
- [x] ELF IFUNC dispatch on hosted Linux: `src/dispatch_ifunc.c` defines each
      public hot symbol as an `STT_GNU_IFUNC` whose resolver returns the AVX2 or
      scalar implementation, so the loader chooses once with **no per-call
      cost**. The plain `src/dispatch.c` remains for other hosts; the
      freestanding build links the scalar archive and needs no dispatch at all.

## Phase 5 — Packaging and release engineering
- [x] Version header (`include/asmlib_version.h`) with `ASMLIB_VERSION_STRING`
      /`ASMLIB_VERSION_NUMBER` and a runtime `asm_version()`.
- [x] `make install`/`uninstall` with `PREFIX`/`DESTDIR`/`LIBDIR`/`INCLUDEDIR`,
      and a generated `asmlib.pc` pkg-config file. CI installs into a staging
      dir and builds a program against it via `pkg-config`.
- [x] wasm module exports the full surface (libc subset + libm with standard
      names); the vector/matrix API is header-only and builds on it.
- [x] `CHANGELOG.md` (Keep a Changelog) and README install section.
- [x] A CMake build and package config (`CMakeLists.txt`,
      `cmake/asmlibConfig.cmake.in`): builds both backends (x86-64 and AArch64,
      selected from the target processor, with `cmake/toolchain-aarch64.cmake`
      for cross-compiling) and installs a relocatable `asmlib.pc` plus a
      `find_package(asmlib)` package exporting `asmlib::asmlib`,
      `asmlib::asmlib_static` and `asmlib::asmlib_scalar`.
- [ ] (later) A byte-for-byte reproducible-build check. The build embeds no
      timestamps, so artifacts are already deterministic.

## Phase 6 — Docs and governance
- [x] `SECURITY.md` (private reporting via GitHub advisories, scope, disclosure)
      and `CONTRIBUTING.md` (build/test matrix, house style, commit/PR process).
- [x] Doxygen API reference: `Doxyfile` + `make docs` (HTML in `build/docs/html`),
      the public headers carry `@file`/`@defgroup`/`@brief`/`@param`/`@return`
      comments, and the README is the generated front page.
- [x] `docs/BENCHMARKS.md`: methodology (clocks, iteration counts, best-of-N,
      builtin substitution, environment) and the published results.

## Phase 7 — I/O, algorithms and format parity
- [x] Full C99 printf family in the shared C engine (`src/libc/printf.c`),
      linked into every backend: `snprintf`/`vsnprintf`, `sprintf`/`vsprintf`,
      `asprintf`/`vasprintf` and (native) `dprintf`/`printf` over the raw
      `write(2)` syscall (`asm_sys_write`).
- [x] Correctly-rounded floating-point formatting (`%f`/`%e`/`%g`/`%a`, upper
      forms) using an exact big-integer decimal conversion, round half to even;
      plus the full flag set, `*` width/precision, `hh h l ll z j t L` length
      modifiers and `%n`. `asm_snprintf` is no longer a bounded integer subset.
- [x] `qsort`/`qsort_r` and `bsearch`/`bsearch_r` (`src/libc/sort.c`), an
      introsort available on all backends.
- [x] Differential float/`*`/`%n`/`dprintf` format tests and a new sort suite,
      run on x86-64, AArch64 and the portable backend.
- [ ] (later) Hand-written assembly versions of the printf engine / introsort
      for x86-64 and AArch64, to move them off the shared C path.
- [ ] (later) `%m` (strerror), locale-aware grouping, and exact `long double`
      formatting on targets where `long double` is binary128.

