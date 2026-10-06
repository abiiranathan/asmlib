#==============================================================================
# CMakeLists.txt - CMake build for the asmlib library
#------------------------------------------------------------------------------
# Builds the same artifacts as the top-level Makefile for the host architecture:
#
#   x86-64   libasmlib.a, libasmlib.so   (AVX2 + scalar dispatch)
#            libasmlib_scalar.a          (portable scalar fallback)
#   AArch64  libasmlib.a, libasmlib.so   (NEON, single native implementation)
#            libasmlib_scalar.a          (portable C backend)
#
# and installs the headers, a relocatable pkg-config file, and a CMake package so
# consumers can use find_package(asmlib) + asmlib::asmlib.
#
#   cmake -S . -B build-cmake
#   cmake --build build-cmake
#   cmake --install build-cmake --prefix /usr/local
#
# Cross-compiling to AArch64:
#   cmake -S . -B build-aarch64 \
#         -DCMAKE_TOOLCHAIN_FILE=cmake/toolchain-aarch64.cmake
#
# The test suite, wasm and fuzzing targets stay on `make`.
#==============================================================================

cmake_minimum_required(VERSION 3.16)

project(asmlib
    VERSION 1.0.0
    DESCRIPTION "Hand-written x86-64 (AVX2/BMI2) and AArch64 (NEON) assembly libc subset"
    HOMEPAGE_URL "https://github.com/abiiranathan/asmlib"
    LANGUAGES C ASM)

include(GNUInstallDirs)
include(CMakePackageConfigHelpers)

# The version of record is the header; keep CMake and the library in step.
file(STRINGS "${CMAKE_CURRENT_SOURCE_DIR}/include/asmlib_version.h" _asmlib_ver
     REGEX "^#define ASMLIB_VERSION_STRING ")
string(REGEX MATCH "\"([0-9]+\\.[0-9]+\\.[0-9]+)\"" _asmlib_ver_match "${_asmlib_ver}")
if(CMAKE_MATCH_1)
    set(ASMLIB_VERSION "${CMAKE_MATCH_1}")
else()
    set(ASMLIB_VERSION "${PROJECT_VERSION}")
endif()

# ---- options -----------------------------------------------------------------
option(ASMLIB_BUILD_SHARED "Build the shared library (libasmlib.so)" ON)
option(ASMLIB_BUILD_STATIC "Build the static library (libasmlib.a)" ON)
option(ASMLIB_BUILD_SCALAR "Build the scalar fallback library (libasmlib_scalar.a)" ON)

# Install rules default on when this is the top-level project, off when it is
# consumed via add_subdirectory() (a parent project can opt in).
if(CMAKE_SOURCE_DIR STREQUAL CMAKE_CURRENT_SOURCE_DIR)
    set(_asmlib_top_level ON)
else()
    set(_asmlib_top_level OFF)
endif()
option(ASMLIB_INSTALL "Generate install and package-config rules" ${_asmlib_top_level})

if(NOT ASMLIB_BUILD_SHARED AND NOT ASMLIB_BUILD_STATIC)
    message(FATAL_ERROR "asmlib: enable at least one of ASMLIB_BUILD_SHARED / ASMLIB_BUILD_STATIC")
endif()

# ---- architecture ------------------------------------------------------------
# asmlib ships two hand-written backends behind the same asm_* API (x86-64 via
# NASM, AArch64 via GNU as). Select one; the portable C backend is the wasm
# build and stays on the Makefile.
if(CMAKE_SYSTEM_PROCESSOR MATCHES "^(x86_64|amd64|AMD64)$")
    set(ASMLIB_ARCH "x86_64")
elseif(CMAKE_SYSTEM_PROCESSOR MATCHES "^(aarch64|arm64|ARM64)$")
    set(ASMLIB_ARCH "aarch64")
else()
    message(FATAL_ERROR
        "asmlib's CMake build supports x86-64 and AArch64 (got "
        "${CMAKE_SYSTEM_PROCESSOR}).\n"
        "Use `make wasm` for the portable wasm32 backend.")
endif()
message(STATUS "asmlib: building the ${ASMLIB_ARCH} backend")

# ---- common C libraries (all architectures) ----------------------------------
set(ASMLIB_LIBC_CFLAGS -std=c11 -ffreestanding -fno-builtin -fno-stack-protector -Wall -Wextra)
set(ASMLIB_MATH_CFLAGS -std=c11 -ffreestanding -fno-builtin -ffp-contract=off
                       -fno-stack-protector -fno-math-errno -Wall -Wextra)
set(_asmlib_cflags -O2 -Wall -Wextra)

add_library(asmlib_version OBJECT src/version.c)
target_include_directories(asmlib_version PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/include")
target_compile_options(asmlib_version PRIVATE ${_asmlib_cflags})
set_target_properties(asmlib_version PROPERTIES POSITION_INDEPENDENT_CODE ON)

file(GLOB ASMLIB_MATH_SOURCES CONFIGURE_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/src/math/*.c")
add_library(asmlib_math OBJECT ${ASMLIB_MATH_SOURCES})
target_include_directories(asmlib_math PRIVATE
    "${CMAKE_CURRENT_SOURCE_DIR}/include" "${CMAKE_CURRENT_SOURCE_DIR}/src/math")
target_compile_options(asmlib_math PRIVATE ${ASMLIB_MATH_CFLAGS})
set_target_properties(asmlib_math PROPERTIES POSITION_INDEPENDENT_CODE ON)

# Portable C backend, used for the scalar archive on every architecture.
file(GLOB ASMLIB_LIBC_SOURCES CONFIGURE_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/src/libc/*.c")
add_library(asmlib_scalar_objs OBJECT ${ASMLIB_LIBC_SOURCES})
target_include_directories(asmlib_scalar_objs PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/src/libc")
target_compile_options(asmlib_scalar_objs PRIVATE ${ASMLIB_LIBC_CFLAGS})
set_target_properties(asmlib_scalar_objs PROPERTIES POSITION_INDEPENDENT_CODE ON)

# Shared portable C engine linked into the native libraries: the full printf
# family (src/libc/printf.c), qsort/bsearch (src/libc/sort.c) and the fd output
# layer (src/dprintf.c). Kept separate from the scalar objects so the hand-written
# integer formatters in the assembly backends are not shadowed.
add_library(asmlib_engine OBJECT
    src/libc/printf.c
    src/libc/sort.c
    src/dprintf.c)
target_include_directories(asmlib_engine PRIVATE
    "${CMAKE_CURRENT_SOURCE_DIR}/include" "${CMAKE_CURRENT_SOURCE_DIR}/src/libc")
target_compile_options(asmlib_engine PRIVATE ${ASMLIB_LIBC_CFLAGS})
set_target_properties(asmlib_engine PROPERTIES POSITION_INDEPENDENT_CODE ON)

# ---- architecture backend ----------------------------------------------------
set(ASMLIB_EXTRA_ITEMS "")     # arch-specific objects for the main library
set(ASMLIB_COMMON_ASM "")      # arena/ctype/cpu, shared with the scalar archive
set(ASMLIB_DEP_TARGETS "")     # targets that must build first

if(ASMLIB_ARCH STREQUAL "x86_64")
    find_program(ASMLIB_NASM nasm REQUIRED
        DOC "NASM assembler (2.14+; used for the x86-64 backend)")
    find_program(ASMLIB_OBJCOPY objcopy REQUIRED
        DOC "objcopy (binutils; used to prefix the AVX2 symbols)")

    set(ASMLIB_NASM_FLAGS -f elf64 -I "${CMAKE_CURRENT_SOURCE_DIR}/src/"
                          -g -F dwarf -Wall -w-reloc-rel-dword)

    # Assembled in its own directory so the generation rule lives in one scope
    # and runs once for every consumer.
    add_subdirectory("${CMAKE_CURRENT_SOURCE_DIR}/cmake/asmgen"
                     "${CMAKE_CURRENT_BINARY_DIR}/asmgen")
    set_source_files_properties(${ASMLIB_ASM_OBJS} PROPERTIES GENERATED TRUE)

    # Scalar half of the dispatched surface: the portable mem/str routines
    # renamed asm_scalar_* so dispatch can tell them from the AVX2 copies.
    add_library(asmlib_hot_scalar OBJECT src/libc/mem.c src/libc/str.c)
    target_compile_definitions(asmlib_hot_scalar PRIVATE ASMLIB_LIBC_SCALAR_PREFIX)
    target_include_directories(asmlib_hot_scalar PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/src/libc")
    target_compile_options(asmlib_hot_scalar PRIVATE ${ASMLIB_LIBC_CFLAGS})
    set_target_properties(asmlib_hot_scalar PROPERTIES POSITION_INDEPENDENT_CODE ON)

    # Dispatch resolves each hot symbol to AVX2 or scalar (ELF IFUNC).
    add_library(asmlib_dispatch OBJECT src/dispatch_ifunc.c)
    target_include_directories(asmlib_dispatch PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/include")
    target_compile_options(asmlib_dispatch PRIVATE ${_asmlib_cflags})
    set_target_properties(asmlib_dispatch PROPERTIES POSITION_INDEPENDENT_CODE ON)

    set(ASMLIB_EXTRA_ITEMS
        $<TARGET_OBJECTS:asmlib_hot_scalar>
        $<TARGET_OBJECTS:asmlib_dispatch>
        ${ASMLIB_ASM_OBJS})
    set(ASMLIB_COMMON_ASM ${ASMLIB_ASM_SCALAR_OBJS})
    set(ASMLIB_DEP_TARGETS ${ASMLIB_ASMGEN_TARGET})

elseif(ASMLIB_ARCH STREQUAL "aarch64")
    # The AArch64 backend is a single native implementation (NEON is baseline);
    # no dispatch and no scalar counterpart are needed.
    set(_a64_dir "${CMAKE_CURRENT_SOURCE_DIR}/src/aarch64")
    set(_a64_common
        "${_a64_dir}/arena.S" "${_a64_dir}/ctype.S" "${_a64_dir}/cpu.S")
    set(_a64_rest
        "${_a64_dir}/alloc.S" "${_a64_dir}/format.S" "${_a64_dir}/memory.S"
        "${_a64_dir}/scan.S" "${_a64_dir}/search.S" "${_a64_dir}/strcmp.S"
        "${_a64_dir}/string.S" "${_a64_dir}/sys.S")

    add_library(asmlib_a64_common OBJECT ${_a64_common})
    target_include_directories(asmlib_a64_common PRIVATE "${_a64_dir}")
    set_target_properties(asmlib_a64_common PROPERTIES POSITION_INDEPENDENT_CODE ON)

    add_library(asmlib_a64_rest OBJECT ${_a64_rest})
    target_include_directories(asmlib_a64_rest PRIVATE "${_a64_dir}")
    set_target_properties(asmlib_a64_rest PROPERTIES POSITION_INDEPENDENT_CODE ON)

    set(ASMLIB_EXTRA_ITEMS $<TARGET_OBJECTS:asmlib_a64_rest>)
    set(ASMLIB_COMMON_ASM $<TARGET_OBJECTS:asmlib_a64_common>)
endif()

# ---- the library -------------------------------------------------------------
set(ASMLIB_MAIN_ITEMS
    $<TARGET_OBJECTS:asmlib_version>
    $<TARGET_OBJECTS:asmlib_math>
    $<TARGET_OBJECTS:asmlib_engine>
    ${ASMLIB_COMMON_ASM}
    ${ASMLIB_EXTRA_ITEMS})

set(_asmlib_public_include
    "$<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>"
    "$<INSTALL_INTERFACE:${CMAKE_INSTALL_INCLUDEDIR}>")

set(ASMLIB_EXPORT_TARGETS "")

if(ASMLIB_BUILD_SHARED)
    add_library(asmlib SHARED ${ASMLIB_MAIN_ITEMS})
    set_target_properties(asmlib PROPERTIES OUTPUT_NAME asmlib)
    target_include_directories(asmlib PUBLIC ${_asmlib_public_include})
    if(ASMLIB_DEP_TARGETS)
        add_dependencies(asmlib ${ASMLIB_DEP_TARGETS})
    endif()
    if(UNIX AND NOT APPLE)
        target_link_options(asmlib PRIVATE -Wl,-Bsymbolic)
    endif()
    add_library(asmlib::asmlib ALIAS asmlib)
    list(APPEND ASMLIB_EXPORT_TARGETS asmlib)
endif()

if(ASMLIB_BUILD_STATIC)
    add_library(asmlib_static STATIC ${ASMLIB_MAIN_ITEMS})
    set_target_properties(asmlib_static PROPERTIES OUTPUT_NAME asmlib)
    target_include_directories(asmlib_static PUBLIC ${_asmlib_public_include})
    if(ASMLIB_DEP_TARGETS)
        add_dependencies(asmlib_static ${ASMLIB_DEP_TARGETS})
    endif()
    add_library(asmlib::asmlib_static ALIAS asmlib_static)
    list(APPEND ASMLIB_EXPORT_TARGETS asmlib_static)
endif()

# ---- scalar fallback library -------------------------------------------------
if(ASMLIB_BUILD_SCALAR)
    add_library(asmlib_scalar STATIC
        $<TARGET_OBJECTS:asmlib_scalar_objs>
        $<TARGET_OBJECTS:asmlib_math>
        ${ASMLIB_COMMON_ASM})
    set_target_properties(asmlib_scalar PROPERTIES OUTPUT_NAME asmlib_scalar)
    target_include_directories(asmlib_scalar PUBLIC ${_asmlib_public_include})
    if(ASMLIB_DEP_TARGETS)
        add_dependencies(asmlib_scalar ${ASMLIB_DEP_TARGETS})
    endif()
    add_library(asmlib::asmlib_scalar ALIAS asmlib_scalar)
    list(APPEND ASMLIB_EXPORT_TARGETS asmlib_scalar)
endif()

# ---- install + package config ------------------------------------------------
if(ASMLIB_INSTALL)
    install(TARGETS ${ASMLIB_EXPORT_TARGETS}
        EXPORT asmlibTargets
        ARCHIVE DESTINATION "${CMAKE_INSTALL_LIBDIR}"
        LIBRARY DESTINATION "${CMAKE_INSTALL_LIBDIR}"
        RUNTIME DESTINATION "${CMAKE_INSTALL_BINDIR}"
        INCLUDES DESTINATION "${CMAKE_INSTALL_INCLUDEDIR}")

    install(DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/include/"
        DESTINATION "${CMAKE_INSTALL_INCLUDEDIR}"
        FILES_MATCHING PATTERN "*.h")

    # pkg-config (relocatable; see cmake/asmlib.pc.in).
    configure_file("${CMAKE_CURRENT_SOURCE_DIR}/cmake/asmlib.pc.in"
                   "${CMAKE_CURRENT_BINARY_DIR}/asmlib.pc" @ONLY)
    install(FILES "${CMAKE_CURRENT_BINARY_DIR}/asmlib.pc"
        DESTINATION "${CMAKE_INSTALL_LIBDIR}/pkgconfig")

    # CMake package: asmlib::asmlib, asmlib::asmlib_static, asmlib::asmlib_scalar.
    install(EXPORT asmlibTargets
        NAMESPACE asmlib::
        FILE asmlibTargets.cmake
        DESTINATION "${CMAKE_INSTALL_LIBDIR}/cmake/asmlib")

    configure_package_config_file(
        "${CMAKE_CURRENT_SOURCE_DIR}/cmake/asmlibConfig.cmake.in"
        "${CMAKE_CURRENT_BINARY_DIR}/asmlibConfig.cmake"
        INSTALL_DESTINATION "${CMAKE_INSTALL_LIBDIR}/cmake/asmlib")
    write_basic_package_version_file(
        "${CMAKE_CURRENT_BINARY_DIR}/asmlibConfigVersion.cmake"
        VERSION "${ASMLIB_VERSION}"
        COMPATIBILITY SameMajorVersion)

    install(FILES
        "${CMAKE_CURRENT_BINARY_DIR}/asmlibConfig.cmake"
        "${CMAKE_CURRENT_BINARY_DIR}/asmlibConfigVersion.cmake"
        DESTINATION "${CMAKE_INSTALL_LIBDIR}/cmake/asmlib")
endif()
