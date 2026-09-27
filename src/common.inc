;==============================================================================
; common.inc - shared definitions for the asmlib x86-64 assembly library
;------------------------------------------------------------------------------
; This file is included by every translation unit. It contains only NASM
; preprocessor definitions and macros; it emits no machine code by itself.
;==============================================================================

; Mark the whole file's stack as non-executable so the linker/loader does not
; warn about (or create) an executable stack for our objects. NASM accepts the
; GNU property section when targeting ELF.
%macro GNU_STACK_NOTE 0
    section .note.GNU-stack noalloc noexec nowrite progbits
%endmacro

; Number of bytes in a hardware page. We only ever use it to keep speculative
; vector reads inside a single page (a 32-byte aligned read can never straddle
; a 4096-byte page because 4096 is a multiple of 32).
%define PAGE_SIZE 4096

; Convenience: size of one AVX2 vector register in bytes.
%define YMM_BYTES 32
