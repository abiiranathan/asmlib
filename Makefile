#==============================================================================
# Makefile - build the asmlib x86-64 assembly library, tests, examples, bench
#==============================================================================

NASM      ?= nasm
CC        ?= gcc
AR        ?= ar
VALGRIND  ?= valgrind
SANFLAGS  ?= -fsanitize=address,undefined -fno-omit-frame-pointer

NASMFLAGS := -f elf64 -I src/ -g -F dwarf -Wall -w-reloc-rel-dword
CFLAGS    ?= -O2 -Wall -Wextra -Iinclude
LDFLAGS   ?=

BUILD     := build
SRC_ASM   := $(wildcard src/*.asm)
OBJ       := $(patsubst src/%.asm,$(BUILD)/%.o,$(SRC_ASM))
HEADER    := include/asmlib.h
INC       := src/common.inc

# ---- AArch64 port (hand-written assembly, cross-compiled and run under qemu) -
#   make ARCH=aarch64 test        cross-build the aarch64 lib and run the
#                                 differential suite under qemu-aarch64-static
A64_CC    ?= aarch64-linux-gnu-gcc
A64_AR    ?= aarch64-linux-gnu-ar
A64_QEMU  ?= qemu-aarch64-static
A64_SRC   := $(wildcard src/aarch64/*.S)
A64_OBJ   := $(patsubst src/aarch64/%.S,$(BUILD)/aarch64/%.o,$(A64_SRC))
A64_STATIC:= $(BUILD)/aarch64/libasmlib.a
A64_CFLAGS?= -O2 -Wall -Wextra -Iinclude -Isrc/aarch64 -static

STATIC    := $(BUILD)/libasmlib.a
SHARED    := $(BUILD)/libasmlib.so

# ---- freestanding math library (C, no libc/libm) ----------------------------
MATH_SRC    := $(wildcard src/math/*.c)
MATH_OBJ    := $(patsubst src/math/%.c,$(BUILD)/math/%.o,$(MATH_SRC))
MATH_CFLAGS := -O2 -std=c11 -ffreestanding -fno-builtin -ffp-contract=off -fno-stack-protector \
               -fno-math-errno -Wall -Wextra -Iinclude -Isrc/math
MATH_TEST_SRC := $(wildcard tests/test_math_*.c)
MATH_TEST_BIN := $(patsubst tests/%.c,$(BUILD)/%,$(MATH_TEST_SRC))
WASM_CC     ?= clang --target=wasm32-unknown-unknown

# ---- portable C backend for wasm/freestanding (memory, string, allocator) ---
LIBC_SRC      := $(wildcard src/libc/*.c)
LIBC_CFLAGS   := -O2 -std=c11 -ffreestanding -fno-builtin -fno-stack-protector \
                 -Wall -Wextra -Isrc/libc
LIBC_TEST_BIN := $(BUILD)/test_portable $(BUILD)/test_portable_alloc $(BUILD)/test_portable_format $(BUILD)/test_portable_scan

TEST_BIN      := $(BUILD)/test_asmlib
TEST_ARENA_BIN:= $(BUILD)/test_arena
TEST_ALLOC_BIN:= $(BUILD)/test_alloc
TEST_FORMAT_BIN := $(BUILD)/test_format
TEST_SCAN_BIN   := $(BUILD)/test_scan
TEST_MT_BIN   := $(BUILD)/test_alloc_mt $(BUILD)/test_portable_alloc_mt
BENCH_BIN     := $(BUILD)/bench
BENCH_ARENA_BIN := $(BUILD)/bench_arena
MATH_BENCH_BIN  := $(BUILD)/math_bench
FORMAT_BENCH_BIN := $(BUILD)/format_bench
SCAN_BENCH_BIN  := $(BUILD)/scan_bench
PERF_BIN      := $(BUILD)/perfbench
EX_BIN        := $(BUILD)/example

.PHONY: all test test-valgrind test-asan test-math test-libc test-mt bench bench-arena bench-alloc bench-math bench-format bench-scan perfbench example clean wasm wasm-lib wasm-example wasm-serve test-aarch64 aarch64

all: $(STATIC) $(SHARED)

# ---- assemble every translation unit ----------------------------------------
$(BUILD)/%.o: src/%.asm $(INC) | $(BUILD)
	$(NASM) $(NASMFLAGS) -o $@ $<

$(BUILD):
	mkdir -p $(BUILD)

# ---- libraries --------------------------------------------------------------
$(STATIC): $(OBJ)
	$(AR) rcs $@ $^

$(SHARED): $(OBJ)
	$(CC) -shared -Wl,-Bsymbolic -o $@ $^ $(LDFLAGS)

# ---- tests ------------------------------------------------------------------
$(TEST_BIN): tests/test_asmlib.c $(STATIC) $(HEADER)
	$(CC) $(CFLAGS) -o $@ tests/test_asmlib.c $(STATIC) $(LDFLAGS)

$(TEST_ARENA_BIN): tests/test_arena.c $(STATIC) $(HEADER)
	$(CC) $(CFLAGS) -o $@ tests/test_arena.c $(STATIC) $(LDFLAGS)

$(TEST_ALLOC_BIN): tests/test_alloc.c $(STATIC) $(HEADER)
	$(CC) $(CFLAGS) -o $@ tests/test_alloc.c $(STATIC) $(LDFLAGS)

$(TEST_FORMAT_BIN): tests/test_format.c $(STATIC) $(HEADER)
	$(CC) $(CFLAGS) -o $@ tests/test_format.c $(STATIC) $(LDFLAGS)

$(TEST_SCAN_BIN): tests/test_scan.c $(STATIC) $(HEADER)
	$(CC) $(CFLAGS) -o $@ tests/test_scan.c $(STATIC) $(LDFLAGS)

# Multithreaded allocator stress tests (native asm heap and portable heap).
$(BUILD)/test_alloc_mt: tests/test_alloc_mt.c $(STATIC) $(HEADER)
	$(CC) $(CFLAGS) -pthread -o $@ tests/test_alloc_mt.c $(STATIC) $(LDFLAGS)

$(BUILD)/test_portable_alloc_mt: tests/test_portable_alloc_mt.c src/libc/alloc.c src/libc/portable.h | $(BUILD)
	$(CC) $(LIBC_CFLAGS) -pthread -o $@ tests/test_portable_alloc_mt.c src/libc/alloc.c

test: $(TEST_BIN) $(TEST_ARENA_BIN) $(TEST_ALLOC_BIN) $(TEST_FORMAT_BIN) $(TEST_SCAN_BIN) $(TEST_MT_BIN)
	./$(TEST_BIN)
	./$(TEST_ARENA_BIN)
	./$(TEST_ALLOC_BIN)
	./$(TEST_FORMAT_BIN)
	./$(TEST_SCAN_BIN)
	./$(BUILD)/test_alloc_mt
	./$(BUILD)/test_portable_alloc_mt

test-mt: $(TEST_MT_BIN)
	./$(BUILD)/test_alloc_mt
	./$(BUILD)/test_portable_alloc_mt

# Run the suites under valgrind; fails on any invalid read/write or leak.
# --undef-value-errors=no silences valgrind's inability to model AVX2 register
# definedness (it also flags glibc's own SIMD string routines for this).
test-valgrind: $(TEST_BIN) $(TEST_ARENA_BIN) $(TEST_ALLOC_BIN)
	$(VALGRIND) --tool=memcheck --error-exitcode=99 --leak-check=full \
		--errors-for-leak-kinds=definite --undef-value-errors=no ./$(TEST_BIN)
	$(VALGRIND) --tool=memcheck --error-exitcode=99 --leak-check=full \
		--errors-for-leak-kinds=definite --undef-value-errors=no ./$(TEST_ARENA_BIN)
	$(VALGRIND) --tool=memcheck --error-exitcode=99 --leak-check=full \
		--errors-for-leak-kinds=definite --undef-value-errors=no ./$(TEST_ALLOC_BIN)

# Run the suites under AddressSanitizer + UndefinedBehaviorSanitizer.
test-asan: tests/test_asmlib.c tests/test_arena.c tests/test_alloc.c tests/test_format.c tests/test_scan.c $(STATIC) $(HEADER)
	$(CC) $(CFLAGS) $(SANFLAGS) -o $(BUILD)/test_asan tests/test_asmlib.c $(STATIC)
	ASAN_OPTIONS=detect_leaks=1 ./$(BUILD)/test_asan
	$(CC) $(CFLAGS) $(SANFLAGS) -o $(BUILD)/test_arena_asan tests/test_arena.c $(STATIC)
	ASAN_OPTIONS=detect_leaks=1 ./$(BUILD)/test_arena_asan
	$(CC) $(CFLAGS) $(SANFLAGS) -o $(BUILD)/test_alloc_asan tests/test_alloc.c $(STATIC)
	ASAN_OPTIONS=detect_leaks=1 ./$(BUILD)/test_alloc_asan
	$(CC) $(CFLAGS) $(SANFLAGS) -o $(BUILD)/test_format_asan tests/test_format.c $(STATIC)
	ASAN_OPTIONS=detect_leaks=1 ./$(BUILD)/test_format_asan
	$(CC) $(CFLAGS) $(SANFLAGS) -o $(BUILD)/test_scan_asan tests/test_scan.c $(STATIC)
	ASAN_OPTIONS=detect_leaks=1 ./$(BUILD)/test_scan_asan

# ---- benchmark --------------------------------------------------------------
$(BENCH_BIN): bench/bench.c $(STATIC) $(HEADER)
	$(CC) $(CFLAGS) -o $@ bench/bench.c $(STATIC) $(LDFLAGS)

$(BENCH_ARENA_BIN): bench/arena_bench.c $(STATIC) $(HEADER)
	$(CC) $(CFLAGS) -o $@ bench/arena_bench.c $(STATIC) $(LDFLAGS)

bench: $(BENCH_BIN)
	./$(BENCH_BIN)

bench-arena: $(BENCH_ARENA_BIN)
	./$(BENCH_ARENA_BIN)

bench-alloc: $(BENCH_ARENA_BIN)
	./$(BENCH_ARENA_BIN)

# Math benchmark: asm math vs. the host libm. Compiled with -fno-builtin so the
# libm side is a real call and cannot be folded to builtins.
$(MATH_BENCH_BIN): bench/math_bench.c $(MATH_OBJ) include/asmlib_math.h | $(BUILD)
	$(CC) -O2 -Wall -Wextra -Iinclude -Isrc/math -fno-builtin -o $@ bench/math_bench.c $(MATH_OBJ) -lm

bench-math: $(MATH_BENCH_BIN)
	./$(MATH_BENCH_BIN)

$(FORMAT_BENCH_BIN): bench/format_bench.c $(STATIC) $(HEADER)
	$(CC) $(CFLAGS) -o $@ bench/format_bench.c $(STATIC) $(LDFLAGS)

bench-format: $(FORMAT_BENCH_BIN)
	./$(FORMAT_BENCH_BIN)

$(SCAN_BENCH_BIN): bench/scan_bench.c $(STATIC) $(HEADER)
	$(CC) $(CFLAGS) -o $@ bench/scan_bench.c $(STATIC) $(LDFLAGS)

bench-scan: $(SCAN_BENCH_BIN)
	./$(SCAN_BENCH_BIN)

# One-phase-per-invocation harness for profiling with `perf`:
#   perf record -o /tmp/p.data ./build/perfbench <phase> [reps]
# Phases: memcpy memcpy1k memset memset1k memcmp strlen strchr memchr
#         memchr_scan strchr_scan strcmp memmem arena_alloc malloc_free
$(PERF_BIN): bench/perfbench.c $(STATIC) $(HEADER)
	$(CC) $(CFLAGS) -o $@ bench/perfbench.c $(STATIC) $(LDFLAGS)

perfbench: $(PERF_BIN)
	@echo "usage: perf record ./build/perfbench <phase> [reps]"

# ---- practical example ------------------------------------------------------
$(EX_BIN): examples/example.c $(STATIC) $(HEADER)
	$(CC) $(CFLAGS) -o $@ examples/example.c $(STATIC) $(LDFLAGS)

example: $(EX_BIN)
	./$(EX_BIN)

# ---- freestanding math library ----------------------------------------------
# The asm library requires AVX2, which in practice always implies FMA; enabling
# it lets the musl-derived kernels use FMA (guarded by __FP_FAST_FMA) and keeps
# them freestanding. -ffp-contract=off is kept so the exact double-double and
# error-free transforms elsewhere in the library are not contracted.
$(BUILD)/math/%.o: src/math/%.c include/asmlib_math.h src/math/math_private.h src/math/upstream.h | $(BUILD)
	@mkdir -p $(dir $@)
	$(CC) $(MATH_CFLAGS) -msse4.1 -mfma -c -o $@ $<

$(BUILD)/test_math_%: tests/test_math_%.c tests/math_test.h $(MATH_OBJ) include/asmlib_math.h | $(BUILD)
	$(CC) $(MATH_CFLAGS) -o $@ $< $(MATH_OBJ) -lm

test-math: $(MATH_TEST_BIN)
	@for t in $(MATH_TEST_BIN); do ./$$t || exit 1; done

# ---- portable C backend (memory, string, allocator) for wasm ----------------
$(BUILD)/test_portable: tests/test_portable.c src/libc/mem.c src/libc/str.c src/libc/portable.h | $(BUILD)
	$(CC) $(LIBC_CFLAGS) -o $@ tests/test_portable.c src/libc/mem.c src/libc/str.c

$(BUILD)/test_portable_alloc: tests/test_portable_alloc.c src/libc/alloc.c src/libc/portable.h | $(BUILD)
	$(CC) $(LIBC_CFLAGS) -o $@ tests/test_portable_alloc.c src/libc/alloc.c

$(BUILD)/test_portable_format: tests/test_format.c src/libc/format.c src/libc/portable.h include/asmlib.h | $(BUILD)
	$(CC) $(LIBC_CFLAGS) -Iinclude -o $@ tests/test_format.c src/libc/format.c

$(BUILD)/test_portable_scan: tests/test_scan.c src/libc/scan.c src/libc/portable.h include/asmlib.h | $(BUILD)
	$(CC) $(LIBC_CFLAGS) -Iinclude -o $@ tests/test_scan.c src/libc/scan.c

test-libc: $(LIBC_TEST_BIN)
	@for t in $(LIBC_TEST_BIN); do ./$$t || exit 1; done

# Compile every math and portable-libc source for wasm32 (freestanding). The
# objects are always built; the module is linked when wasm-ld is available.
# ASMLIB_MATH_STD_NAMES/ASMLIB_LIBC_STD_NAMES make the module export standard
# <math.h>/libc symbols, so it is a drop-in freestanding libc + libm.
wasm:
	@rm -rf $(BUILD)/wasm
	@mkdir -p $(BUILD)/wasm
	@for f in $(MATH_SRC) $(LIBC_SRC); do \
		o=$(BUILD)/wasm/$$(basename $$f .c).o; \
		$(WASM_CC) $(MATH_CFLAGS) -Isrc/libc -DASMLIB_MATH_STD_NAMES -DASMLIB_LIBC_STD_NAMES -c -o $$o $$f || exit 1; \
	done
	@echo "wasm objects built in $(BUILD)/wasm"
	@if command -v wasm-ld >/dev/null 2>&1; then \
		wasm-ld --no-entry --export-all -o $(BUILD)/asmlib.wasm $(BUILD)/wasm/*.o && \
		echo "linked $(BUILD)/asmlib.wasm"; \
	else \
		echo "wasm-ld not installed: objects compiled, module not linked"; \
	fi

# Real-world wasm demo: a double pendulum integrated with asmlib as the
# freestanding math + libc. `make wasm-lib` links it as a *library* module with
# a small explicit C ABI (no --export-all) ready to be loaded from a web page.
WASM_EX_OBJ := $(BUILD)/wasm/double_pendulum.o
WASM_LIB    := $(BUILD)/double_pendulum.wasm
WEB_DIR     := examples/web
WEB_WASM    := $(WEB_DIR)/double_pendulum.wasm

# Symbols the web UI needs: the pendulum API plus malloc/free so JS can read
# the trajectory buffer. Everything else stays private to the module.
WASM_EXPORTS := dp_init dp_step dp_state dp_tip_x dp_tip_y dp_energy_drift \
                dp_buffer dp_run double_pendulum_run_f malloc free

wasm-lib:
	@rm -rf $(BUILD)/wasm
	@mkdir -p $(BUILD)/wasm
	@for f in $(MATH_SRC) $(LIBC_SRC); do \
		o=$(BUILD)/wasm/$$(basename $$f .c).o; \
		$(WASM_CC) $(MATH_CFLAGS) -Isrc/libc -DASMLIB_MATH_STD_NAMES -DASMLIB_LIBC_STD_NAMES -c -o $$o $$f || exit 1; \
	done
	$(WASM_CC) $(MATH_CFLAGS) -DASMLIB_MATH_STD_NAMES -DASMLIB_LIBC_STD_NAMES -Iinclude -Isrc/libc -c -o $(WASM_EX_OBJ) examples/double_pendulum.c
	wasm-ld --no-entry --export-memory --initial-memory=1048576 --max-memory=67108864 \
		$(foreach s,$(WASM_EXPORTS),--export=$(s)) \
		-o $(WASM_LIB) $(BUILD)/wasm/*.o
	@echo "linked $(WASM_LIB) (library module, $(words $(WASM_EXPORTS)) exports)"
	@mkdir -p $(WEB_DIR)
	cp $(WASM_LIB) $(WEB_WASM)
	@echo "copied to $(WEB_WASM)"

# Serve the web UI over HTTP (browsers block wasm fetch from file://).
wasm-serve: wasm-lib
	@echo "open http://localhost:8000/  (Ctrl-C to stop)"
	@cd $(WEB_DIR) && python3 -m http.server 8000

# Non-interactive check of the library module's C ABI, from Node.
wasm-example: wasm-lib
	node examples/double_pendulum.js $(WASM_LIB)

# ---- AArch64 port (hand-written assembly) -----------------------------------
# Cross-compile the aarch64 sources and build + run the same differential test
# suite under qemu-aarch64-static. Requires aarch64-linux-gnu-gcc and qemu.
$(BUILD)/aarch64/%.o: src/aarch64/%.S src/aarch64/common_aarch64.inc | $(BUILD)
	@mkdir -p $(dir $@)
	$(A64_CC) -c -Isrc/aarch64 -o $@ $<

$(A64_STATIC): $(A64_OBJ)
	$(A64_AR) rcs $@ $^

# The differential harnesses reuse tests/asmlib.h API; build with the aarch64
# library and run under qemu.
$(BUILD)/aarch64_test_asmlib: tests/test_asmlib.c $(A64_STATIC) $(HEADER) | $(BUILD)
	$(A64_CC) $(A64_CFLAGS) -o $@ tests/test_asmlib.c $(A64_STATIC)

$(BUILD)/aarch64_test_arena: tests/test_arena.c $(A64_STATIC) $(HEADER) | $(BUILD)
	$(A64_CC) $(A64_CFLAGS) -o $@ tests/test_arena.c $(A64_STATIC)

$(BUILD)/aarch64_test_alloc: tests/test_alloc.c $(A64_STATIC) $(HEADER) | $(BUILD)
	$(A64_CC) $(A64_CFLAGS) -o $@ tests/test_alloc.c $(A64_STATIC)

$(BUILD)/aarch64_test_format: tests/test_format.c $(A64_STATIC) $(HEADER) | $(BUILD)
	$(A64_CC) $(A64_CFLAGS) -o $@ tests/test_format.c $(A64_STATIC)

$(BUILD)/aarch64_test_scan: tests/test_scan.c $(A64_STATIC) $(HEADER) | $(BUILD)
	$(A64_CC) $(A64_CFLAGS) -o $@ tests/test_scan.c $(A64_STATIC)

aarch64: $(A64_STATIC)
	@echo "built $(A64_STATIC)"

test-aarch64: aarch64 $(BUILD)/aarch64_test_asmlib $(BUILD)/aarch64_test_arena $(BUILD)/aarch64_test_alloc $(BUILD)/aarch64_test_format $(BUILD)/aarch64_test_scan
	$(A64_QEMU) $(BUILD)/aarch64_test_asmlib
	$(A64_QEMU) $(BUILD)/aarch64_test_arena
	$(A64_QEMU) $(BUILD)/aarch64_test_alloc
	$(A64_QEMU) $(BUILD)/aarch64_test_format
	$(A64_QEMU) $(BUILD)/aarch64_test_scan

clean:
	rm -rf $(BUILD)