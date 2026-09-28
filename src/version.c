/*==============================================================================
 * version.c - runtime access to the asmlib version string
 *------------------------------------------------------------------------------
 * SPDX-License-Identifier: MIT
 *============================================================================*/

#include "asmlib_version.h"

const char *asm_version(void) { return ASMLIB_VERSION_STRING; }
