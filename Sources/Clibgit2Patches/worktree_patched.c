/*
 * GitKit shim — roll back what a failed git_worktree_add() provably made.
 *
 * git_worktree_add() rolls nothing back when it fails part way: the new
 * worktree's private git directory and working directory, its `.git` file,
 * `commondir`, `gitdir` and `HEAD` stay — for example when its own open of
 * the new worktree fails because the config load refuses an include. Its
 * caller can't tell whether this add made them: an error from before the
 * directories exist (a branch checked out elsewhere, a directory another
 * writer made first) reads like one from after.
 *
 * The add makes both directories exclusively (GIT_MKDIR_EXCL), writes those
 * four files, then opens the new worktree with git_repository_open() — its
 * only open, and the first point after making them where host code (the
 * include policy, a filter in the checkout) runs. Within worktree.c only, git_repository_create_head()
 * records the git directory it writes `HEAD` to, and the open is routed
 * through gitkit_worktree_add_open(), which records, before opening, the
 * identity of both directories and the four files. gitkit_worktree_add()
 * then removes, on failure, exactly those, if they are unchanged and
 * nothing else is in either directory (created_dir.c); otherwise it keeps
 * both.
 */
#include "repository.h"
#include "gitkit_created_dir.h"

#if defined(_MSC_VER)
#  define GITKIT_THREAD_LOCAL __declspec(thread)
#else
#  define GITKIT_THREAD_LOCAL __thread
#endif

typedef struct {
	int opened;
	git_str gitdir;
	gitkit_file_id workdir_id, gitdir_id;
	gitkit_file_id dotgit_id, commondir_id, gitdir_file_id, head_id;
} gitkit_worktree_add_state;

static GITKIT_THREAD_LOCAL gitkit_worktree_add_state *gitkit_worktree_add_current;

static int gitkit_worktree_add_create_head(const char *git_dir, const char *ref_name)
{
	if (gitkit_worktree_add_current)
		git_str_sets(&gitkit_worktree_add_current->gitdir, git_dir);
	return git_repository_create_head(git_dir, ref_name);
}

static void gitkit_record(gitkit_file_id *out, const char *dir, const char *name)
{
	git_str path = GIT_STR_INIT;

	memset(out, 0, sizeof(*out));
	if (git_str_joinpath(&path, dir, name) == 0)
		gitkit_created_id(out, path.ptr);
	git_str_dispose(&path);
}

static int gitkit_worktree_add_open(git_repository **out, const char *path)
{
	gitkit_worktree_add_state *state = gitkit_worktree_add_current;

	if (state && git_str_len(&state->gitdir) > 0) {
		state->opened = 1;
		gitkit_created_id(&state->workdir_id, path);
		gitkit_record(&state->dotgit_id, path, ".git");
		gitkit_created_id(&state->gitdir_id, state->gitdir.ptr);
		gitkit_record(&state->commondir_id, state->gitdir.ptr, "commondir");
		gitkit_record(&state->gitdir_file_id, state->gitdir.ptr, "gitdir");
		gitkit_record(&state->head_id, state->gitdir.ptr, "HEAD");
	}
	return git_repository_open(out, path);
}

#define git_repository_create_head gitkit_worktree_add_create_head
#define git_repository_open gitkit_worktree_add_open
#include "worktree.c"
#undef git_repository_open
#undef git_repository_create_head

/* Removes both directories, or neither. */
static int gitkit_worktree_add_roll_back(
	gitkit_worktree_add_state *state, const char *worktree)
{
	const gitkit_created_entry workdir[] = {
		{ ".git", 0, &state->dotgit_id },
	};
	const gitkit_created_entry gitdir[] = {
		{ "commondir", 0, &state->commondir_id },
		{ "gitdir", 0, &state->gitdir_file_id },
		{ "HEAD", 0, &state->head_id },
	};
	const gitkit_created_dir dirs[] = {
		{ worktree, &state->workdir_id, workdir, ARRAY_SIZE(workdir) },
		{ state->gitdir.ptr, &state->gitdir_id, gitdir, ARRAY_SIZE(gitdir) },
	};

	return gitkit_remove_created_dirs(dirs, ARRAY_SIZE(dirs)) == GITKIT_CREATED_REMOVED
		? GITKIT_WORKTREE_ADD_REMOVED
		: GITKIT_WORKTREE_ADD_KEPT;
}

int gitkit_worktree_add(
	git_worktree **out, git_repository *repo,
	const char *name, const char *worktree,
	const git_worktree_add_options *opts, int *made)
{
	gitkit_worktree_add_state state = { 0 };
	gitkit_worktree_add_state *previous = gitkit_worktree_add_current;
	int error, result = GITKIT_WORKTREE_ADD_NOT_MADE;

	git_str_init(&state.gitdir, 0);
	gitkit_worktree_add_current = &state;
	error = git_worktree_add(out, repo, name, worktree, opts);
	gitkit_worktree_add_current = previous;

	if (state.opened)
		result = error < 0
			? gitkit_worktree_add_roll_back(&state, worktree)
			: GITKIT_WORKTREE_ADD_KEPT;
	if (made)
		*made = result;
	git_str_dispose(&state.gitdir);
	return error;
}
