/*==============================================================================
 * fuzz_convert.c - libFuzzer target for the integer formatters
 *------------------------------------------------------------------------------
 * Exercises asm_u64toa / asm_i64toa / asm_u64toa_base / asm_u64tohex with the
 * fuzzer's bytes and checks, on every input:
 *   - the bounded writers never touch a byte past `cap` (canary),
 *   - cap == 0 writes nothing,
 *   - the truncated prefix and the NUL match the untruncated result,
 *   - decimal matches the host snprintf.
 * A canary fault or mismatch traps, which libFuzzer reports as a crash.
 *============================================================================*/

#include "asmlib.h"

#include <stdint.h>
#include <stdio.h>
#include <string.h>

#define CANARY 0xA5

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    if (size < 12) return 0;

    uint64_t v;
    memcpy(&v, data, sizeof v);
    unsigned cap = data[8] % 48;              /* 0..47, spans truncation */
    unsigned base = data[9];
    int upper = data[10] & 1;

    char buf[96];
    char full[80];

    /* ---- asm_u64toa ---- */
    size_t flen = asm_u64toa(v, full, sizeof full);
    memset(buf, CANARY, sizeof buf);
    size_t r = asm_u64toa(v, buf, cap);
    if (r != flen) __builtin_trap();
    if (cap == 0) {
        for (size_t i = 0; i < sizeof buf; i++)
            if ((unsigned char)buf[i] != CANARY) __builtin_trap();
    } else {
        size_t keep = cap - 1 < flen ? cap - 1 : flen;
        if (memcmp(buf, full, keep) != 0) __builtin_trap();
        if (buf[keep] != '\0') __builtin_trap();
        for (size_t i = cap; i < sizeof buf; i++)
            if ((unsigned char)buf[i] != CANARY) __builtin_trap();
    }
    {
        char ref[64];
        int n = snprintf(ref, sizeof ref, "%llu", (unsigned long long)v);
        if ((size_t)n != flen || strcmp(ref, full) != 0) __builtin_trap();
    }

    /* ---- asm_i64toa ---- */
    {
        int64_t sv = (int64_t)v;
        size_t ilen = asm_i64toa(sv, full, sizeof full);
        char ref[64];
        int n = snprintf(ref, sizeof ref, "%lld", (long long)sv);
        if ((size_t)n != ilen || strcmp(ref, full) != 0) __builtin_trap();
        memset(buf, CANARY, sizeof buf);
        if (asm_i64toa(sv, buf, cap) != ilen) __builtin_trap();
        for (size_t i = cap; i < sizeof buf; i++)
            if ((unsigned char)buf[i] != CANARY) __builtin_trap();
    }

    /* ---- asm_u64toa_base (2..36) ---- */
    if (base >= 2 && base <= 36) {
        size_t len = asm_u64toa_base(v, full, sizeof full, base);
        if (len == 0 || len > 64) __builtin_trap();     /* base 2 worst case */
        memset(buf, CANARY, sizeof buf);
        if (asm_u64toa_base(v, buf, cap, base) != len) __builtin_trap();
        for (size_t i = cap; i < sizeof buf; i++)
            if ((unsigned char)buf[i] != CANARY) __builtin_trap();
        for (size_t i = 0; i < len; i++) {
            char c = full[i];
            int d = (c >= '0' && c <= '9') ? c - '0' : (c >= 'a' && c <= 'z') ? c - 'a' + 10 : 99;
            if (d >= (int)base) __builtin_trap();
        }
    }

    /* ---- asm_u64tohex ---- */
    {
        size_t len = asm_u64tohex(v, full, sizeof full, upper);
        if (len == 0 || len > 16) __builtin_trap();
        char ref[32];
        snprintf(ref, sizeof ref, upper ? "%llX" : "%llx", (unsigned long long)v);
        if (strcmp(ref, full) != 0) __builtin_trap();
        memset(buf, CANARY, sizeof buf);
        if (asm_u64tohex(v, buf, cap, upper) != len) __builtin_trap();
        for (size_t i = cap; i < sizeof buf; i++)
            if ((unsigned char)buf[i] != CANARY) __builtin_trap();
    }
    return 0;
}
