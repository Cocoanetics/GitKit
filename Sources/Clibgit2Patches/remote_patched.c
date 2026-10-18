/*
 * GitKit shim — a negative fetch refspec keeps the refs it excludes out
 * of the ref updates and FETCH_HEAD, not only out of the negotiation.
 *
 * libgit2 honours a negative refspec (`^refs/heads/wip`) when it picks
 * the refs to fetch (fetch.c's filter_wants, through
 * git_remote__matching_refspec), but remote.c's update step matches every
 * advertised ref against every refspec with plain
 * git_refspec_src_matches(). So a positive refspec still updates an
 * excluded ref whenever its objects are present, and the negative refspec
 * itself, having no destination, adds the excluded ref to FETCH_HEAD. git
 * leaves the ref out of both.
 *
 * Within remote.c only, git_refspec_src_matches() is routed through
 * gitkit_refspec_src_matches(): a negative refspec never selects a ref,
 * and a ref a negative refspec of the same set excludes doesn't match —
 * the set being the fetch's refspecs, or the configured ones for the
 * opportunistic updates of a fetch given its own. Every call site has
 * the remote in scope as `remote`.
 *
 * (The same gap exists in upstream libgit2; this fix is worth offering
 * there too.)
 */
#include "remote.h"
#include "buf.h"
#include "branch.h"
#include "config.h"
#include "repository.h"
#include "fetch.h"
#include "refs.h"
#include "refspec.h"
#include "fetchhead.h"
#include "push.h"
#include "proxy.h"
#include "strarray.h"
#include "git2/config.h"
#include "git2/types.h"
#include "git2/oid.h"
#include "git2/net.h"
#include "git2/refspec.h"
#include "transports/smart.h"

static int gitkit_refspec_src_matches(
	const git_remote *remote, const git_refspec *spec, const char *refname);

#define git_refspec_src_matches(spec, refname) \
	gitkit_refspec_src_matches(remote, spec, refname)
#include "remote.c"
#undef git_refspec_src_matches

static int gitkit_refspec_src_matches(
	const git_remote *remote, const git_refspec *spec, const char *refname)
{
	const git_vector *set = &remote->active_refspecs;
	const git_refspec *other;
	size_t i;

	if (git_refspec_is_negative(spec) || !git_refspec_src_matches(spec, refname))
		return 0;

	git_vector_foreach(&remote->passive_refspecs, i, other) {
		if (other == spec) {
			set = &remote->passive_refspecs;
			break;
		}
	}

	git_vector_foreach(set, i, other) {
		if (!other->push && git_refspec_src_matches_negative(other, refname))
			return 0;
	}

	return 1;
}
