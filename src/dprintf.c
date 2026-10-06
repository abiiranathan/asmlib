/*==============================================================================
 * dprintf.c - formatted output to a file descriptor (Linux x86-64 / AArch64)
 *------------------------------------------------------------------------------
 * SPDX-License-Identifier: MIT
 *
 * The buffer-targeted printf family lives in src/libc/printf.c and is shared by
 * every backend. This file adds the file-descriptor variants on top of it using
 * the raw write(2) wrapper (asm_sys_write) and the library's own heap, so no
 * libc is involved:
 *
 *   int asm_dprintf (int fd, const char *fmt, ...);
 *   int asm_vdprintf(int fd, const char *fmt, va_list ap);
 *   int asm_printf  (const char *fmt, ...);        -> fd 1 (stdout)
 *   int asm_vprintf (const char *fmt, va_list ap);
 *
 * Only the native (OS-backed) backends compile this file.
 *============================================================================*/

#include <stdarg.h>
#include <stddef.h>

extern int  asm_vsnprintf(char *dst, size_t size, const char *fmt, va_list ap);
extern void *asm_malloc(size_t size);
extern void  asm_free(void *ptr);
extern long  asm_sys_write(int fd, const void *buf, size_t count);

static int write_all(int fd, const char *buf, size_t n) {
    size_t off = 0;
    while (off < n) {
        long r = asm_sys_write(fd, buf + off, n - off);
        if (r <= 0) return -1;
        off += (size_t)r;
    }
    return (int)n;
}

int asm_vdprintf(int fd, const char *fmt, va_list ap) {
    va_list a;
    char *buf;
    int n, r;

    va_copy(a, ap);
    n = asm_vsnprintf(NULL, 0, fmt, a);
    va_end(a);
    if (n < 0) return -1;

    buf = (char *)asm_malloc((size_t)n + 1);
    if (!buf) return -1;

    va_copy(a, ap);
    asm_vsnprintf(buf, (size_t)n + 1, fmt, a);
    va_end(a);

    r = write_all(fd, buf, (size_t)n);
    asm_free(buf);
    return r;
}

int asm_dprintf(int fd, const char *fmt, ...) {
    va_list ap;
    int r;
    va_start(ap, fmt);
    r = asm_vdprintf(fd, fmt, ap);
    va_end(ap);
    return r;
}

int asm_vprintf(const char *fmt, va_list ap) {
    return asm_vdprintf(1, fmt, ap);
}

int asm_printf(const char *fmt, ...) {
    va_list ap;
    int r;
    va_start(ap, fmt);
    r = asm_vdprintf(1, fmt, ap);
    va_end(ap);
    return r;
}
