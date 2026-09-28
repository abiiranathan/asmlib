# CMake toolchain file for cross-building the AArch64 backend.
#
#   cmake -S . -B build-aarch64 -DCMAKE_TOOLCHAIN_FILE=cmake/toolchain-aarch64.cmake
#   cmake --build build-aarch64
#
# Override the compiler with -DASMLIB_AARCH64_CC=/path/to/aarch64-gcc if needed.
# Configure a prefix/sysroot with CMAKE_FIND_ROOT_PATH when cross-linking.

set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR aarch64)

if(NOT DEFINED ASMLIB_AARCH64_CC)
    set(ASMLIB_AARCH64_CC aarch64-linux-gnu-gcc)
endif()

set(CMAKE_C_COMPILER   ${ASMLIB_AARCH64_CC})
set(CMAKE_ASM_COMPILER ${ASMLIB_AARCH64_CC})

set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
