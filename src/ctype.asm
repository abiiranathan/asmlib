;==============================================================================
; ctype.asm - branchless ASCII character classification (System V AMD64 ABI)
;------------------------------------------------------------------------------
; Implements the C-locale ctype predicates and case converters:
;
;   int asm_toupper (int c);   int asm_tolower (int c);
;   int asm_isalpha (int c);   int asm_isdigit (int c);
;   int asm_isalnum (int c);   int asm_isspace (int c);
;   int asm_isupper (int c);   int asm_islower (int c);
;   int asm_isxdigit(int c);   int asm_isprint (int c);
;   int asm_iscntrl (int c);   int asm_isgraph (int c);
;   int asm_ispunct (int c);   int asm_isblank (int c);
;
; The predicates return 1 for true and 0 for false; the exact non-zero value
; is not part of the contract (libc returns implementation-defined flags).
; All routines assume a value in the range 0..255 or EOF; like libc, values
; outside the unsigned-char range are not meaningful.
;==============================================================================

BITS 64
default rel

%include "common.inc"

section .text

;==============================================================================
; int asm_tolower(int c)
;------------------------------------------------------------------------------
; Converts an upper-case ASCII letter to lower case; other bytes unchanged.
;
; Parameters (System V AMD64 ABI):
;   edi = c (int)  - character value (0..255 or EOF)
; Returns:
;   eax = the converted character (unchanged unless c is 'A'..'Z')
; Uses / clobbers:
;   reads edi; writes eax, edx; no callee-saved registers, no syscall
;==============================================================================
global asm_tolower:function             ; export the case converter as a function
asm_tolower:
    ; ---- single-range test: 'A'..'Z' selects the lower-case bit ----
    mov     eax, edi                    ; eax = c (result starts as the input)
    lea     edx, [rdi-'A']              ; edx = c - 'A' (signed distance above 'A')
    cmp     edx, 'Z'-'A'                ; is the distance within 0..25?
    setbe   dl                          ; dl = 1 if c is in 'A'..'Z', else 0
    movzx   edx, dl                     ; edx = 0 or 1 (clear the upper bits)
    shl     edx, 5                      ; edx = 0 or 32 (bit 5, the case bit)
    or      eax, edx                    ; set bit 5 to fold upper case to lower
    ret                                 ; return the converted character in eax

;==============================================================================
; int asm_toupper(int c)
;------------------------------------------------------------------------------
; Converts a lower-case ASCII letter to upper case; other bytes unchanged.
;
; Parameters (System V AMD64 ABI):
;   edi = c (int)  - character value (0..255 or EOF)
; Returns:
;   eax = the converted character (unchanged unless c is 'a'..'z')
; Uses / clobbers:
;   reads edi; writes eax, edx; no callee-saved registers, no syscall
;==============================================================================
global asm_toupper:function             ; export the case converter as a function
asm_toupper:
    ; ---- single-range test: 'a'..'z' clears the lower-case bit ----
    mov     eax, edi                    ; eax = c (result starts as the input)
    lea     edx, [rdi-'a']              ; edx = c - 'a' (signed distance above 'a')
    cmp     edx, 'z'-'a'                ; is the distance within 0..25?
    setbe   dl                          ; dl = 1 if c is in 'a'..'z', else 0
    movzx   edx, dl                     ; edx = 0 or 1 (clear the upper bits)
    shl     edx, 5                      ; edx = 0 or 32 (bit 5, the case bit)
    sub     eax, edx                    ; clear bit 5 to fold lower case to upper
    ret                                 ; return the converted character in eax

;==============================================================================
; int asm_isdigit(int c)
;------------------------------------------------------------------------------
; True for the decimal digits '0'..'9' (a single ranged comparison).
;
; Parameters (System V AMD64 ABI):
;   edi = c (int)  - character value (0..255 or EOF)
; Returns:
;   eax = 1 if c is a decimal digit, 0 otherwise
; Uses / clobbers:
;   reads edi; writes eax, edx; no callee-saved registers, no syscall
;==============================================================================
global asm_isdigit:function             ; export the predicate as a function
asm_isdigit:
    ; ---- range test: '0'..'9' ----
    xor     eax, eax                    ; eax = 0 (assume false)
    lea     edx, [rdi-'0']              ; edx = c - '0'
    cmp     edx, '9'-'0'                ; is the unsigned distance within 0..9?
    setbe   al                          ; al = 1 if c lies within the digit range
    ret                                 ; return the predicate in eax

;==============================================================================
; int asm_isupper(int c)
;------------------------------------------------------------------------------
; True for the upper-case letters 'A'..'Z'.
;
; Parameters (System V AMD64 ABI):
;   edi = c (int)  - character value (0..255 or EOF)
; Returns:
;   eax = 1 if c is an upper-case letter, 0 otherwise
; Uses / clobbers:
;   reads edi; writes eax, edx; no callee-saved registers, no syscall
;==============================================================================
global asm_isupper:function             ; export the predicate as a function
asm_isupper:
    ; ---- range test: 'A'..'Z' ----
    xor     eax, eax                    ; eax = 0 (assume false)
    lea     edx, [rdi-'A']              ; edx = c - 'A'
    cmp     edx, 'Z'-'A'                ; is the unsigned distance within 0..25?
    setbe   al                          ; al = 1 if c lies within the upper-case range
    ret                                 ; return the predicate in eax

;==============================================================================
; int asm_islower(int c)
;------------------------------------------------------------------------------
; True for the lower-case letters 'a'..'z'.
;
; Parameters (System V AMD64 ABI):
;   edi = c (int)  - character value (0..255 or EOF)
; Returns:
;   eax = 1 if c is a lower-case letter, 0 otherwise
; Uses / clobbers:
;   reads edi; writes eax, edx; no callee-saved registers, no syscall
;==============================================================================
global asm_islower:function             ; export the predicate as a function
asm_islower:
    ; ---- range test: 'a'..'z' ----
    xor     eax, eax                    ; eax = 0 (assume false)
    lea     edx, [rdi-'a']              ; edx = c - 'a'
    cmp     edx, 'z'-'a'                ; is the unsigned distance within 0..25?
    setbe   al                          ; al = 1 if c lies within the lower-case range
    ret                                 ; return the predicate in eax

;==============================================================================
; int asm_isalpha(int c)
;------------------------------------------------------------------------------
; True for the ASCII letters 'A'..'Z' and 'a'..'z'.
;
; Parameters (System V AMD64 ABI):
;   edi = c (int)  - character value (0..255 or EOF)
; Returns:
;   eax = 1 if c is a letter, 0 otherwise
; Uses / clobbers:
;   reads edi; writes eax, edx, ecx; no callee-saved registers, no syscall
;==============================================================================
global asm_isalpha:function             ; export the predicate as a function
asm_isalpha:
    ; ---- ranges 'A'..'Z' and 'a'..'z' ----
    xor     eax, eax                    ; eax = 0 (assume false)
    lea     edx, [rdi-'A']              ; edx = c - 'A'
    cmp     edx, 'Z'-'A'                ; upper case: distance within 0..25?
    setbe   al                          ; al = 1 if c is upper case
    lea     edx, [rdi-'a']              ; edx = c - 'a'
    cmp     edx, 'z'-'a'                ; lower case: distance within 0..25?
    setbe   cl                          ; cl = 1 if c is lower case
    or      al, cl                      ; either case counts as alpha
    movzx   eax, al                     ; zero-extend the boolean to eax
    ret                                 ; return the predicate in eax

;==============================================================================
; int asm_isalnum(int c)
;------------------------------------------------------------------------------
; True for the ASCII letters and decimal digits.
;
; Parameters (System V AMD64 ABI):
;   edi = c (int)  - character value (0..255 or EOF)
; Returns:
;   eax = 1 if c is alphanumeric, 0 otherwise
; Uses / clobbers:
;   reads edi; writes eax, edx, ecx; no callee-saved registers, no syscall
;==============================================================================
global asm_isalnum:function             ; export the predicate as a function
asm_isalnum:
    ; ---- ranges '0'..'9', 'A'..'Z' and 'a'..'z' ----
    xor     eax, eax                    ; eax = 0 (assume false)
    lea     edx, [rdi-'0']              ; edx = c - '0'
    cmp     edx, '9'-'0'                ; digit: distance within 0..9?
    setbe   al                          ; al = 1 if c is a digit
    lea     edx, [rdi-'A']              ; edx = c - 'A'
    cmp     edx, 'Z'-'A'                ; upper case: distance within 0..25?
    setbe   cl                          ; cl = 1 if c is upper case
    or      al, cl                      ; accumulate digit-or-upper
    lea     edx, [rdi-'a']              ; edx = c - 'a'
    cmp     edx, 'z'-'a'                ; lower case: distance within 0..25?
    setbe   cl                          ; cl = 1 if c is lower case
    or      al, cl                      ; accumulate ...-or-lower
    movzx   eax, al                     ; zero-extend the boolean to eax
    ret                                 ; return the predicate in eax

;==============================================================================
; int asm_isspace(int c)
;------------------------------------------------------------------------------
; True for space and the standard whitespace controls (0x09..0x0D, 0x20).
;
; Parameters (System V AMD64 ABI):
;   edi = c (int)  - character value (0..255 or EOF)
; Returns:
;   eax = 1 if c is whitespace, 0 otherwise
; Uses / clobbers:
;   reads edi; writes eax, edx, ecx; no callee-saved registers, no syscall
;==============================================================================
global asm_isspace:function             ; export the predicate as a function
asm_isspace:
    ; ---- exact space, plus the 0x09..0x0D control range ----
    xor     eax, eax                    ; eax = 0 (assume false)
    cmp     edi, ' '                    ; is c exactly space?
    sete    al                          ; al = 1 if c is space
    lea     edx, [rdi-9]                ; edx = c - '\t' (TAB)
    cmp     edx, 13-9                   ; distance within 0..4 (TAB..CR)?
    setbe   cl                          ; cl = 1 if c is in the whitespace range
    or      al, cl                      ; combine the space and range tests
    movzx   eax, al                     ; zero-extend the boolean to eax
    ret                                 ; return the predicate in eax

;==============================================================================
; int asm_isxdigit(int c)
;------------------------------------------------------------------------------
; True for the hexadecimal digits '0'..'9', 'A'..'F' and 'a'..'f'.
;
; Parameters (System V AMD64 ABI):
;   edi = c (int)  - character value (0..255 or EOF)
; Returns:
;   eax = 1 if c is a hexadecimal digit, 0 otherwise
; Uses / clobbers:
;   reads edi; writes eax, edx, ecx; no callee-saved registers, no syscall
;==============================================================================
global asm_isxdigit:function            ; export the predicate as a function
asm_isxdigit:
    ; ---- ranges '0'..'9', 'A'..'F' and 'a'..'f' ----
    xor     eax, eax                    ; eax = 0 (assume false)
    lea     edx, [rdi-'0']              ; edx = c - '0'
    cmp     edx, '9'-'0'                ; decimal digit: distance within 0..9?
    setbe   al                          ; al = 1 if c is a decimal digit
    lea     edx, [rdi-'A']              ; edx = c - 'A'
    cmp     edx, 'F'-'A'                ; upper hex: distance within 0..5?
    setbe   cl                          ; cl = 1 if c is an upper-case hex letter
    or      al, cl                      ; accumulate digit-or-upper-hex
    lea     edx, [rdi-'a']              ; edx = c - 'a'
    cmp     edx, 'f'-'a'                ; lower hex: distance within 0..5?
    setbe   cl                          ; cl = 1 if c is a lower-case hex letter
    or      al, cl                      ; accumulate ...-or-lower-hex
    movzx   eax, al                     ; zero-extend the boolean to eax
    ret                                 ; return the predicate in eax

;==============================================================================
; int asm_isprint(int c)
;------------------------------------------------------------------------------
; True for printable bytes 0x20..0x7E.
;
; Parameters (System V AMD64 ABI):
;   edi = c (int)  - character value (0..255 or EOF)
; Returns:
;   eax = 1 if c is printable, 0 otherwise
; Uses / clobbers:
;   reads edi; writes eax, edx; no callee-saved registers, no syscall
;==============================================================================
global asm_isprint:function             ; export the predicate as a function
asm_isprint:
    ; ---- range test: 0x20 (space) through 0x7E ----
    xor     eax, eax                    ; eax = 0 (assume false)
    lea     edx, [rdi-0x20]             ; edx = c - 0x20
    cmp     edx, 0x7E-0x20              ; is the distance within 0..0x5E?
    setbe   al                          ; al = 1 if c lies within the printable range
    ret                                 ; return the predicate in eax

;==============================================================================
; int asm_iscntrl(int c)
;------------------------------------------------------------------------------
; True for control bytes 0x00..0x1F and 0x7F.
;
; Parameters (System V AMD64 ABI):
;   edi = c (int)  - character value (0..255 or EOF)
; Returns:
;   eax = 1 if c is a control byte, 0 otherwise
; Uses / clobbers:
;   reads edi; writes eax, ecx; no callee-saved registers, no syscall
;==============================================================================
global asm_iscntrl:function             ; export the predicate as a function
asm_iscntrl:
    ; ---- below 0x20, or exactly 0x7F (DEL) ----
    xor     eax, eax                    ; eax = 0 (assume false)
    cmp     edi, 0x20                   ; is c below space?
    setb    al                          ; al = 1 if c < 0x20
    cmp     edi, 0x7F                   ; is c exactly DEL (0x7F)?
    sete    cl                          ; cl = 1 if c == 0x7F
    or      al, cl                      ; combine the two control conditions
    movzx   eax, al                     ; zero-extend the boolean to eax
    ret                                 ; return the predicate in eax

;==============================================================================
; int asm_isgraph(int c)
;------------------------------------------------------------------------------
; True for visible bytes 0x21..0x7E (printable except space).
;
; Parameters (System V AMD64 ABI):
;   edi = c (int)  - character value (0..255 or EOF)
; Returns:
;   eax = 1 if c is visible, 0 otherwise
; Uses / clobbers:
;   reads edi; writes eax, edx; no callee-saved registers, no syscall
;==============================================================================
global asm_isgraph:function             ; export the predicate as a function
asm_isgraph:
    ; ---- range test: 0x21 ('!') through 0x7E ----
    xor     eax, eax                    ; eax = 0 (assume false)
    lea     edx, [rdi-0x21]             ; edx = c - 0x21
    cmp     edx, 0x7E-0x21              ; is the distance within 0..0x5D?
    setbe   al                          ; al = 1 if c lies within the visible range
    ret                                 ; return the predicate in eax

;==============================================================================
; int asm_ispunct(int c)
;------------------------------------------------------------------------------
; True for printable, non-alphanumeric ASCII (punctuation).
;
; Parameters (System V AMD64 ABI):
;   edi = c (int)  - character value (0..255 or EOF)
; Returns:
;   eax = 1 if c is punctuation, 0 otherwise
; Uses / clobbers:
;   reads edi; writes eax, edx, ecx; no callee-saved registers, no syscall
;==============================================================================
global asm_ispunct:function             ; export the predicate as a function
asm_ispunct:
    ; ---- visible (0x21..0x7E), then subtract alphanumeric membership ----
    xor     eax, eax                    ; eax = 0 (assume false)
    lea     edx, [rdi-0x21]             ; edx = c - 0x21
    cmp     edx, 0x7E-0x21              ; is the distance within 0..0x5D?
    setbe   al                          ; al = 1 if c is visible
    ; subtract the alphanumeric membership
    lea     edx, [rdi-'0']              ; edx = c - '0'
    cmp     edx, '9'-'0'                ; digit: distance within 0..9?
    setbe   cl                          ; cl = 1 if c is a digit
    lea     edx, [rdi-'A']              ; edx = c - 'A'
    cmp     edx, 'Z'-'A'                ; upper case: distance within 0..25?
    setbe   ch                          ; ch = 1 if c is upper case
    or      cl, ch                      ; cl |= upper-case flag
    lea     edx, [rdi-'a']              ; edx = c - 'a'
    cmp     edx, 'z'-'a'                ; lower case: distance within 0..25?
    setbe   ch                          ; ch = 1 if c is lower case
    or      cl, ch                      ; cl = 1 if c is alphanumeric
    ; al = visible && !alnum
    xor     cl, 1                       ; cl = 1 if NOT alphanumeric
    and     al, cl                      ; al = visible AND !alphanumeric
    movzx   eax, al                     ; zero-extend the boolean to eax
    ret                                 ; return the predicate in eax

;==============================================================================
; int asm_isblank(int c)
;------------------------------------------------------------------------------
; True for space and horizontal tab.
;
; Parameters (System V AMD64 ABI):
;   edi = c (int)  - character value (0..255 or EOF)
; Returns:
;   eax = 1 if c is a blank, 0 otherwise
; Uses / clobbers:
;   reads edi; writes eax, ecx; no callee-saved registers, no syscall
;==============================================================================
global asm_isblank:function             ; export the predicate as a function
asm_isblank:
    ; ---- exact space or horizontal tab ----
    xor     eax, eax                    ; eax = 0 (assume false)
    cmp     edi, ' '                    ; is c exactly space?
    sete    al                          ; al = 1 if c is space
    cmp     edi, 9                      ; is c exactly horizontal tab?
    sete    cl                          ; cl = 1 if c is a tab
    or      al, cl                      ; combine the two tests
    movzx   eax, al                     ; zero-extend the boolean to eax
    ret                                 ; return the predicate in eax

GNU_STACK_NOTE                          ; emit the non-executable .note.GNU-stack section
