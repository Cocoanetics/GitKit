/*
 * GitKit shim — a negative fetch refspec keeps the refs it excludes out
 * of the ref updates, FETCH_HEAD and pruning, not only out of the
 * negotiation; and an explicit refspec for a tag is honoured.
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
 * opportunistic updates of a fetch given its own. A refspec of neither
 * set, like the tag auto-following probe, matches as before: as in git,
 * negative refspecs don't stop a tag from being followed.
 *
 * The tag auto-following probe in update_one_tip() claims every tag
 * before the refspec being applied gets a look, so an explicit
 * `refs/tags/v1:refs/custom/x` (or `+refs/tags/*:refs/tags/*`) was never
 * applied. The probe now gives way when that refspec maps the tag itself.
 *
 * git_remote_prune() keeps a remote-tracking ref when it finds the
 * remote ref the ref stands for (its one git_vector_bsearch() call);
 * a remote ref a negative refspec excludes counts as found, so, as in
 * git, pruning leaves its tracking ref alone.
 *
 * Every call site of both has the remote in scope as `remote`, and the
 * refspec being applied as `spec`.
 *
 * Reported upstream as libgit2/libgit2#7435 and #7438.
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
	const git_remote *remote, const git_refspec *current,
	const git_refspec *spec, const char *refname);
static int gitkit_prune_bsearch(
	const git_remote *remote, size_t *at_pos, git_vector *v, const void *key);

#define git_refspec_src_matches(probe, refname) \
	gitkit_refspec_src_matches(remote, spec, probe, refname)
#define git_vector_bsearch(at_pos, v, key) \
	gitkit_prune_bsearch(remote, at_pos, v, key)
#include "remote.c"
#undef git_vector_bsearch
#undef git_refspec_src_matches

static int gitkit_prune_bsearch(
	const git_remote *remote, size_t *at_pos, git_vector *v, const void *key)
{
	const git_remote_head *head = key;
	const git_refspec *spec;
	size_t i;

	git_vector_foreach(&remote->active_refspecs, i, spec) {
		if (!spec->push && git_refspec_src_matches_negative(spec, head->name))
			return 0;
	}
	return git_vector_bsearch(at_pos, v, key);
}

static const git_vector *gitkit_refspec_set(const git_remote *remote, const git_refspec *spec)
{
	const git_refspec *member;
	size_t i;

	git_vector_foreach(&remote->passive_refspecs, i, member) {
		if (member == spec)
			return &remote->passive_refspecs;
	}
	git_vector_foreach(&remote->active_refspecs, i, member) {
		if (member == spec)
			return &remote->active_refspecs;
	}
	return NULL;
}

static int gitkit_refspec_src_matches(
	const git_remote *remote, const git_refspec *current,
	const git_refspec *spec, const char *refname)
{
	const git_vector *set;
	const git_refspec *other;
	size_t i;

	if (git_refspec_is_negative(spec) || !git_refspec_src_matches(spec, refname))
		return 0;

	/*
	 * Not a refspec of the fetch's: the tag auto-following probe. It
	 * leaves a tag to the refspec being applied when that one maps it.
	 */
	if ((set = gitkit_refspec_set(remote, spec)) == NULL)
		return !(current && current != spec && gitkit_refspec_set(remote, current) &&
			 !current->push && !git_refspec_is_negative(current) &&
			 current->dst && *current->dst &&
			 git_refspec_src_matches(current, refname));

	git_vector_foreach(set, i, other) {
		if (!other->push && git_refspec_src_matches_negative(other, refname))
			return 0;
	}

	return 1;
}
