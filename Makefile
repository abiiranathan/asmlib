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

TEST_BIN  := $(BUILD)/test_asmlib
BENCH_BIN := $(BUILD)/bench
EX_BIN    := $(BUILD)/example

.PHONY: all test test-valgrind test-asan bench example clean

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

test: $(TEST_BIN)
	./$(TEST_BIN)

# Run the suite under valgrind; fails on any invalid read/write or leak.
# --undef-value-errors=no silences valgrind's inability to model AVX2 register
# definedness (it also flags glibc's own SIMD string routines for this).
test-valgrind: $(TEST_BIN)
	$(VALGRIND) --tool=memcheck --error-exitcode=99 --leak-check=full \
		--errors-for-leak-kinds=definite --undef-value-errors=no ./$(TEST_BIN)

# Run the suite under AddressSanitizer + UndefinedBehaviorSanitizer.
test-asan: tests/test_asmlib.c $(STATIC) $(HEADER)
	$(CC) $(CFLAGS) $(SANFLAGS) -o $(BUILD)/test_asan tests/test_asmlib.c $(STATIC)
	ASAN_OPTIONS=detect_leaks=1 ./$(BUILD)/test_asan

# ---- benchmark --------------------------------------------------------------
$(BENCH_BIN): bench/bench.c $(STATIC) $(HEADER)
	$(CC) $(CFLAGS) -o $@ bench/bench.c $(STATIC) $(LDFLAGS)

bench: $(BENCH_BIN)
	./$(BENCH_BIN)

# ---- practical example ------------------------------------------------------
$(EX_BIN): examples/example.c $(STATIC) $(HEADER)
	$(CC) $(CFLAGS) -o $@ examples/example.c $(STATIC) $(LDFLAGS)

example: $(EX_BIN)
	./$(EX_BIN)

clean:
	rm -rf $(BUILD)
