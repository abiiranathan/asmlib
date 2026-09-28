/**
 * @file asmlib_version.h
 * @brief Semantic version of the asmlib API.
 * SPDX-License-Identifier: MIT
 *
 * The version covers the public API (everything declared in the asmlib*.h
 * headers). It follows Semantic Versioning: MAJOR for incompatible API changes,
 * MINOR for backwards-compatible additions, PATCH for fixes.
 *============================================================================*/

#ifndef ASMLIB_VERSION_H
#define ASMLIB_VERSION_H

#define ASMLIB_VERSION_MAJOR 1
#define ASMLIB_VERSION_MINOR 0
#define ASMLIB_VERSION_PATCH 0

#define ASMLIB_VERSION_STRING "1.0.0"
#define ASMLIB_VERSION_NUMBER \
    ((ASMLIB_VERSION_MAJOR * 10000) + (ASMLIB_VERSION_MINOR * 100) + ASMLIB_VERSION_PATCH)

#endif /* ASMLIB_VERSION_H */
