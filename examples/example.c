/*==============================================================================
 * example.c - practical use of asmlib: a fast word-frequency analyser
 *------------------------------------------------------------------------------
 * Reads a text file (or builds a synthetic corpus when no file is given) and:
 *   1. counts bytes, lines and words using the vectorised search routines;
 *   2. tokenises with asm_strspn/asm_strcspn and lower-cases with asm_tolower;
 *   3. accumulates a word-frequency hash table using asm_strcmp;
 *   4. reports the most common words and a keyword search via asm_memmem;
 *   5. demonstrates case-insensitive matching with asm_strcasecmp.
 *
 * Build:  make example        Run:  ./build/example [file]
 *============================================================================*/

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "asmlib.h"

#define TABLE_BITS 18
#define TABLE_SIZE (1u << TABLE_BITS)          /* 262144 slots */
#define MAX_WORDS  8

typedef struct {
    const char *word;                          /* points into the word arena   */
    size_t      count;
} entry_t;

static entry_t *table;                          /* open-addressing, zero init   */

/* djb2 hash over the already-lower-cased NUL-terminated word. */
static unsigned long hash_word(const char *s) {
    unsigned long h = 5381;
    for (; *s; s++) h = ((h << 5) + h) + (unsigned char)*s;
    return h;
}

/* Record one occurrence of `word` (length `len`) in the hash table. */
static void count_word(const char *word, size_t len, char **arena) {
    char *key = *arena;                         /* store the key contiguously   */
    for (size_t i = 0; i < len; i++)
        key[i] = (char)asm_tolower((unsigned char)word[i]);
    key[len] = 0;
    *arena += len + 1;

    size_t mask = TABLE_SIZE - 1;
    size_t slot = hash_word(key) & mask;
    for (;;) {
        entry_t *e = &table[slot];
        if (e->word == NULL) {                  /* empty: insert               */
            e->word = key;
            e->count = 1;
            return;
        }
        if (asm_strcmp(e->word, key) == 0) {    /* same word: bump the counter */
            e->count++;
            *arena -= len + 1;                  /* key was redundant           */
            return;
        }
        slot = (slot + 1) & mask;               /* linear probing              */
    }
}

/* Count non-overlapping occurrences of `needle` in `hay` (hay_len bytes). */
static size_t count_occurrences(const char *hay, size_t hay_len,
                                const char *needle) {
    size_t nlen = asm_strlen(needle);
    if (nlen == 0) return 0;
    size_t hits = 0;
    const char *p = hay;
    size_t remaining = hay_len;
    while (remaining >= nlen) {
        const char *hit = asm_memmem(p, remaining, needle, nlen);
        if (!hit) break;
        hits++;
        size_t advance = (size_t)(hit - p) + nlen; /* skip past the match      */
        p += advance;
        remaining -= advance;
    }
    return hits;
}

static void report_top(void) {
    entry_t best[MAX_WORDS];
    memset(best, 0, sizeof best);
    for (size_t i = 0; i < TABLE_SIZE; i++) {
        entry_t *e = &table[i];
        if (!e->word) continue;
        for (int k = 0; k < MAX_WORDS; k++) {
            if (e->count > best[k].count) {
                if (k < MAX_WORDS - 1)
                    memmove(&best[k + 1], &best[k],
                            (MAX_WORDS - 1 - k) * sizeof(entry_t));
                best[k] = *e;
                break;
            }
        }
    }
    printf("  top words:\n");
    for (int k = 0; k < MAX_WORDS && best[k].word; k++)
        printf("    %-12s %zu\n", best[k].word, best[k].count);
}

int main(int argc, char **argv) {
    /* ---- acquire the corpus ------------------------------------------- */
    char *text = NULL;
    size_t text_len = 0;
    if (argc > 1) {
        FILE *f = fopen(argv[1], "rb");
        if (!f) { perror("fopen"); return 1; }
        fseek(f, 0, SEEK_END);
        long sz = ftell(f);
        fseek(f, 0, SEEK_SET);
        text = malloc((size_t)sz + 1);
        text_len = fread(text, 1, (size_t)sz, f);
        fclose(f);
        text[text_len] = 0;
    } else {
        /* Build a synthetic corpus by repeating a few sentences. */
        static const char *seed =
            "The quick brown fox jumps over the lazy dog. "
            "Pack my box with five dozen liquor jugs. "
            "The five boxing wizards jump quickly; the lazy dog sleeps. ";
        size_t seed_len = asm_strlen(seed);
        size_t reps = 20000;
        text = malloc(seed_len * reps + 1);
        for (size_t i = 0; i < reps; i++)
            asm_memcpy(text + i * seed_len, seed, seed_len);
        text_len = seed_len * reps;
        text[text_len] = 0;
    }

    /* ---- basic statistics --------------------------------------------- */
    size_t lines = 0;
    for (const char *p = text; p < text + text_len; ) {
        const char *nl = asm_memchr(p, '\n', (size_t)(text + text_len - p));
        lines++;
        if (!nl) break;
        p = nl + 1;
    }

    /* ---- tokenise and count ------------------------------------------- */
    table = calloc(TABLE_SIZE, sizeof(entry_t));
    char *arena = malloc(text_len + 1);
    char *cursor = arena;
    const char *delims = " \t\r\n.,;:!?\"'()[]{}<>/\\|-+=*&^%$#@`~";

    size_t total_words = 0;
    for (const char *p = text; *p; ) {
        p += asm_strspn(p, delims);             /* skip separators             */
        if (!*p) break;
        size_t len = asm_strcspn(p, delims);    /* length of the next token    */
        count_word(p, len, &cursor);
        total_words++;
        p += len;
    }

    size_t unique = 0;
    for (size_t i = 0; i < TABLE_SIZE; i++)
        if (table[i].word) unique++;

    printf("== asmlib word-frequency example ==\n");
    printf("  corpus      : %zu bytes, %zu lines\n", text_len, lines);
    printf("  words       : %zu total, %zu unique\n", total_words, unique);
    report_top();

    /* ---- substring search with the SIMD memmem ------------------------ */
    const char *keyword = "lazy dog";
    printf("  occurrences of \"%s\": %zu\n",
           keyword, count_occurrences(text, text_len, keyword));

    /* ---- case-insensitive comparison demo ----------------------------- */
    printf("  strcasecmp(\"Hello\", \"hELLo\") = %d\n",
           asm_strcasecmp("Hello", "hELLo"));

    free(arena);
    free(table);
    free(text);
    return 0;
}
