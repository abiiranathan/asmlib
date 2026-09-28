# Contributing to asmlib

Thanks for taking the time to help. This file covers how to build and test the
library, the house style, and how to get a change merged.

By contributing you agree that your work is licensed under the project's
[MIT license](LICENSE).

## Prerequisites

| Tool | Used for |
| ---- | -------- |
| `gcc` or `clang`, `make`, `ar`, `ld` | everything |
| `nasm` (2.14+, 3.02 tested) | the x86-64 assembly backend |
| `valgrind` | `make test-valgrind` (optional) |
| `clang` + `lld` | `make fuzz` (libFuzzer, optional) |
| `qemu-user-static` | `make test-fallback` (no-AVX2 path) |
| `aarch64-linux-gnu-gcc` + `qemu-user-static` | `make test-aarch64` |
| `doxygen` | `make docs` (API reference, optional) |

`sudo apt-get install build-essential nasm qemu-user-static` covers the common
cases on Debian/Ubuntu.

## Build and test

```sh
make                 # build/libasmlib.a + build/libasmlib.so
make test            # the full differential suite (must stay green)
```

Before opening a pull request, run the widest set your machine supports:

```sh
make test                     # native differential, guard-page, fuzz-seed, threads
make test-asan                # ASan + UBSan
make test-fallback            # scalar path under qemu (no AVX2)
make test-scalar              # portable scalar library
make test-freestanding        # -nostdlib, no OS
make test-aarch64             # cross-build + qemu
make test-math test-libc      # math and portable libc suites
make test-valgrind            # memcheck (slow)
make bench                    # sanity-check that fast paths are still fast
```

If you change a hot routine, include a benchmark before/after in the PR and
note the CPU. See [BENCHMARKS.md](docs/BENCHMARKS.md) for the methodology.

Guidelines for new or changed routines:

- **Correctness first.** Every size, every alignment, and the empty input must
  be covered. The differential tests compare against the host libc; add cases
  there rather than inventing a new harness.
- **Stay page-safe.** A speculative vector load may only read bytes that are
  in-bounds for the requested length, or a naturally aligned vector load that
  cannot straddle a page. The guard-page test enforces this.
- **No UB.** No unaligned typed accesses, no signed overflow, no strict-aliasing
  violations. `make test-asan` includes UBSan.
- **Bounded and predictable.** Prefer returning `NULL`/`-1` to overrunning, and
  document the contract in the header.

## Layout

| Path | Contents |
| ---- | -------- |
| `include/` | the public headers (`asmlib.h` is the umbrella) |
| `src/*.asm` | the x86-64 NASM backend (AVX2/BMI2) |
| `src/aarch64/` | the AArch64 GNU-as backend (NEON) |
| `src/libc/` | the portable C backend (wasm / freestanding) and scalar fallback |
| `src/math/` | the freestanding math library (portions adapted from musl) |
| `src/dispatch*.c` | runtime CPU dispatch (ELF IFUNC on hosted Linux) |
| `tests/` | differential, guard-page, allocator, freestanding tests |
| `fuzz/` | libFuzzer entry points |
| `bench/`, `examples/` | benchmarks and example programs |

## House style

- **Headers**: document every public function; one blank line between
  declarations; keep the existing section banners. Public names are `asm_*`.
- **C**: C99, 4-space indent, `/* ... */` comments, no tabs. Match the file you
  are editing; do not reformat untouched code.
- **Assembly**: NASM for x86-64 (Intel syntax) and GNU `as` for AArch64; keep
  the existing macro/style conventions and register-usage comments. Preserve
  callee-saved registers and the documented ABI.
- **No new dependencies** in the library itself: it must stay linkable with
  `-nostdlib`. Test-only tooling is fine.
- Keep the public API additive where possible; a breaking change bumps the major
  version and goes in `CHANGELOG.md`.

## Commits and pull requests

- Keep commits focused and the message in the imperative mood, for example
  `Add a safe asm_sscanf and speed up asm_u64toa`.
- Run `make test` (and the wider set above) before pushing. CI runs the same
  targets with both `gcc` and `clang`.
- In the PR describe **what** changed, **why**, and any benchmark numbers.
- Link the issue the change addresses, if there is one.

## Reporting bugs and security issues

- Ordinary bugs: open a GitHub issue with the version (`asm_version()`), target,
  and a minimal reproducer.
- Security issues: **do not** open a public issue; follow
  [SECURITY.md](SECURITY.md).

## Good first contributions

- More differential cases: exotic alignments, `SIZE_MAX`-adjacent lengths,
  embedded NULs in `%c` scans.
- Extend the wasm/JS examples.
- Documentation fixes and clarifications.
