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

STATIC    := $(BUILD)/libasmlib.a
SHARED    := $(BUILD)/libasmlib.so

TEST_BIN      := $(BUILD)/test_asmlib
TEST_ARENA_BIN:= $(BUILD)/test_arena
TEST_ALLOC_BIN:= $(BUILD)/test_alloc
BENCH_BIN     := $(BUILD)/bench
BENCH_ARENA_BIN := $(BUILD)/bench_arena
EX_BIN        := $(BUILD)/example

.PHONY: all test test-valgrind test-asan bench bench-arena bench-alloc example clean

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

test: $(TEST_BIN) $(TEST_ARENA_BIN) $(TEST_ALLOC_BIN)
	./$(TEST_BIN)
	./$(TEST_ARENA_BIN)
	./$(TEST_ALLOC_BIN)

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
test-asan: tests/test_asmlib.c tests/test_arena.c tests/test_alloc.c $(STATIC) $(HEADER)
	$(CC) $(CFLAGS) $(SANFLAGS) -o $(BUILD)/test_asan tests/test_asmlib.c $(STATIC)
	ASAN_OPTIONS=detect_leaks=1 ./$(BUILD)/test_asan
	$(CC) $(CFLAGS) $(SANFLAGS) -o $(BUILD)/test_arena_asan tests/test_arena.c $(STATIC)
	ASAN_OPTIONS=detect_leaks=1 ./$(BUILD)/test_arena_asan
	$(CC) $(CFLAGS) $(SANFLAGS) -o $(BUILD)/test_alloc_asan tests/test_alloc.c $(STATIC)
	ASAN_OPTIONS=detect_leaks=1 ./$(BUILD)/test_alloc_asan

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

# ---- practical example ------------------------------------------------------
$(EX_BIN): examples/example.c $(STATIC) $(HEADER)
	$(CC) $(CFLAGS) -o $@ examples/example.c $(STATIC) $(LDFLAGS)

example: $(EX_BIN)
	./$(EX_BIN)

clean:
	rm -rf $(BUILD)
