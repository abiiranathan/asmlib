# Assemble the x86-64 backend.
#
# This lives in its own directory on purpose: a custom command's build rule is
# emitted into the targets of the directory that defines it. Keeping the
# generation here means it runs once and is shared by the static, shared and
# scalar libraries, instead of being re-emitted (and raced) for each target.

set(_gen "${CMAKE_CURRENT_BINARY_DIR}/obj")

# The non-dispatched assembly modules.
set(_core alloc arena cpu ctype format scan sys)
# The AVX2 memory/string/comparison/search modules, symbols prefixed asm_avx2_.
set(_hot memory string strcmp search)

set(ASMLIB_ASM_OBJS "")
foreach(_m IN LISTS _core)
    set(_o "${_gen}/${_m}.o")
    add_custom_command(OUTPUT "${_o}"
        COMMAND ${CMAKE_COMMAND} -E make_directory "${_gen}"
        COMMAND ${ASMLIB_NASM} ${ASMLIB_NASM_FLAGS} -o "${_o}"
                "${PROJECT_SOURCE_DIR}/src/${_m}.asm"
        DEPENDS "${PROJECT_SOURCE_DIR}/src/${_m}.asm"
                "${PROJECT_SOURCE_DIR}/src/common.inc"
        COMMENT "Assembling src/${_m}.asm"
        VERBATIM)
    list(APPEND ASMLIB_ASM_OBJS "${_o}")
endforeach()

foreach(_m IN LISTS _hot)
    set(_raw "${_gen}/avx2/${_m}.raw.o")
    set(_o   "${_gen}/avx2/${_m}.o")
    add_custom_command(OUTPUT "${_o}"
        COMMAND ${CMAKE_COMMAND} -E make_directory "${_gen}/avx2"
        COMMAND ${ASMLIB_NASM} ${ASMLIB_NASM_FLAGS} -o "${_raw}"
                "${PROJECT_SOURCE_DIR}/src/${_m}.asm"
        COMMAND ${ASMLIB_OBJCOPY} --prefix-symbols=asm_avx2_ "${_raw}" "${_o}"
        DEPENDS "${PROJECT_SOURCE_DIR}/src/${_m}.asm"
                "${PROJECT_SOURCE_DIR}/src/common.inc"
        COMMENT "Assembling src/${_m}.asm (AVX2, asm_avx2_ prefix)"
        VERBATIM)
    list(APPEND ASMLIB_ASM_OBJS "${_o}")
endforeach()

# The three core objects the scalar archive also needs.
set(ASMLIB_ASM_SCALAR_OBJS
    "${_gen}/arena.o" "${_gen}/ctype.o" "${_gen}/cpu.o")

set(ASMLIB_ASMGEN_TARGET asmlib_asmgen)
add_custom_target(${ASMLIB_ASMGEN_TARGET} DEPENDS ${ASMLIB_ASM_OBJS})

set(ASMLIB_ASM_OBJS "${ASMLIB_ASM_OBJS}" PARENT_SCOPE)
set(ASMLIB_ASM_SCALAR_OBJS "${ASMLIB_ASM_SCALAR_OBJS}" PARENT_SCOPE)
set(ASMLIB_ASMGEN_TARGET "${ASMLIB_ASMGEN_TARGET}" PARENT_SCOPE)
