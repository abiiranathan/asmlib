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
;==============================================================================
global asm_tolower:function
asm_tolower:
    mov     eax, edi                    ; result starts as the input
    lea     edx, [rdi-'A']              ; distance above 'A'
    cmp     edx, 'Z'-'A'                ; is it an upper-case letter?
    setbe   dl                          ; dl = 1 if so
    movzx   edx, dl                     ; edx = 0 or 1
    shl     edx, 5                      ; edx = 0 or 32
    or      eax, edx                    ; set the lower-case bit
    ret

;==============================================================================
; int asm_toupper(int c)
;------------------------------------------------------------------------------
; Converts a lower-case ASCII letter to upper case; other bytes unchanged.
;==============================================================================
global asm_toupper:function
asm_toupper:
    mov     eax, edi                    ; result starts as the input
    lea     edx, [rdi-'a']              ; distance above 'a'
    cmp     edx, 'z'-'a'                ; is it a lower-case letter?
    setbe   dl                          ; dl = 1 if so
    movzx   edx, dl                     ; edx = 0 or 1
    shl     edx, 5                      ; edx = 0 or 32
    sub     eax, edx                    ; clear the lower-case bit
    ret

;==============================================================================
; int asm_isdigit(int c)
;==============================================================================
global asm_isdigit:function
asm_isdigit:
    xor     eax, eax                    ; assume false
    lea     edx, [rdi-'0']              ; distance above '0'
    cmp     edx, '9'-'0'                ; within '0'..'9'?
    setbe   al                          ; set result
    ret

;==============================================================================
; int asm_isupper(int c)
;==============================================================================
global asm_isupper:function
asm_isupper:
    xor     eax, eax                    ; assume false
    lea     edx, [rdi-'A']              ; distance above 'A'
    cmp     edx, 'Z'-'A'                ; within 'A'..'Z'?
    setbe   al
    ret

;==============================================================================
; int asm_islower(int c)
;==============================================================================
global asm_islower:function
asm_islower:
    xor     eax, eax                    ; assume false
    lea     edx, [rdi-'a']              ; distance above 'a'
    cmp     edx, 'z'-'a'                ; within 'a'..'z'?
    setbe   al
    ret

;==============================================================================
; int asm_isalpha(int c)
;==============================================================================
global asm_isalpha:function
asm_isalpha:
    xor     eax, eax                    ; assume false
    lea     edx, [rdi-'A']              ; distance above 'A'
    cmp     edx, 'Z'-'A'                ; upper case?
    setbe   al
    lea     edx, [rdi-'a']              ; distance above 'a'
    cmp     edx, 'z'-'a'                ; lower case?
    setbe   cl
    or      al, cl                      ; either case counts as alpha
    movzx   eax, al
    ret

;==============================================================================
; int asm_isalnum(int c)
;==============================================================================
global asm_isalnum:function
asm_isalnum:
    xor     eax, eax                    ; assume false
    lea     edx, [rdi-'0']              ; digit?
    cmp     edx, '9'-'0'
    setbe   al
    lea     edx, [rdi-'A']              ; upper case?
    cmp     edx, 'Z'-'A'
    setbe   cl
    or      al, cl
    lea     edx, [rdi-'a']              ; lower case?
    cmp     edx, 'z'-'a'
    setbe   cl
    or      al, cl
    movzx   eax, al
    ret

;==============================================================================
; int asm_isspace(int c)
;------------------------------------------------------------------------------
; True for space and the standard whitespace controls (0x09..0x0D, 0x20).
;==============================================================================
global asm_isspace:function
asm_isspace:
    xor     eax, eax                    ; assume false
    cmp     edi, ' '                    ; ordinary space?
    sete    al
    lea     edx, [rdi-9]                ; distance above TAB
    cmp     edx, 13-9                   ; TAB, LF, VT, FF or CR?
    setbe   cl
    or      al, cl
    movzx   eax, al
    ret

;==============================================================================
; int asm_isxdigit(int c)
;==============================================================================
global asm_isxdigit:function
asm_isxdigit:
    xor     eax, eax                    ; assume false
    lea     edx, [rdi-'0']              ; decimal digit?
    cmp     edx, '9'-'0'
    setbe   al
    lea     edx, [rdi-'A']              ; upper-case hex letter?
    cmp     edx, 'F'-'A'
    setbe   cl
    or      al, cl
    lea     edx, [rdi-'a']              ; lower-case hex letter?
    cmp     edx, 'f'-'a'
    setbe   cl
    or      al, cl
    movzx   eax, al
    ret

;==============================================================================
; int asm_isprint(int c)
;------------------------------------------------------------------------------
; True for printable bytes 0x20..0x7E.
;==============================================================================
global asm_isprint:function
asm_isprint:
    xor     eax, eax                    ; assume false
    lea     edx, [rdi-0x20]             ; distance above space
    cmp     edx, 0x7E-0x20              ; within the printable range?
    setbe   al
    ret

;==============================================================================
; int asm_iscntrl(int c)
;------------------------------------------------------------------------------
; True for control bytes 0x00..0x1F and 0x7F.
;==============================================================================
global asm_iscntrl:function
asm_iscntrl:
    xor     eax, eax                    ; assume false
    cmp     edi, 0x20                   ; below space?
    setb    al
    cmp     edi, 0x7F                   ; exactly DEL?
    sete    cl
    or      al, cl
    movzx   eax, al
    ret

;==============================================================================
; int asm_isgraph(int c)
;------------------------------------------------------------------------------
; True for visible bytes 0x21..0x7E (printable except space).
;==============================================================================
global asm_isgraph:function
asm_isgraph:
    xor     eax, eax                    ; assume false
    lea     edx, [rdi-0x21]             ; distance above '!'
    cmp     edx, 0x7E-0x21              ; within the visible range?
    setbe   al
    ret

;==============================================================================
; int asm_ispunct(int c)
;------------------------------------------------------------------------------
; True for printable, non-alphanumeric ASCII (punctuation).
;==============================================================================
global asm_ispunct:function
asm_ispunct:
    xor     eax, eax                    ; assume false
    lea     edx, [rdi-0x21]             ; is it visible?
    cmp     edx, 0x7E-0x21
    setbe   al
    ; subtract the alphanumeric membership
    lea     edx, [rdi-'0']              ; digit?
    cmp     edx, '9'-'0'
    setbe   cl
    lea     edx, [rdi-'A']              ; upper case?
    cmp     edx, 'Z'-'A'
    setbe   ch
    or      cl, ch
    lea     edx, [rdi-'a']              ; lower case?
    cmp     edx, 'z'-'a'
    setbe   ch
    or      cl, ch
    ; al = visible && !alnum
    xor     cl, 1                       ; cl = 1 if NOT alphanumeric
    and     al, cl
    movzx   eax, al
    ret

;==============================================================================
; int asm_isblank(int c)
;------------------------------------------------------------------------------
; True for space and horizontal tab.
;==============================================================================
global asm_isblank:function
asm_isblank:
    xor     eax, eax                    ; assume false
    cmp     edi, ' '                    ; space?
    sete    al
    cmp     edi, 9                      ; horizontal tab?
    sete    cl
    or      al, cl
    movzx   eax, al
    ret

GNU_STACK_NOTE
