/*
 * GitKit shim — how far a failed git_worktree_add() got.
 *
 * git_worktree_add() rolls nothing back when it fails part way: the new
 * worktree's private git directory and working directory, its `.git` file
 * and `HEAD` stay. Its caller can only remove them if this add made them,
 * and the error doesn't say: one from before the directories are made
 * (a branch checked out elsewhere, a directory another writer made first)
 * reads like one from after.
 *
 * The add makes both directories exclusively (GIT_MKDIR_EXCL), then writes
 * their files, then opens the new worktree with git_repository_open() — its
 * only open. Within worktree.c only, that open is routed through
 * gitkit_worktree_add_open(), which records that it was reached;
 * gitkit_worktree_add() reports it. Reached means this add made both
 * directories and everything in them so far, so its caller may prune them.
 */
#include "repository.h"
#include "../CGitKit/include/gitkit_libgit2.h"

#if defined(_MSC_VER)
#  define GITKIT_THREAD_LOCAL __declspec(thread)
#else
#  define GITKIT_THREAD_LOCAL __thread
#endif

static GITKIT_THREAD_LOCAL int gitkit_worktree_add_opened;

static int gitkit_worktree_add_open(git_repository **out, const char *path)
{
	gitkit_worktree_add_opened = 1;
	return git_repository_open(out, path);
}

#define git_repository_open gitkit_worktree_add_open
#include "worktree.c"
#undef git_repository_open

int gitkit_worktree_add(
	git_worktree **out, git_repository *repo,
	const char *name, const char *worktree,
	const git_worktree_add_options *opts, int *created)
{
	int error;

	gitkit_worktree_add_opened = 0;
	error = git_worktree_add(out, repo, name, worktree, opts);
	if (created)
		*created = gitkit_worktree_add_opened;
	gitkit_worktree_add_opened = 0;
	return error;
}
