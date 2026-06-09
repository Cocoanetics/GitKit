#ifndef GITKIT_LIBGIT2_H
#define GITKIT_LIBGIT2_H

/*
 * GitKit's curated entry point into libgit2's public headers.
 *
 * Using a custom umbrella header (rather than SwiftPM's auto-generated
 * umbrella-*directory* module map) keeps libgit2's internal MSVC polyfill
 * `git2/stdint.h` out of the module — it is not part of the real public API
 * and only exists for VS2008-era builds, where it now collides with the
 * toolchain's own <stdint.h>.
 *
 * It also lets us apply the two Windows (MSVC / clang-cl) compatibility shims
 * that libgit2's public headers assume but the toolchain doesn't provide —
 * here, before git2.h, so the libgit2 submodule stays byte-for-byte pristine
 * and consumers inherit the fix through this module. (A cSetting `-D` doesn't
 * reach the Swift importer's module build, so it must live in a header.)
 */
#if defined(_WIN32)
#  include <stddef.h>
typedef ptrdiff_t ssize_t;       /* used by git2/sys/stream.h callback types */
#  define _MSC_STDINT_H_         /* skip libgit2's bundled <stdint.h> polyfill */
#endif

#include "git2.h"

#endif /* GITKIT_LIBGIT2_H */
