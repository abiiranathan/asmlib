# Benchmark methodology and results

This page documents how asmlib is benchmarked, on what hardware, and how to
reproduce the numbers. It is the long form of the **Benchmark** section in the
[README](../README.md#benchmark).

Numbers here are for regression tracking and to make the design trade-offs
visible. They are not a claim that asmlib wins every case: several glibc
routines are excellent and asmlib is deliberately tuned for the cases it
targets.

## What is measured

| Target | Source | `make` alias | Compares against |
| ------ | ------ | ------------ | ---------------- |
| memory + strings | `bench/bench.c` | `make bench` | glibc `memcpy`/`memset`/`memcmp`/`strlen`/`memchr`/`strstr` |
| arena + malloc heap | `bench/arena_bench.c` | `make bench-arena` / `bench-alloc` | glibc `malloc`/`free` |
| math | `bench/math_bench.c` | `make bench-math` | host `libm` |
| formatting | `bench/format_bench.c` | `make bench-format` | glibc `snprintf` |
| scanning | `bench/scan_bench.c` | `make bench-scan` | glibc `sscanf` |
| single-op attribution | `bench/perfbench.c` | `make perfbench` | for `perf` profiling |

## Measurement methodology

- **Clock.** `clock_gettime(CLOCK_MONOTONIC)` around a loop of many iterations;
  each result is reported as **nanoseconds per call**. The memory/string
  harness uses `ITERS = 20000` per size; the arena/allocator/math/format/scan
  harnesses report the **best of N trials** (7–9) to suppress scheduler and
  thermal noise.
- **No builtin substitution.** libc and asmlib entry points are held in
  `volatile` function pointers, so the compiler cannot replace a `memcpy` call
  with an inline builtin or delete the loop. Every loop writes into a `volatile
  sink` to prevent dead-code elimination.
- **Best vs. average.** Best-of-N is used because the interesting signal is the
  code's peak throughput; averages on a shared, thermally-throttling laptop are
  dominated by other load. Re-run a few times if a number moves.
- **Speedup.** Each table shows `libc / asmlib`; **`> 1.00x` means asmlib is
  faster**. In the raw `make bench` output the columns are
  `libc_ns / asm_ns / ratio`.

## Environment

The published numbers were taken on the development machine:

- CPU: Intel Core i7-10510U (Comet Lake), 4 cores / 8 threads, AVX2 + BMI1 +
  BMI2 + ERMS + FMA.
- OS/kernel: Arch-based (Omarchy), Linux 7.2.
- libc: glibc 2.44. Compilers: GCC 16.2.1 and Clang 22.1.8.
- Correctness of the comparison relies on libc being large and well-tuned; on a
  different libc (musl) the ratios will differ.

## Reproducing

```sh
make bench          # memory + strings vs. glibc
make bench-arena    # arena and asm_malloc vs. glibc malloc/free
make bench-math     # math vs. libm
make bench-format   # asm_snprintf / asm_u64toa vs. snprintf
make bench-scan     # asm_sscanf vs. sscanf
```

Pin to an idle core and disable frequency scaling for the cleanest signal:

```sh
taskset -c 2 ./build/bench
```

## Results (development machine)

### Memory and strings

`make bench` prints the live table (the `libc/asm` ratio per size). On the
development machine the stable observations are:

- `memchr` is consistently at parity or faster, including for short inputs.
- mid/large `memcpy`, `memset` and `memcmp` (>= 4 KiB) are around parity, with
  `memcmp` typically ahead on large inputs and `memset` ahead once the ERMS/NT
  path engages.
- glibc keeps an edge on `strlen` and on its heavily optimised two-way
  `strstr`; asmlib's `strstr` wins by a wide margin only for large haystacks
  where the two-way skip amortises.

Absolute per-size numbers swing with turbo and thermal state on a laptop, so
this section is reported qualitatively; the harness exists to catch regressions
in CI-like local runs rather than to publish a fixed table.

### Arena and malloc heap

Best of 9 trials, ns per operation:

```
workload                              asm       malloc   speedup
arena   1000 x 64B                   4.36        37.46     8.59x
arena   4000 mixed 8..512B           4.35        86.13    19.80x
arena   1000 x 64B +memset           7.29        43.52     5.97x
malloc  1000 x 64B                   8.55        40.94     4.79x
malloc  4000 mixed 8..512B          11.53        93.10     8.08x
2048 x 1KiB fill+release (us)        22.28      1012.72    45.46x
```

The arena wins because allocation is a pointer bump, the memory is contiguous
(cache-predictable), and a reset is one rewind instead of thousands of `free`
calls. The malloc heap wins over glibc on burst workloads too: the
thread-local cache makes the steady-state path a couple of instructions, so the
global lock only appears on refills and over-budget frees.

### Math

Best of 7, ns/call, vs. host `libm` (glibc 2.44):

```
function         libm     asmlib   speedup
sqrt             1.75       1.72     1.02x
cbrt            17.20       7.89     2.18x
fmod             7.21       7.85     0.92x
exp              5.23       5.27     0.99x
exp2             4.28       4.33     0.99x
expm1            4.48       6.47     0.69x
log              4.76       5.49     0.87x
log2             5.14       5.93     0.87x
pow             15.70      16.71     0.94x
sin             14.45      17.87     0.81x
cos             14.09      18.21     0.77x
tan             17.87      18.13     0.99x
asin             8.34       9.39     0.89x
atan2           19.46      19.15     1.02x
cosh             9.94       7.49     1.33x
sinh            10.79      20.84     0.52x
tanh             5.04       7.40     0.68x
asinh           20.62      14.97     1.38x
```

`cbrt` is more than twice as fast and `cosh`/`asinh` are ~1.3–1.4x faster;
`sqrt`, `exp`, `exp2`, `tan` and `atan2` are near parity. Native builds use FMA
(implied by AVX2) for the kernels that support it; the wasm32 build stays
FMA-free and uses the portable fallbacks.

### Formatting

Best of 9, ns/call, vs. host `snprintf`:

```
workload                     libc     asmlib   speedup
snprintf "%d"               50.55      28.48     1.78x
snprintf "%lld"             74.69      41.45     1.80x
snprintf "%08x"             60.56      28.77     2.10x
snprintf "[%-16s]"          60.94      29.18     2.09x
snprintf mixed             159.32     104.35     1.53x
asm_u64toa (vs %llu)        80.79      20.32     3.98x
```

The decimal path emits two/four/eight-digit groups from a 200-byte table using
reciprocal multiplies (no hardware divide); hex and octal shift and mask.
`asm_u64toa` writes straight into the caller's buffer when it is provably large
enough, and the formatter appends through a single bounded sink.

### Scanning

Best of 9, ns/call, vs. host `sscanf`:

```
workload                     libc     asmlib   speedup
sscanf "%d"                130.93      44.78     2.92x
sscanf "%lld"              193.06      63.39     3.05x
sscanf "%x"                120.55      48.36     2.49x
sscanf "%15s"               65.96      30.23     2.18x
sscanf mixed               233.35     105.76     2.21x
```

libc's scanf machinery is heavier than printf's; the smaller, branch-driven
scanner is 2.2–3x faster on the integer/string cases it targets.

## Profiling with `perf`

`make perfbench` builds a harness that runs **one operation per invocation** so
`perf` attribution is unambiguous:

```sh
perf record -o /tmp/p.data ./build/perfbench strcmp 100000
perf report -i /tmp/p.data --no-children --sort=symbol --stdio
perf stat   -e task-clock,cycles,instructions ./build/perfbench memcpy 100000
```

This harness drove the latest tuning round: it showed `strcmp`'s 8-byte SWAR
loop at 0.69 cycles/byte, `memmem` spending 21% of its scan in the scalar
last-byte check, and `strchr` burning 44% of a short scan stepping to
alignment. Those findings led to the AVX2 `strcmp`, the ERMS/NT `memcpy`
geometry, and the align-down `strchr`.

## Caveats

- **Thermals and turbo.** Laptops throttle; a server or a pinned desktop will
  show different absolute numbers (and usually larger asmlib wins for
  `memcpy`/`memset` once ERMS is steady).
- **libc version matters.** These are glibc 2.44 comparisons. musl and older
  glibc differ substantially.
- **Best-of-N is optimistic by design.** It isolates the code path from
  scheduling noise; use `perf stat` for steady-state throughput.
