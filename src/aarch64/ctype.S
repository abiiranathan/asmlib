/*==============================================================================
 * ctype.S - branchless ASCII character classification (AArch64 / AAPCS64)
 *------------------------------------------------------------------------------
 * SPDX-License-Identifier: MIT
 *
 * AArch64 port of src/ctype.asm. Implements the C-locale ctype predicates and
 * case converters:
 *
 *   int asm_toupper (int c);   int asm_tolower (int c);
 *   int asm_isalpha (int c);   int asm_isdigit (int c);
 *   int asm_isalnum (int c);   int asm_isspace (int c);
 *   int asm_isupper (int c);   int asm_islower (int c);
 *   int asm_isxdigit(int c);   int asm_isprint (int c);
 *   int asm_iscntrl (int c);   int asm_isgraph (int c);
 *   int asm_ispunct (int c);   int asm_isblank (int c);
 *
 * Every predicate is a set of range tests expressed with `sub`, `cmp` and
 * `cset`, so the code is branch-free and has no unpredictable jumps. The
 * predicates return 1 for true and 0 for false; the exact non-zero value is
 * not part of the contract (libc returns implementation-defined flags). All
 * routines assume a value in the range 0..255 or EOF; like libc, values
 * outside the unsigned-char range are not meaningful.
 *============================================================================*/

#include "common_aarch64.inc"

    .text

/*==============================================================================
 * int asm_tolower(int c)
 *------------------------------------------------------------------------------
 * Converts an upper-case ASCII letter to lower case; other bytes unchanged.
 *
 * Parameters (AAPCS64):
 *   w0 = c (int)  - character value (0..255 or EOF)
 * Returns:
 *   w0 = the converted character (unchanged unless c is 'A'..'Z')
 * Uses / clobbers:
 *   Reads w0; writes w0, w1, w2; no callee-saved registers, no syscall
 *============================================================================*/
    .globl asm_tolower
    .type  asm_tolower, %function
    .p2align 2
asm_tolower:
    /* ---- single-range test: 'A'..'Z' selects the lower-case bit ---- */
    mov     w1, w0                      /* w1 = c (result starts as the input)*/
    sub     w2, w0, #'A'                /* w2 = c - 'A'                       */
    cmp     w2, #'Z'-'A'                /* distance within 0..25?             */
    cset    w2, ls                      /* w2 = 1 if c is in 'A'..'Z'         */
    lsl     w2, w2, #5                  /* w2 = 0 or 32 (the case bit 5)      */
    orr     w0, w1, w2                  /* set bit 5 to fold upper to lower   */
    ret
    .size asm_tolower, .-asm_tolower

/*==============================================================================
 * int asm_toupper(int c)
 *------------------------------------------------------------------------------
 * Converts a lower-case ASCII letter to upper case; other bytes unchanged.
 *
 * Parameters (AAPCS64):
 *   w0 = c (int)  - character value (0..255 or EOF)
 * Returns:
 *   w0 = the converted character (unchanged unless c is 'a'..'z')
 * Uses / clobbers:
 *   Reads w0; writes w0, w1, w2; no callee-saved registers, no syscall
 *============================================================================*/
    .globl asm_toupper
    .type  asm_toupper, %function
    .p2align 2
asm_toupper:
    /* ---- single-range test: 'a'..'z' clears the lower-case bit ---- */
    mov     w1, w0                      /* w1 = c (result starts as the input)*/
    sub     w2, w0, #'a'                /* w2 = c - 'a'                       */
    cmp     w2, #'z'-'a'                /* distance within 0..25?             */
    cset    w2, ls                      /* w2 = 1 if c is in 'a'..'z'         */
    lsl     w2, w2, #5                  /* w2 = 0 or 32 (the case bit 5)      */
    sub     w0, w1, w2                  /* clear bit 5 to fold lower to upper */
    ret
    .size asm_toupper, .-asm_toupper

/*==============================================================================
 * int asm_isdigit(int c)
 *------------------------------------------------------------------------------
 * True for the decimal digits '0'..'9' (a single ranged comparison).
 *
 * Parameters (AAPCS64):
 *   w0 = c (int)  - character value (0..255 or EOF)
 * Returns:
 *   w0 = 1 if c is a decimal digit, 0 otherwise
 * Uses / clobbers:
 *   Reads w0; writes w0, w1; no callee-saved registers, no syscall
 *============================================================================*/
    .globl asm_isdigit
    .type  asm_isdigit, %function
    .p2align 2
asm_isdigit:
    /* ---- range test: '0'..'9' ---- */
    sub     w1, w0, #'0'                /* w1 = c - '0'                       */
    cmp     w1, #'9'-'0'                /* unsigned distance within 0..9?     */
    cset    w0, ls                      /* w0 = 1 if c lies within the digits */
    ret
    .size asm_isdigit, .-asm_isdigit

/*==============================================================================
 * int asm_isupper(int c)
 *------------------------------------------------------------------------------
 * True for the upper-case letters 'A'..'Z'.
 *
 * Parameters (AAPCS64):
 *   w0 = c (int)  - character value (0..255 or EOF)
 * Returns:
 *   w0 = 1 if c is an upper-case letter, 0 otherwise
 * Uses / clobbers:
 *   Reads w0; writes w0, w1; no callee-saved registers, no syscall
 *============================================================================*/
    .globl asm_isupper
    .type  asm_isupper, %function
    .p2align 2
asm_isupper:
    /* ---- range test: 'A'..'Z' ---- */
    sub     w1, w0, #'A'                /* w1 = c - 'A'                       */
    cmp     w1, #'Z'-'A'                /* unsigned distance within 0..25?    */
    cset    w0, ls                      /* w0 = 1 if c is upper case          */
    ret
    .size asm_isupper, .-asm_isupper

/*==============================================================================
 * int asm_islower(int c)
 *------------------------------------------------------------------------------
 * True for the lower-case letters 'a'..'z'.
 *
 * Parameters (AAPCS64):
 *   w0 = c (int)  - character value (0..255 or EOF)
 * Returns:
 *   w0 = 1 if c is a lower-case letter, 0 otherwise
 * Uses / clobbers:
 *   Reads w0; writes w0, w1; no callee-saved registers, no syscall
 *============================================================================*/
    .globl asm_islower
    .type  asm_islower, %function
    .p2align 2
asm_islower:
    /* ---- range test: 'a'..'z' ---- */
    sub     w1, w0, #'a'                /* w1 = c - 'a'                       */
    cmp     w1, #'z'-'a'                /* unsigned distance within 0..25?    */
    cset    w0, ls                      /* w0 = 1 if c is lower case          */
    ret
    .size asm_islower, .-asm_islower

/*==============================================================================
 * int asm_isalpha(int c)
 *------------------------------------------------------------------------------
 * True for the ASCII letters 'A'..'Z' and 'a'..'z'.
 *
 * Parameters (AAPCS64):
 *   w0 = c (int)  - character value (0..255 or EOF)
 * Returns:
 *   w0 = 1 if c is a letter, 0 otherwise
 * Uses / clobbers:
 *   Reads w0; writes w0, w1, w2; no callee-saved registers, no syscall
 *============================================================================*/
    .globl asm_isalpha
    .type  asm_isalpha, %function
    .p2align 2
asm_isalpha:
    /* ---- ranges 'A'..'Z' and 'a'..'z' ---- */
    sub     w1, w0, #'A'                /* upper case: distance within 0..25? */
    cmp     w1, #'Z'-'A'
    cset    w1, ls                      /* w1 = 1 if c is upper case          */
    sub     w2, w0, #'a'                /* lower case: distance within 0..25? */
    cmp     w2, #'z'-'a'
    cset    w2, ls                      /* w2 = 1 if c is lower case          */
    orr     w0, w1, w2                  /* either case counts as alpha        */
    ret
    .size asm_isalpha, .-asm_isalpha

/*==============================================================================
 * int asm_isalnum(int c)
 *------------------------------------------------------------------------------
 * True for the ASCII letters and decimal digits.
 *
 * Parameters (AAPCS64):
 *   w0 = c (int)  - character value (0..255 or EOF)
 * Returns:
 *   w0 = 1 if c is alphanumeric, 0 otherwise
 * Uses / clobbers:
 *   Reads w0; writes w0, w1, w2; no callee-saved registers, no syscall
 *============================================================================*/
    .globl asm_isalnum
    .type  asm_isalnum, %function
    .p2align 2
asm_isalnum:
    /* ---- ranges '0'..'9', 'A'..'Z' and 'a'..'z' ---- */
    sub     w1, w0, #'0'                /* digit: distance within 0..9?       */
    cmp     w1, #'9'-'0'
    cset    w1, ls                      /* w1 = 1 if c is a digit             */
    sub     w2, w0, #'A'                /* upper case: distance within 0..25? */
    cmp     w2, #'Z'-'A'
    cset    w2, ls                      /* w2 = 1 if c is upper case          */
    orr     w1, w1, w2                  /* accumulate digit-or-upper          */
    sub     w2, w0, #'a'                /* lower case: distance within 0..25? */
    cmp     w2, #'z'-'a'
    cset    w2, ls                      /* w2 = 1 if c is lower case          */
    orr     w0, w1, w2                  /* accumulate ...-or-lower            */
    ret
    .size asm_isalnum, .-asm_isalnum

/*==============================================================================
 * int asm_isspace(int c)
 *------------------------------------------------------------------------------
 * True for space and the standard whitespace controls (0x09..0x0D, 0x20).
 *
 * Parameters (AAPCS64):
 *   w0 = c (int)  - character value (0..255 or EOF)
 * Returns:
 *   w0 = 1 if c is whitespace, 0 otherwise
 * Uses / clobbers:
 *   Reads w0; writes w0, w1, w2; no callee-saved registers, no syscall
 *============================================================================*/
    .globl asm_isspace
    .type  asm_isspace, %function
    .p2align 2
asm_isspace:
    /* ---- exact space, plus the 0x09..0x0D control range ---- */
    cmp     w0, #' '                    /* is c exactly space?                */
    cset    w1, eq                      /* w1 = 1 if c is space               */
    sub     w2, w0, #9                  /* w2 = c - '\t' (TAB)                */
    cmp     w2, #13-9                   /* distance within 0..4 (TAB..CR)?    */
    cset    w2, ls                      /* w2 = 1 if c is in the range        */
    orr     w0, w1, w2                  /* combine the space and range tests  */
    ret
    .size asm_isspace, .-asm_isspace

/*==============================================================================
 * int asm_isxdigit(int c)
 *------------------------------------------------------------------------------
 * True for the hexadecimal digits '0'..'9', 'A'..'F' and 'a'..'f'.
 *
 * Parameters (AAPCS64):
 *   w0 = c (int)  - character value (0..255 or EOF)
 * Returns:
 *   w0 = 1 if c is a hexadecimal digit, 0 otherwise
 * Uses / clobbers:
 *   Reads w0; writes w0, w1, w2; no callee-saved registers, no syscall
 *============================================================================*/
    .globl asm_isxdigit
    .type  asm_isxdigit, %function
    .p2align 2
asm_isxdigit:
    /* ---- ranges '0'..'9', 'A'..'F' and 'a'..'f' ---- */
    sub     w1, w0, #'0'                /* decimal digit: distance within 0..9?*/
    cmp     w1, #'9'-'0'
    cset    w1, ls                      /* w1 = 1 if c is a decimal digit     */
    sub     w2, w0, #'A'                /* upper hex: distance within 0..5?   */
    cmp     w2, #'F'-'A'
    cset    w2, ls                      /* w2 = 1 if c is an upper hex letter */
    orr     w1, w1, w2                  /* accumulate digit-or-upper-hex      */
    sub     w2, w0, #'a'                /* lower hex: distance within 0..5?   */
    cmp     w2, #'f'-'a'
    cset    w2, ls                      /* w2 = 1 if c is a lower hex letter  */
    orr     w0, w1, w2                  /* accumulate ...-or-lower-hex        */
    ret
    .size asm_isxdigit, .-asm_isxdigit

/*==============================================================================
 * int asm_isprint(int c)
 *------------------------------------------------------------------------------
 * True for printable bytes 0x20..0x7E.
 *
 * Parameters (AAPCS64):
 *   w0 = c (int)  - character value (0..255 or EOF)
 * Returns:
 *   w0 = 1 if c is printable, 0 otherwise
 * Uses / clobbers:
 *   Reads w0; writes w0, w1; no callee-saved registers, no syscall
 *============================================================================*/
    .globl asm_isprint
    .type  asm_isprint, %function
    .p2align 2
asm_isprint:
    /* ---- range test: 0x20 (space) through 0x7E ---- */
    sub     w1, w0, #0x20               /* w1 = c - 0x20                      */
    cmp     w1, #0x7E-0x20              /* distance within 0..0x5E?           */
    cset    w0, ls                      /* w0 = 1 if c is printable           */
    ret
    .size asm_isprint, .-asm_isprint

/*==============================================================================
 * int asm_iscntrl(int c)
 *------------------------------------------------------------------------------
 * True for control bytes 0x00..0x1F and 0x7F.
 *
 * Parameters (AAPCS64):
 *   w0 = c (int)  - character value (0..255 or EOF)
 * Returns:
 *   w0 = 1 if c is a control byte, 0 otherwise
 * Uses / clobbers:
 *   Reads w0; writes w0, w1, w2; no callee-saved registers, no syscall
 *============================================================================*/
    .globl asm_iscntrl
    .type  asm_iscntrl, %function
    .p2align 2
asm_iscntrl:
    /* ---- below 0x20, or exactly 0x7F (DEL) ---- */
    cmp     w0, #0x20                   /* is c below space?                  */
    cset    w1, lo                      /* w1 = 1 if c < 0x20 (unsigned)      */
    cmp     w0, #0x7F                   /* is c exactly DEL (0x7F)?           */
    cset    w2, eq                      /* w2 = 1 if c == 0x7F                */
    orr     w0, w1, w2                  /* combine the two control conditions */
    ret
    .size asm_iscntrl, .-asm_iscntrl

/*==============================================================================
 * int asm_isgraph(int c)
 *------------------------------------------------------------------------------
 * True for visible bytes 0x21..0x7E (printable except space).
 *
 * Parameters (AAPCS64):
 *   w0 = c (int)  - character value (0..255 or EOF)
 * Returns:
 *   w0 = 1 if c is visible, 0 otherwise
 * Uses / clobbers:
 *   Reads w0; writes w0, w1; no callee-saved registers, no syscall
 *============================================================================*/
    .globl asm_isgraph
    .type  asm_isgraph, %function
    .p2align 2
asm_isgraph:
    /* ---- range test: 0x21 ('!') through 0x7E ---- */
    sub     w1, w0, #0x21               /* w1 = c - 0x21                      */
    cmp     w1, #0x7E-0x21              /* distance within 0..0x5D?           */
    cset    w0, ls                      /* w0 = 1 if c is visible             */
    ret
    .size asm_isgraph, .-asm_isgraph

/*==============================================================================
 * int asm_ispunct(int c)
 *------------------------------------------------------------------------------
 * True for printable, non-alphanumeric ASCII (punctuation).
 *
 * Parameters (AAPCS64):
 *   w0 = c (int)  - character value (0..255 or EOF)
 * Returns:
 *   w0 = 1 if c is punctuation, 0 otherwise
 * Uses / clobbers:
 *   Reads w0; writes w0, w1, w2, w3; no callee-saved registers, no syscall
 *============================================================================*/
    .globl asm_ispunct
    .type  asm_ispunct, %function
    .p2align 2
asm_ispunct:
    /* ---- visible (0x21..0x7E), then subtract alphanumeric membership ---- */
    sub     w1, w0, #0x21               /* visible range: 0x21..0x7E?         */
    cmp     w1, #0x7E-0x21
    cset    w1, ls                      /* w1 = 1 if c is visible             */
    sub     w2, w0, #'0'                /* digit: distance within 0..9?       */
    cmp     w2, #'9'-'0'
    cset    w2, ls                      /* w2 = 1 if c is a digit             */
    sub     w3, w0, #'A'                /* upper case: distance within 0..25? */
    cmp     w3, #'Z'-'A'
    cset    w3, ls                      /* w3 = 1 if c is upper case          */
    orr     w2, w2, w3                  /* w2 |= upper-case flag              */
    sub     w3, w0, #'a'                /* lower case: distance within 0..25? */
    cmp     w3, #'z'-'a'
    cset    w3, ls                      /* w3 = 1 if c is lower case          */
    orr     w2, w2, w3                  /* w2 = 1 if c is alphanumeric        */
    /* ---- w0 = visible && !alphanumeric ---- */
    bic     w0, w1, w2                  /* clear visible when alphanumeric    */
    ret
    .size asm_ispunct, .-asm_ispunct

/*==============================================================================
 * int asm_isblank(int c)
 *------------------------------------------------------------------------------
 * True for space and horizontal tab.
 *
 * Parameters (AAPCS64):
 *   w0 = c (int)  - character value (0..255 or EOF)
 * Returns:
 *   w0 = 1 if c is a blank, 0 otherwise
 * Uses / clobbers:
 *   Reads w0; writes w0, w1, w2; no callee-saved registers, no syscall
 *============================================================================*/
    .globl asm_isblank
    .type  asm_isblank, %function
    .p2align 2
asm_isblank:
    /* ---- exact space or horizontal tab ---- */
    cmp     w0, #' '                    /* is c exactly space?                */
    cset    w1, eq                      /* w1 = 1 if c is space               */
    cmp     w0, #9                      /* is c exactly horizontal tab?       */
    cset    w2, eq                      /* w2 = 1 if c is a tab               */
    orr     w0, w1, w2                  /* combine the two tests              */
    ret
    .size asm_isblank, .-asm_isblank

GNU_STACK_NOTE
