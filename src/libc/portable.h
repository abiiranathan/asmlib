/*==============================================================================
 * portable.h - portable, freestanding C backend for the non-x86 targets
 *------------------------------------------------------------------------------
 * SPDX-License-Identifier: MIT
 *
 * The x86-64 memory/string/allocator routines are hand-written NASM and cannot
 * run in WebAssembly. This header declares a portable C implementation of the
 * same API that is compiled for wasm32 (and any freestanding target), so the
 * whole library - not just src/math - can be linked without libc.
 *
 * By default the symbols are `asm_`-prefixed (asm_memcpy, ...) so they can be
 * differentially tested against a host libc. Compile the sources with
 * -DASMLIB_LIBC_STD_NAMES to expose the standard names (memcpy, malloc, ...)
 * instead; that is what the wasm build does so the module is a drop-in libc.
 *============================================================================*/

#ifndef ASMLIB_PORTABLE_H
#define ASMLIB_PORTABLE_H

#include <stddef.h>

#ifdef ASMLIB_LIBC_STD_NAMES
#define ASM_LIBC(name) name
#else
#define ASM_LIBC(name) asm_##name
#endif

/* ---- memory ------------------------------------------------------------ */
void *ASM_LIBC(memcpy)(void *dst, const void *src, size_t n);
void *ASM_LIBC(memmove)(void *dst, const void *src, size_t n);
void *ASM_LIBC(mempcpy)(void *dst, const void *src, size_t n);
void *ASM_LIBC(memccpy)(void *dst, const void *src, int c, size_t n);
void *ASM_LIBC(memset)(void *dst, int c, size_t n);
void *ASM_LIBC(bzero)(void *dst, size_t n);
void  ASM_LIBC(explicit_bzero)(void *dst, size_t n);
int   ASM_LIBC(memcmp)(const void *a, const void *b, size_t n);
void *ASM_LIBC(memchr)(const void *s, int c, size_t n);
void *ASM_LIBC(memrchr)(const void *s, int c, size_t n);

/* ---- string ------------------------------------------------------------ */
size_t ASM_LIBC(strlen)(const char *s);
size_t ASM_LIBC(strnlen)(const char *s, size_t maxlen);
char  *ASM_LIBC(strncpy)(char *dst, const char *src, size_t n);
char  *ASM_LIBC(strncat)(char *dst, const char *src, size_t n);
char  *ASM_LIBC(stpncpy)(char *dst, const char *src, size_t n);
size_t ASM_LIBC(strlcpy)(char *dst, const char *src, size_t size);
size_t ASM_LIBC(strlcat)(char *dst, const char *src, size_t size);
int    ASM_LIBC(strcmp)(const char *a, const char *b);
int    ASM_LIBC(strncmp)(const char *a, const char *b, size_t n);
int    ASM_LIBC(strcasecmp)(const char *a, const char *b);
int    ASM_LIBC(strncasecmp)(const char *a, const char *b, size_t n);
char  *ASM_LIBC(strchr)(const char *s, int c);
char  *ASM_LIBC(strrchr)(const char *s, int c);
char  *ASM_LIBC(strstr)(const char *hay, const char *needle);
void  *ASM_LIBC(memmem)(const void *hay, size_t hlen, const void *needle, size_t nlen);
size_t ASM_LIBC(strspn)(const char *s, const char *accept);
size_t ASM_LIBC(strcspn)(const char *s, const char *accept);
char  *ASM_LIBC(strpbrk)(const char *s, const char *accept);

/* ---- allocator --------------------------------------------------------- */
void  *ASM_LIBC(malloc)(size_t size);
void  *ASM_LIBC(calloc)(size_t count, size_t size);
void  *ASM_LIBC(realloc)(void *ptr, size_t size);
void   ASM_LIBC(free)(void *ptr);
void  *ASM_LIBC(reallocarray)(void *ptr, size_t count, size_t size);
size_t ASM_LIBC(malloc_usable_size)(void *ptr);
int    ASM_LIBC(posix_memalign)(void **memptr, size_t alignment, size_t size);
void  *ASM_LIBC(aligned_alloc)(size_t alignment, size_t size);

/* ---- formatting -------------------------------------------------------- */
/* Bounded integer-to-string converters (always asm_-prefixed) and the minimal
 * snprintf. See include/asmlib.h for the supported format subset. */
size_t asm_u64toa(unsigned long long value, char *buf, size_t cap);
size_t asm_i64toa(long long value, char *buf, size_t cap);
size_t asm_u64toa_base(unsigned long long value, char *buf, size_t cap, unsigned base);
size_t asm_u64tohex(unsigned long long value, char *buf, size_t cap, int uppercase);
int    ASM_LIBC(snprintf)(char *dst, size_t size, const char *fmt, ...);
int    ASM_LIBC(sscanf)(const char *src, const char *fmt, ...);

#endif /* ASMLIB_PORTABLE_H */
