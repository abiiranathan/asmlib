# Security Policy

asmlib is a systems library: every routine reads and writes raw memory, and the
arena/malloc allocators manage their own heap. A bug here is a memory-safety bug
in the program that links it, so reports are taken seriously.

## Supported versions

The latest released `1.x` line receives security fixes. The version is in
`include/asmlib_version.h` and returned by `asm_version()`.

| Version | Supported          |
| ------- | ------------------ |
| 1.0.x   | :white_check_mark: |
| < 1.0   | :x:                |

## Reporting a vulnerability

**Please do not open a public issue for a security problem.**

Use GitHub's private reporting:

1. Go to <https://github.com/abiiranathan/asmlib/security/advisories> and click
   **Report a vulnerability** (private security advisory). This keeps the
   discussion and any proof-of-concept private until a fix is ready.
2. If you cannot use advisories, open an issue that says only "I would like to
   report a security issue privately" **without details**, and a maintainer will
   follow up with a private channel.

Helpful reports include:

- the affected function(s) and version/commit,
- the target (x86-64, AArch64, or wasm32) and CPU features if relevant,
- a description of the bug and, if possible, a minimal reproducer or PoC,
- whether the issue is a read out of bounds, a write out of bounds, an
  information leak, undefined behaviour, or an allocator integrity problem.

## What we consider in scope

- Out-of-bounds reads or writes in any `asm_*` routine, including the
  speculative loads used by the AVX2/NEON scanners.
- Reads that cross a page boundary into unmapped memory (the library promises
  every speculative read is either in-bounds for the requested length or a
  naturally aligned vector load that cannot straddle a page).
- Integer overflow/truncation in size arithmetic (e.g. `asm_reallocarray`,
  `asm_snprintf` widths, arena alignment).
- Corruption of the arena or malloc heap metadata, double-free or use-after-free
  that the allocator fails to detect, cross-thread races in the thread-local
  cache path.
- Undefined behaviour reachable from documented inputs, including on the
  freestanding math library (NaN/infinity handling, rounding).
- Issues in the published artifacts (`make install`, `asmlib.pc`, the wasm
  module's exports).

## Out of scope

- Bugs that require a deliberately corrupted allocator state or a hostile local
  environment you already control.
- Denial of service from passing absurd sizes that the documented API rejects
  (the functions return `NULL`/`-1` rather than overrunning).
- Anything in `src/math/` inherited from musl that is also unresolved upstream
  (still welcome, but note the provenance in `src/math/NOTICE`).
- Misuse of the opt-in `ASMLIB_ENABLE_LIBC_ALIASES` that changes program
  semantics by design.

## How the code is tested

Defence in depth is built into the test suite; see `README.md` and
`CONTRIBUTING.md`:

- **Differential tests** (7M+ checks) against the host libc over exhaustive and
  randomised inputs and every alignment.
- **Guard-page tests** that place buffers against a `PROT_NONE` page to prove no
  speculative read crosses the boundary.
- **AddressSanitizer + UndefinedBehaviorSanitizer** and **valgrind memcheck**.
- **libFuzzer** targets for the converters, formatter, scanner and linalg.
- **`ASMLIB_ALLOC_DEBUG`**, which turns on poison-on-free, bad-pointer checks,
  live-object accounting and a double-free trap for the allocator.

## Disclosure

We aim to acknowledge a report within a few days and to ship a fix or mitigation
as soon as is practical, and will credit reporters in the release notes unless
they prefer to stay anonymous.
