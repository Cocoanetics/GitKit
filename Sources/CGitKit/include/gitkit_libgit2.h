#ifndef GITKIT_LIBGIT2_H
#define GITKIT_LIBGIT2_H

/*
 * GitKit's curated entry point into libgit2's public headers.
 *
 * Using a custom umbrella header (rather than SwiftPM's auto-generated
 * umbrella-*directory* module map) keeps libgit2's internal MSVC polyfill
 * `git2/stdint.h` out of the module — it is not part of the real public API
 * and only exists for VS2008-era builds, where it collides with the toolchain's
 * own <stdint.h>.
 *
 * It also lets us apply the two Windows (MSVC / clang-cl) compatibility shims
 * that libgit2's public headers assume but the toolchain doesn't provide —
 * here, before git2.h, so the libgit2 submodule stays byte-for-byte pristine
 * and consumers inherit the fix through this module. (A cSetting `-D` doesn't
 * reach the Swift importer's module build, so it must live in a header.)
 *
 * git2.h and the git2/ tree are vendored alongside this umbrella (see
 * Scripts/update-libgit2.sh); SwiftPM's C-module build only searches this
 * target's publicHeadersPath, never cSettings header paths.
 */
#if defined(_WIN32)
#  include <stddef.h>
typedef ptrdiff_t ssize_t;       /* used by git2/sys/stream.h callback types */
#  define _MSC_STDINT_H_         /* skip libgit2's bundled <stdint.h> polyfill */
#endif

#include "git2.h"

/*
 * The "sys" (backend / plugin) API. git2.h does NOT include these, but
 * consumers use complete types from them (e.g. git_config_iterator). The
 * auto umbrella-directory map would pull them in for free — but it would also
 * pull git2/stdint.h, hence this explicit list. Regenerated from the vendored
 * git2/sys/*.h by Scripts/update-libgit2.sh.
 */
/* BEGIN sys */
#include "git2/sys/alloc.h"
#include "git2/sys/commit.h"
#include "git2/sys/commit_graph.h"
#include "git2/sys/config.h"
#include "git2/sys/cred.h"
#include "git2/sys/credential.h"
#include "git2/sys/diff.h"
#include "git2/sys/email.h"
#include "git2/sys/errors.h"
#include "git2/sys/filter.h"
#include "git2/sys/hashsig.h"
#include "git2/sys/index.h"
#include "git2/sys/mempack.h"
#include "git2/sys/merge.h"
#include "git2/sys/midx.h"
#include "git2/sys/odb_backend.h"
#include "git2/sys/openssl.h"
#include "git2/sys/path.h"
#include "git2/sys/refdb_backend.h"
#include "git2/sys/refs.h"
#include "git2/sys/remote.h"
#include "git2/sys/repository.h"
#include "git2/sys/stream.h"
#include "git2/sys/transport.h"
/* END sys */

#endif /* GITKIT_LIBGIT2_H */
