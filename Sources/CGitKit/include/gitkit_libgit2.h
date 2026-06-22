#ifndef GITKIT_LIBGIT2_H
#define GITKIT_LIBGIT2_H

/*
 * GitKit's curated entry point into libgit2's public headers.
 *
 * A custom umbrella header (rather than SwiftPM's auto-generated
 * umbrella-*directory* module map) lets us apply the two Windows (MSVC /
 * clang-cl) compatibility shims that libgit2's public headers assume but the
 * toolchain doesn't provide — here, before git2.h, so the libgit2 submodule
 * stays byte-for-byte pristine and consumers inherit the fix through this
 * module. (A cSetting `-D` doesn't reach the Swift importer's module build, so
 * it must live in a header.)
 *
 * The trade-off of a custom umbrella is that it only exposes headers it
 * explicitly #includes, so the public headers git2.h doesn't pull in are
 * listed by hand below: git2/cred_helpers.h and the git2/sys backend tree.
 * Without the explicit cred_helpers.h include Clang would flag it as an
 * uncovered umbrella header (-Wincomplete-umbrella).
 *
 * git2.h and the git2/ tree are vendored alongside this umbrella (see
 * Scripts/update-libgit2.sh); SwiftPM's C-module build only searches this
 * target's publicHeadersPath, never cSettings header paths. That script also
 * drops libgit2's git2/stdint.h from the vendored tree — an MSVC <stdint.h>
 * polyfill for VS2008-era builds, not real public API — so it isn't left
 * behind as an uncovered umbrella header either.
 */
#if defined(_WIN32)
#  include <stddef.h>
typedef ptrdiff_t ssize_t;       /* used by git2/sys/stream.h callback types */
#  define _MSC_STDINT_H_         /* skip libgit2's bundled <stdint.h> polyfill */
#endif

#include "git2.h"

/*
 * git2/cred_helpers.h is a deprecated top-level forwarding header — its
 * git_credential_userpass helper now lives in git2/credential_helpers.h (which
 * git2.h already reaches via git2/deprecated.h). git2.h doesn't include the
 * shim itself, so pull it in here to keep it under the umbrella.
 */
#include "git2/cred_helpers.h"

/*
 * The "sys" (backend / plugin) API. git2.h does NOT include these, but
 * consumers use complete types from them (e.g. git_config_iterator); a custom
 * umbrella won't expose them unless they're listed. Regenerated from the
 * vendored git2/sys headers by Scripts/update-libgit2.sh.
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
