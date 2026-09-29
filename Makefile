#==============================================================================
# Makefile - build the asmlib x86-64 assembly library, tests, examples, bench
#==============================================================================

NASM      ?= nasm
CC        ?= gcc
AR        ?= ar
VALGRIND  ?= valgrind
DOXYGEN   ?= doxygen
SANFLAGS  ?= -fsanitize=address,undefined -fno-omit-frame-pointer

NASMFLAGS := -f elf64 -I src/ -g -F dwarf -Wall -w-reloc-rel-dword
CFLAGS    ?= -O2 -Wall -Wextra -Iinclude
LDFLAGS   ?=

BUILD     := build
# The memory/string/comparison/search surface has two x86-64 implementations:
# the hand-written AVX2 NASM modules (built under an asm_avx2_ symbol prefix)
# and the portable scalar C sources (asm_scalar_). src/dispatch_ifunc.c (hosted
# Linux) or src/dispatch.c (elsewhere) exports the public asm_* names and picks
# one, so one library runs anywhere.
HOT       := memory string strcmp search
SRC_ASM   := $(wildcard src/*.asm)
CORE_ASM  := $(filter-out $(addprefix src/,$(addsuffix .asm,$(HOT))),$(SRC_ASM))
OBJ       := $(patsubst src/%.asm,$(BUILD)/%.o,$(CORE_ASM))
AVX2_OBJ  := $(addprefix $(BUILD)/avx2/,$(addsuffix .o,$(HOT)))
SCALAR_HOT_OBJ := $(BUILD)/scalar_hot/mem.o $(BUILD)/scalar_hot/str.o
# Hosted Linux x86-64 resolves the hot routines with ELF IFUNC (no per-call
# cost); every other host uses the portable branch dispatcher.
HOST_IFUNC := $(if $(filter Linux,$(shell uname -s)),$(if $(filter x86_64 amd64,$(shell uname -m)),1,),0)
ifeq ($(HOST_IFUNC),1)
DISPATCH_OBJ   := $(BUILD)/dispatch_ifunc.o
else
DISPATCH_OBJ   := $(BUILD)/dispatch.o
endif
VERSION_OBJ    := $(BUILD)/version.o
LIB_OBJ   := $(OBJ) $(AVX2_OBJ) $(SCALAR_HOT_OBJ) $(DISPATCH_OBJ) $(VERSION_OBJ)
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
LIBC_TEST_BIN := $(BUILD)/test_portable $(BUILD)/test_portable_alloc $(BUILD)/test_portable_format $(BUILD)/test_portable_scan $(BUILD)/test_portable_alloc_debug

TEST_BIN      := $(BUILD)/test_asmlib
TEST_ARENA_BIN:= $(BUILD)/test_arena
TEST_ALLOC_BIN:= $(BUILD)/test_alloc
TEST_FORMAT_BIN := $(BUILD)/test_format
TEST_SCAN_BIN   := $(BUILD)/test_scan
TEST_LINALG_BIN := $(BUILD)/test_linalg
TEST_THREADS_BIN:= $(BUILD)/test_alloc_threads
TEST_ALLOC_DBG_BIN := $(BUILD)/test_alloc_debug
TEST_MT_BIN   := $(BUILD)/test_alloc_mt $(BUILD)/test_portable_alloc_mt
BENCH_BIN     := $(BUILD)/bench
BENCH_ARENA_BIN := $(BUILD)/bench_arena
MATH_BENCH_BIN  := $(BUILD)/math_bench
FORMAT_BENCH_BIN := $(BUILD)/format_bench
SCAN_BENCH_BIN  := $(BUILD)/scan_bench
PERF_BIN      := $(BUILD)/perfbench
EX_BIN        := $(BUILD)/example

.PHONY: all test test-valgrind test-asan test-math test-libc test-mt bench bench-arena bench-alloc bench-math bench-format bench-scan perfbench example clean wasm wasm-lib wasm-example wasm-serve wasm-image wasm-image-example wasm-image-serve test-aarch64 aarch64 fuzz scalar-lib test-scalar test-freestanding test-fallback install uninstall pkgconfig docs

all: $(STATIC) $(SHARED)

# ---- assemble every translation unit ----------------------------------------
$(BUILD)/%.o: src/%.asm $(INC) | $(BUILD)
	$(NASM) $(NASMFLAGS) -o $@ $<

$(BUILD):
	mkdir -p $(BUILD)

# ---- libraries --------------------------------------------------------------
# The freestanding math objects are part of the library too, so the vector and
# matrix headers (which call asm_sqrtf, asm_sinf, ...) link out of the box.
$(STATIC): $(LIB_OBJ) $(MATH_OBJ)
	$(AR) rcs $@ $^

$(SHARED): $(LIB_OBJ) $(MATH_OBJ)
	$(CC) -shared -Wl,-Bsymbolic -o $@ $^ $(LDFLAGS)

# AVX2 half: assemble, then prefix every symbol with asm_avx2_.
$(BUILD)/avx2/%.o: src/%.asm $(INC) | $(BUILD)
	@mkdir -p $(dir $@)
	$(NASM) $(NASMFLAGS) -o $@ $<
	objcopy --prefix-symbols=asm_avx2_ $@

# Scalar half: the portable C memory/string routines under asm_scalar_.
$(BUILD)/scalar_hot/%.o: src/libc/%.c src/libc/portable.h | $(BUILD)
	@mkdir -p $(dir $@)
	$(CC) $(LIBC_CFLAGS) -fPIC -DASMLIB_LIBC_SCALAR_PREFIX -c -o $@ $<

$(BUILD)/dispatch.o: src/dispatch.c $(HEADER) | $(BUILD)
	$(CC) $(CFLAGS) -fPIC -c -o $@ $<

$(BUILD)/dispatch_ifunc.o: src/dispatch_ifunc.c | $(BUILD)
	$(CC) $(CFLAGS) -fPIC -c -o $@ $<

$(BUILD)/version.o: src/version.c include/asmlib_version.h | $(BUILD)
	$(CC) $(CFLAGS) -fPIC -c -o $@ $<

# ---- scalar x86-64 fallback library -----------------------------------------
# The portable C backend compiled natively without SSE4.1/FMA and exported under
# the same asm_* names: a working (slower) fallback for x86-64 CPUs that lack
# AVX2, and the same code path the wasm build uses. It bundles the arena, ctype
# and cpu objects and is self-contained, so the -nostdlib freestanding test can
# link it without a C runtime (IFUNC relocations need one).
SCALAR_OBJ      := $(patsubst src/libc/%.c,$(BUILD)/scalar/%.o,$(LIBC_SRC))
SCALAR_MATH_OBJ := $(patsubst src/math/%.c,$(BUILD)/scalar/math/%.o,$(MATH_SRC))
SCALAR_LIB      := $(BUILD)/libasmlib_scalar.a

$(BUILD)/scalar/%.o: src/libc/%.c src/libc/portable.h | $(BUILD)
	@mkdir -p $(dir $@)
	$(CC) $(LIBC_CFLAGS) -c -o $@ $<

$(BUILD)/scalar/math/%.o: src/math/%.c include/asmlib_math.h src/math/math_private.h src/math/upstream.h | $(BUILD)
	@mkdir -p $(dir $@)
	$(CC) $(MATH_CFLAGS) -c -o $@ $<

$(SCALAR_LIB): $(SCALAR_OBJ) $(SCALAR_MATH_OBJ) $(BUILD)/arena.o $(BUILD)/ctype.o $(BUILD)/cpu.o
	$(AR) rcs $@ $^

scalar-lib: $(SCALAR_LIB)
	@echo "built $(SCALAR_LIB) (portable C, no AVX2 required)"

$(BUILD)/test_scalar: tests/test_portable.c $(SCALAR_LIB) $(HEADER)
	$(CC) $(LIBC_CFLAGS) -Iinclude -o $@ tests/test_portable.c $(SCALAR_LIB)

test-scalar: $(BUILD)/test_scalar
	./$(BUILD)/test_scalar

# Portable C scanner built as asm_ref_sscanf: a host-independent oracle for the
# scan differential tests (the host libc's ambiguous scanf cases changed in
# glibc 2.42, so the tests cannot rely on it unconditionally).
$(BUILD)/scan_ref.o: src/libc/scan.c src/libc/portable.h | $(BUILD)
	$(CC) $(LIBC_CFLAGS) -DASMLIB_LIBC_REF_NAMES -c -o $@ $<

# ---- tests ------------------------------------------------------------------
$(TEST_BIN): tests/test_asmlib.c $(STATIC) $(HEADER)
	$(CC) $(CFLAGS) -o $@ tests/test_asmlib.c $(STATIC) $(LDFLAGS)

$(TEST_ARENA_BIN): tests/test_arena.c $(STATIC) $(HEADER)
	$(CC) $(CFLAGS) -o $@ tests/test_arena.c $(STATIC) $(LDFLAGS)

$(TEST_ALLOC_BIN): tests/test_alloc.c $(STATIC) $(HEADER)
	$(CC) $(CFLAGS) -o $@ tests/test_alloc.c $(STATIC) $(LDFLAGS)

$(TEST_FORMAT_BIN): tests/test_format.c $(STATIC) $(HEADER)
	$(CC) $(CFLAGS) -o $@ tests/test_format.c $(STATIC) $(LDFLAGS)

$(TEST_SCAN_BIN): tests/test_scan.c $(STATIC) $(BUILD)/scan_ref.o $(HEADER)
	$(CC) $(CFLAGS) -o $@ tests/test_scan.c $(BUILD)/scan_ref.o $(STATIC) $(LDFLAGS)

$(TEST_LINALG_BIN): tests/test_linalg.c $(STATIC) $(HEADER)
	$(CC) $(CFLAGS) -o $@ tests/test_linalg.c $(STATIC) -lm $(LDFLAGS)

$(TEST_THREADS_BIN): tests/test_alloc_threads.c $(STATIC) $(HEADER)
	$(CC) $(CFLAGS) -pthread -o $@ tests/test_alloc_threads.c $(STATIC) $(LDFLAGS)

# A separate allocator object built with ASMLIB_ALLOC_DEBUG (double-free trap).
$(BUILD)/alloc_debug.o: src/alloc.asm $(INC) | $(BUILD)
	$(NASM) $(NASMFLAGS) -DASMLIB_ALLOC_DEBUG -o $@ $<

$(TEST_ALLOC_DBG_BIN): tests/test_alloc_debug.c $(BUILD)/alloc_debug.o $(STATIC) $(HEADER)
	$(CC) $(CFLAGS) -o $@ tests/test_alloc_debug.c $(BUILD)/alloc_debug.o $(STATIC) $(LDFLAGS)

# Freestanding smoke: -nostdlib, no OS, no libc (defines its own _start). It
# links the scalar archive, which has no IFUNC relocations and no syscalls.
$(BUILD)/test_freestanding: tests/test_freestanding.c $(SCALAR_LIB) $(HEADER)
	$(CC) -O2 -ffreestanding -fno-builtin -fno-stack-protector -nostdlib -static \
		-Iinclude -o $@ tests/test_freestanding.c $(SCALAR_LIB)

test-freestanding: $(BUILD)/test_freestanding
	./$(BUILD)/test_freestanding

# Prove the scalar fallback: the same differential suites under qemu with an
# x86-64 CPU that has no AVX2 (Nehalem), so the IFUNC resolvers pick the scalar
# path (and src/dispatch.c would, on other hosts).
QEMU_X86 ?= qemu-x86_64-static
test-fallback: $(TEST_BIN) $(TEST_ARENA_BIN) $(TEST_ALLOC_BIN)
	$(QEMU_X86) -cpu Nehalem ./$(TEST_BIN)
	$(QEMU_X86) -cpu Nehalem ./$(TEST_ARENA_BIN)
	$(QEMU_X86) -cpu Nehalem ./$(TEST_ALLOC_BIN)

# Multithreaded allocator stress tests (native asm heap and portable heap).
$(BUILD)/test_alloc_mt: tests/test_alloc_mt.c $(STATIC) $(HEADER)
	$(CC) $(CFLAGS) -pthread -o $@ tests/test_alloc_mt.c $(STATIC) $(LDFLAGS)

$(BUILD)/test_portable_alloc_mt: tests/test_portable_alloc_mt.c src/libc/alloc.c src/libc/portable.h | $(BUILD)
	$(CC) $(LIBC_CFLAGS) -pthread -o $@ tests/test_portable_alloc_mt.c src/libc/alloc.c

test: $(TEST_BIN) $(TEST_ARENA_BIN) $(TEST_ALLOC_BIN) $(TEST_FORMAT_BIN) $(TEST_SCAN_BIN) $(TEST_LINALG_BIN) $(TEST_THREADS_BIN) $(TEST_ALLOC_DBG_BIN) $(TEST_MT_BIN) $(BUILD)/test_freestanding
	./$(TEST_BIN)
	./$(TEST_ARENA_BIN)
	./$(TEST_ALLOC_BIN)
	./$(TEST_FORMAT_BIN)
	./$(TEST_SCAN_BIN)
	./$(TEST_LINALG_BIN)
	./$(TEST_THREADS_BIN)
	./$(TEST_ALLOC_DBG_BIN)
	./$(BUILD)/test_freestanding
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
test-asan: tests/test_asmlib.c tests/test_arena.c tests/test_alloc.c tests/test_format.c tests/test_scan.c tests/test_linalg.c $(STATIC) $(BUILD)/scan_ref.o $(HEADER)
	$(CC) $(CFLAGS) $(SANFLAGS) -o $(BUILD)/test_asan tests/test_asmlib.c $(STATIC)
	ASAN_OPTIONS=detect_leaks=1 ./$(BUILD)/test_asan
	$(CC) $(CFLAGS) $(SANFLAGS) -o $(BUILD)/test_arena_asan tests/test_arena.c $(STATIC)
	ASAN_OPTIONS=detect_leaks=1 ./$(BUILD)/test_arena_asan
	$(CC) $(CFLAGS) $(SANFLAGS) -o $(BUILD)/test_alloc_asan tests/test_alloc.c $(STATIC)
	ASAN_OPTIONS=detect_leaks=1 ./$(BUILD)/test_alloc_asan
	$(CC) $(CFLAGS) $(SANFLAGS) -o $(BUILD)/test_format_asan tests/test_format.c $(STATIC)
	ASAN_OPTIONS=detect_leaks=1 ./$(BUILD)/test_format_asan
	$(CC) $(CFLAGS) $(SANFLAGS) -o $(BUILD)/test_scan_asan tests/test_scan.c $(BUILD)/scan_ref.o $(STATIC)
	ASAN_OPTIONS=detect_leaks=1 ./$(BUILD)/test_scan_asan
	$(CC) $(CFLAGS) $(SANFLAGS) -o $(BUILD)/test_linalg_asan tests/test_linalg.c $(STATIC) -lm
	ASAN_OPTIONS=detect_leaks=1 ./$(BUILD)/test_linalg_asan

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
	$(CC) $(MATH_CFLAGS) -msse4.1 -mfma -fPIC -c -o $@ $<

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

$(BUILD)/test_portable_scan: tests/test_scan.c src/libc/scan.c src/libc/portable.h include/asmlib.h $(BUILD)/scan_ref.o | $(BUILD)
	$(CC) $(LIBC_CFLAGS) -Iinclude -o $@ tests/test_scan.c src/libc/scan.c $(BUILD)/scan_ref.o

$(BUILD)/test_portable_alloc_debug: tests/test_portable_alloc_debug.c src/libc/alloc.c src/libc/portable.h | $(BUILD)
	$(CC) $(LIBC_CFLAGS) -DASMLIB_ALLOC_DEBUG -o $@ tests/test_portable_alloc_debug.c src/libc/alloc.c

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

# Second real-world wasm demo: basic image editing built on the vector/matrix
# headers. Same freestanding runtime (math + portable libc), its own export set.
IE_LIB     := $(BUILD)/image_edit.wasm
WEB_IE     := $(WEB_DIR)/image_edit.wasm
IE_EXPORTS := ie_adjust ie_grayscale ie_invert ie_convolve3 ie_box_blur \
              ie_sharpen ie_warp ie_rotate malloc free

wasm-image:
	@rm -rf $(BUILD)/wasm
	@mkdir -p $(BUILD)/wasm
	@for f in $(MATH_SRC) $(LIBC_SRC); do \
		o=$(BUILD)/wasm/$$(basename $$f .c).o; \
		$(WASM_CC) $(MATH_CFLAGS) -Isrc/libc -DASMLIB_MATH_STD_NAMES -DASMLIB_LIBC_STD_NAMES -c -o $$o $$f || exit 1; \
	done
	$(WASM_CC) $(MATH_CFLAGS) -DASMLIB_MATH_STD_NAMES -DASMLIB_LIBC_STD_NAMES \
		-Iinclude -Isrc/libc -c -o $(BUILD)/wasm/image_edit.o examples/image_edit.c
	wasm-ld --no-entry --export-memory --initial-memory=16777216 --max-memory=268435456 \
		$(foreach s,$(IE_EXPORTS),--export=$(s)) \
		-o $(IE_LIB) $(BUILD)/wasm/*.o
	@echo "linked $(IE_LIB) (image-edit module, $(words $(IE_EXPORTS)) exports)"
	@mkdir -p $(WEB_DIR)
	cp $(IE_LIB) $(WEB_IE)
	@echo "copied to $(WEB_IE)"

wasm-image-example: wasm-image
	node examples/image_edit.js $(IE_LIB)

# Serve the image-editing UI (needs an HTTP origin for the wasm fetch).
wasm-image-serve: wasm-image
	@echo "open http://localhost:8000/image_edit.html  (Ctrl-C to stop)"
	@cd $(WEB_DIR) && python3 -m http.server 8000

# ---- AArch64 port (hand-written assembly) -----------------------------------
# Cross-compile the aarch64 sources and build + run the same differential test
# suite under qemu-aarch64-static. Requires aarch64-linux-gnu-gcc and qemu.
$(BUILD)/aarch64/%.o: src/aarch64/%.S src/aarch64/common_aarch64.inc | $(BUILD)
	@mkdir -p $(dir $@)
	$(A64_CC) -c -Isrc/aarch64 -o $@ $<

$(A64_STATIC): $(A64_OBJ)
	$(A64_AR) rcs $@ $^

# Freestanding math for the AArch64 linalg test (the vector/matrix headers call
# asm_sqrtf, asm_sinf, ...).
A64_MATH_OBJ := $(patsubst src/math/%.c,$(BUILD)/aarch64/math/%.o,$(MATH_SRC))
$(BUILD)/aarch64/math/%.o: src/math/%.c include/asmlib_math.h src/math/math_private.h src/math/upstream.h | $(BUILD)
	@mkdir -p $(dir $@)
	$(A64_CC) $(MATH_CFLAGS) -c -o $@ $<

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

$(BUILD)/aarch64/scan_ref.o: src/libc/scan.c src/libc/portable.h | $(BUILD)
	@mkdir -p $(dir $@)
	$(A64_CC) $(A64_CFLAGS) -Isrc/libc -DASMLIB_LIBC_REF_NAMES -c -o $@ $<

$(BUILD)/aarch64_test_scan: tests/test_scan.c $(A64_STATIC) $(BUILD)/aarch64/scan_ref.o $(HEADER) | $(BUILD)
	$(A64_CC) $(A64_CFLAGS) -o $@ tests/test_scan.c $(BUILD)/aarch64/scan_ref.o $(A64_STATIC)

$(BUILD)/aarch64_test_linalg: tests/test_linalg.c $(A64_STATIC) $(A64_MATH_OBJ) $(HEADER) | $(BUILD)
	$(A64_CC) $(A64_CFLAGS) -o $@ tests/test_linalg.c $(A64_STATIC) $(A64_MATH_OBJ) -lm

$(BUILD)/aarch64_test_threads: tests/test_alloc_threads.c $(A64_STATIC) $(HEADER) | $(BUILD)
	$(A64_CC) $(A64_CFLAGS) -pthread -o $@ tests/test_alloc_threads.c $(A64_STATIC)

$(BUILD)/aarch64_test_freestanding: tests/test_freestanding.c $(A64_STATIC) $(A64_MATH_OBJ) $(HEADER) | $(BUILD)
	$(A64_CC) -O2 -ffreestanding -fno-builtin -fno-stack-protector -nostdlib -static \
		-Iinclude -o $@ tests/test_freestanding.c $(A64_STATIC) $(A64_MATH_OBJ)

aarch64: $(A64_STATIC)
	@echo "built $(A64_STATIC)"

test-aarch64: aarch64 $(BUILD)/aarch64_test_asmlib $(BUILD)/aarch64_test_arena $(BUILD)/aarch64_test_alloc $(BUILD)/aarch64_test_format $(BUILD)/aarch64_test_scan $(BUILD)/aarch64_test_linalg $(BUILD)/aarch64_test_threads $(BUILD)/aarch64_test_freestanding
	$(A64_QEMU) $(BUILD)/aarch64_test_asmlib
	$(A64_QEMU) $(BUILD)/aarch64_test_arena
	$(A64_QEMU) $(BUILD)/aarch64_test_alloc
	$(A64_QEMU) $(BUILD)/aarch64_test_format
	$(A64_QEMU) $(BUILD)/aarch64_test_scan
	$(A64_QEMU) $(BUILD)/aarch64_test_linalg
	$(A64_QEMU) $(BUILD)/aarch64_test_threads
	$(A64_QEMU) $(BUILD)/aarch64_test_freestanding

# ---- fuzzing (libFuzzer; requires clang) ------------------------------------
FUZZ_CC    ?= clang
FUZZ_FLAGS ?= -O1 -g -fsanitize=fuzzer,address,undefined -fno-omit-frame-pointer -Iinclude
FUZZ_TIME  ?= 10
FUZZ_BINS  := $(BUILD)/fuzz_convert $(BUILD)/fuzz_format $(BUILD)/fuzz_scan $(BUILD)/fuzz_linalg

$(BUILD)/fuzz_%: fuzz/fuzz_%.c $(STATIC) $(HEADER) | $(BUILD)
	$(FUZZ_CC) $(FUZZ_FLAGS) -o $@ $< $(STATIC) -lm

# fuzz_scan also links the portable scanner as a host-independent reference.
$(BUILD)/fuzz_scan_ref.o: src/libc/scan.c src/libc/portable.h | $(BUILD)
	$(FUZZ_CC) -O1 -g -fsanitize=address,undefined -fno-omit-frame-pointer \
		-Isrc/libc -DASMLIB_LIBC_REF_NAMES -c -o $@ $<

$(BUILD)/fuzz_scan: fuzz/fuzz_scan.c $(STATIC) $(BUILD)/fuzz_scan_ref.o $(HEADER) | $(BUILD)
	$(FUZZ_CC) $(FUZZ_FLAGS) -o $@ fuzz/fuzz_scan.c $(BUILD)/fuzz_scan_ref.o $(STATIC) -lm

fuzz: $(FUZZ_BINS)
	@for b in $(FUZZ_BINS); do \
		echo "== $$b (max ${FUZZ_TIME}s) =="; \
		$$b -max_total_time=$(FUZZ_TIME) -rss_limit_mb=2048 -artifact_prefix=$(BUILD)/ || exit 1; \
	done

# ---- install / packaging ----------------------------------------------------
PREFIX     ?= /usr/local
LIBDIR     ?= $(PREFIX)/lib
INCLUDEDIR ?= $(PREFIX)/include
VERSION    := $(shell sed -n 's/^#define ASMLIB_VERSION_STRING "\(.*\)"/\1/p' include/asmlib_version.h)
PC         := $(BUILD)/asmlib.pc

$(PC): asmlib.pc.in include/asmlib_version.h | $(BUILD)
	sed -e 's|@PREFIX@|$(PREFIX)|g' -e 's|@LIBDIR@|$(LIBDIR)|g' \
	    -e 's|@INCLUDEDIR@|$(INCLUDEDIR)|g' -e 's|@VERSION@|$(VERSION)|g' $< > $@

pkgconfig: $(PC)
	@echo "wrote $(PC)"

# HTML API reference (Doxygen). Optional: not part of `all` or `test`.
DOCS_HTML := $(BUILD)/docs/html/index.html
docs:
	@command -v $(DOXYGEN) >/dev/null 2>&1 || { \
	    echo "$(DOXYGEN) not found - install doxygen to build the API docs"; \
	    echo "  Debian/Ubuntu: sudo apt-get install doxygen"; \
	    echo "  Arch:          sudo pacman -S doxygen"; exit 1; }
	@mkdir -p $(BUILD)/docs
	$(DOXYGEN) Doxyfile
	@echo "API docs -> $(DOCS_HTML)"

install: all scalar-lib $(PC)
	install -d $(DESTDIR)$(LIBDIR) $(DESTDIR)$(INCLUDEDIR) $(DESTDIR)$(LIBDIR)/pkgconfig
	install -m 644 $(STATIC) $(DESTDIR)$(LIBDIR)/
	install -m 755 $(SHARED) $(DESTDIR)$(LIBDIR)/
	install -m 644 $(SCALAR_LIB) $(DESTDIR)$(LIBDIR)/
	install -m 644 include/*.h $(DESTDIR)$(INCLUDEDIR)/
	install -m 644 $(PC) $(DESTDIR)$(LIBDIR)/pkgconfig/
	@echo "installed asmlib $(VERSION) under $(DESTDIR)$(PREFIX)"

uninstall:
	rm -f $(DESTDIR)$(LIBDIR)/libasmlib.a $(DESTDIR)$(LIBDIR)/libasmlib.so \
	      $(DESTDIR)$(LIBDIR)/libasmlib_scalar.a $(DESTDIR)$(LIBDIR)/pkgconfig/asmlib.pc
	rm -f $(DESTDIR)$(INCLUDEDIR)/asmlib.h $(DESTDIR)$(INCLUDEDIR)/asmlib_math.h \
	      $(DESTDIR)$(INCLUDEDIR)/asmlib_simd.h $(DESTDIR)$(INCLUDEDIR)/asmlib_vec.h \
	      $(DESTDIR)$(INCLUDEDIR)/asmlib_matrix.h $(DESTDIR)$(INCLUDEDIR)/asmlib_version.h
	@echo "uninstalled asmlib"

clean:
	rm -rf $(BUILD)