/*
 * GitKit shim — an operation's config levels for every repository a thread
 * opens, including the ones libgit2 opens internally.
 *
 * libgit2 opens repositories of its own in the middle of an operation:
 * submodule status and diff open each child (submodule.c's
 * git_submodule__open()), as do submodule sync and update, staging a
 * gitlink, worktree checks and a local clone or fetch. Such a handle reads
 * its config from the process's search paths, so levels a host added to
 * the repository it opened (git_config_add_backend()) never reach it, and
 * the child is hashed, filtered and compared under a config git would not
 * have used. Worse, libgit2 clears the error of a child it fails to open
 * and reports the child as changed.
 *
 * Every open builds its config in one place, load_config(), before
 * anything derived from the config (format checks, `core.*` cache, index
 * capabilities, filters, attributes) exists. Within repository.c only:
 *
 *  • git_config_add_file_ondisk() is routed through
 *    gitkit_repository_add_file(), which skips a search-path file whose
 *    level the calling thread's scope replaces — that file is never read,
 *    nor are its includes, as git reads no ~/.gitconfig under
 *    GIT_CONFIG_GLOBAL — and records a failure to read the others;
 *  • load_config()'s one git_config_set_writeorder() call, made once every
 *    file is added and before the config is handed out, is routed through
 *    gitkit_repository_finish_config(), which adds the scope's levels
 *    (forcing out whatever the level held), then sets the write order the
 *    open asked for: the repository's own config file only.
 *
 * With no scope on the calling thread both behave exactly as before. A
 * scope is pushed and popped by the thread it belongs to (LIFO, so a
 * nested scope restores the outer one) and holds only copies — a file's
 * path, an entries level's text — so no caller memory is lent to libgit2;
 * each load reads the file and parses the text again into backends the
 * config owns.
 *
 * A failure to read a level while a scope is active (a refused include —
 * recorded where it is refused, config_file_patched.c — an unreadable or
 * unparsable file, an entries level that doesn't parse) is recorded in the
 * scope, because the open that hit it may be one libgit2 swallows. The
 * scope's owner reports the first one libgit2 did not hand back to it.
 *
 * Not covered: configs libgit2 builds with git_config_open_default()
 * (config.c), which does not go through load_config(): the template
 * directory and initial branch of an init, and the config of a detached
 * remote.
 */
#include "repository.h"
#include "git2/object.h"
#include "git2/sys/repository.h"
#include "git2/sys/config.h"
#include "buf.h"
#include "common.h"
#include "commit.h"
#include "grafts.h"
#include "tag.h"
#include "blob.h"
#include "futils.h"
#include "sysdir.h"
#include "filebuf.h"
#include "index.h"
#include "config.h"
#include "refs.h"
#include "filter.h"
#include "odb.h"
#include "refdb.h"
#include "remote.h"
#include "merge.h"
#include "diff_driver.h"
#include "annotated_commit.h"
#include "submodule.h"
#include "worktree.h"
#include "path.h"
#include "../CGitKit/include/gitkit_libgit2.h"

#if defined(_MSC_VER)
#  define GITKIT_THREAD_LOCAL __declspec(thread)
#else
#  define GITKIT_THREAD_LOCAL __thread
#endif

/* SYSTEM, XDG, GLOBAL and APP: the levels a scope may replace. */
#define GITKIT_SCOPE_LEVELS 4

typedef struct {
	git_config_level_t level;
	char *path;		/* a file level, or NULL */
	char *text;		/* an entries level: its config text */
	size_t text_len;
	char *backend_type;
} gitkit_config_scope_level;

typedef struct {
	int code;
	int klass;
	char *message;
	int reported;		/* handed back by the call that failed */
} gitkit_config_scope_failure;

struct gitkit_config_scope {
	gitkit_config_scope_level levels[GITKIT_SCOPE_LEVELS];
	size_t levels_len;

	enum { GITKIT_SCOPE_NEW, GITKIT_SCOPE_PUSHED, GITKIT_SCOPE_POPPED } state;
	gitkit_config_scope *previous;

	gitkit_config_scope_failure *failures;
	size_t failures_len;
	int failure_lost;	/* one could not be recorded */
};

static GITKIT_THREAD_LOCAL gitkit_config_scope *gitkit_current_scope;

int gitkit_config_scope_new(gitkit_config_scope **out)
{
	GIT_ASSERT_ARG(out);

	*out = git__calloc(1, sizeof(gitkit_config_scope));
	GIT_ERROR_CHECK_ALLOC(*out);
	return 0;
}

static void gitkit_scope_level_dispose(gitkit_config_scope_level *level)
{
	git__free(level->path);
	git__free(level->text);
	git__free(level->backend_type);
	memset(level, 0, sizeof(*level));
}

void gitkit_config_scope_free(gitkit_config_scope *scope)
{
	size_t i;

	/* Freeing a scope still in force would leave the thread pointing at it. */
	if (!scope || scope->state == GITKIT_SCOPE_PUSHED)
		return;

	for (i = 0; i < scope->levels_len; i++)
		gitkit_scope_level_dispose(&scope->levels[i]);
	for (i = 0; i < scope->failures_len; i++)
		git__free(scope->failures[i].message);
	git__free(scope->failures);
	git__free(scope);
}

/* The slot for `level`, replacing what the scope held for it. */
static gitkit_config_scope_level *gitkit_scope_slot(
	gitkit_config_scope *scope, git_config_level_t level)
{
	size_t i;

	if (scope->state != GITKIT_SCOPE_NEW) {
		git_error_set(GIT_ERROR_INVALID, "an operation configuration scope is changed only before it is pushed");
		return NULL;
	}

	switch (level) {
	case GIT_CONFIG_LEVEL_SYSTEM:
	case GIT_CONFIG_LEVEL_XDG:
	case GIT_CONFIG_LEVEL_GLOBAL:
	case GIT_CONFIG_LEVEL_APP:
		break;
	default:
		git_error_set(GIT_ERROR_INVALID, "an operation configuration scope cannot replace config level %d", (int)level);
		return NULL;
	}

	for (i = 0; i < scope->levels_len; i++) {
		if (scope->levels[i].level == level) {
			gitkit_scope_level_dispose(&scope->levels[i]);
			scope->levels[i].level = level;
			return &scope->levels[i];
		}
	}

	scope->levels[scope->levels_len].level = level;
	return &scope->levels[scope->levels_len++];
}

int gitkit_config_scope_add_file(
	gitkit_config_scope *scope, git_config_level_t level, const char *path)
{
	gitkit_config_scope_level *slot;

	GIT_ASSERT_ARG(scope);
	GIT_ASSERT_ARG(path);

	if ((slot = gitkit_scope_slot(scope, level)) == NULL)
		return -1;

	slot->path = git__strdup(path);
	GIT_ERROR_CHECK_ALLOC(slot->path);
	return 0;
}

int gitkit_config_scope_add_entries(
	gitkit_config_scope *scope, git_config_level_t level,
	const char *text, size_t len, const char *backend_type)
{
	gitkit_config_scope_level *slot;

	GIT_ASSERT_ARG(scope);
	GIT_ASSERT_ARG(text || !len);

	if ((slot = gitkit_scope_slot(scope, level)) == NULL)
		return -1;

	/* An empty level still needs a text, to tell it from a file level. */
	slot->text = git__malloc(len + 1);
	GIT_ERROR_CHECK_ALLOC(slot->text);
	if (len)
		memcpy(slot->text, text, len);
	slot->text[len] = '\0';
	slot->text_len = len;

	if (backend_type) {
		slot->backend_type = git__strdup(backend_type);
		GIT_ERROR_CHECK_ALLOC(slot->backend_type);
	}
	return 0;
}

int gitkit_config_scope_push(gitkit_config_scope *scope)
{
	GIT_ASSERT_ARG(scope);

	if (scope->state != GITKIT_SCOPE_NEW) {
		git_error_set(GIT_ERROR_INVALID, "an operation configuration scope is pushed only once");
		return -1;
	}

	scope->previous = gitkit_current_scope;
	scope->state = GITKIT_SCOPE_PUSHED;
	gitkit_current_scope = scope;
	return 0;
}

int gitkit_config_scope_pop(gitkit_config_scope *scope)
{
	GIT_ASSERT_ARG(scope);

	if (scope->state != GITKIT_SCOPE_PUSHED || gitkit_current_scope != scope) {
		git_error_set(GIT_ERROR_INVALID, "an operation configuration scope is popped by its thread, innermost first");
		return -1;
	}

	gitkit_current_scope = scope->previous;
	scope->previous = NULL;
	scope->state = GITKIT_SCOPE_POPPED;
	return 0;
}

int gitkit_config_scope_has_level(git_config_level_t level)
{
	gitkit_config_scope *scope = gitkit_current_scope;
	size_t i;

	if (!scope)
		return 0;

	for (i = 0; i < scope->levels_len; i++)
		if (scope->levels[i].level == level)
			return 1;
	return 0;
}

int gitkit_config_scope_first_failure(
	const gitkit_config_scope *scope, int *code, int *klass, const char **message)
{
	size_t i;

	GIT_ASSERT_ARG(scope);

	for (i = 0; i < scope->failures_len; i++) {
		const gitkit_config_scope_failure *failure = &scope->failures[i];

		if (failure->reported)
			continue;
		if (code)
			*code = failure->code;
		if (klass)
			*klass = failure->klass;
		if (message)
			*message = failure->message;
		return 1;
	}

	if (scope->failure_lost) {
		if (code)
			*code = -1;
		if (klass)
			*klass = GIT_ERROR_NOMEMORY;
		if (message)
			*message = "a config failure during the operation could not be recorded";
		return 1;
	}
	return 0;
}

void gitkit_config_scope_mark_reported(int klass, const char *message)
{
	gitkit_config_scope *scope = gitkit_current_scope;
	gitkit_config_scope_failure *newest;

	if (!scope || !scope->failures_len || !message)
		return;

	/*
	 * Only the newest record can be the error being handed back: each
	 * failure recorded later replaced libgit2's error with its own, and
	 * one libgit2 cleared is followed by a fresh record if it recurs.
	 */
	newest = &scope->failures[scope->failures_len - 1];
	if (!newest->reported && newest->klass == klass &&
	    newest->message && strcmp(newest->message, message) == 0)
		newest->reported = 1;
}

/* How many failures the calling thread's scope recorded so far. */
static size_t gitkit_scope_recorded(void)
{
	gitkit_config_scope *scope = gitkit_current_scope;

	return scope ? scope->failures_len + (size_t)scope->failure_lost : 0;
}

/*
 * Records libgit2's current error as a failure of the calling thread's
 * scope, if there is one. Also called by config_file_patched.c when the
 * include policy refuses an include.
 */
void gitkit_config_scope__record(int code)
{
	gitkit_config_scope *scope = gitkit_current_scope;
	gitkit_config_scope_failure *grown;
	const git_error *last;

	if (!scope)
		return;

	grown = git__reallocarray(scope->failures, scope->failures_len + 1, sizeof(*grown));
	if (!grown) {
		scope->failure_lost = 1;
		return;
	}
	scope->failures = grown;

	last = git_error_last();
	grown = &scope->failures[scope->failures_len];
	grown->code = code < 0 ? code : -1;
	grown->klass = last ? last->klass : 0;
	grown->message = git__strdup(last && last->message ? last->message : "unknown error");
	grown->reported = 0;

	if (!grown->message) {
		scope->failure_lost = 1;
		return;
	}
	scope->failures_len++;
}

static int gitkit_repository_add_file(
	git_config *cfg, const char *path, git_config_level_t level,
	const git_repository *repo, int force)
{
	size_t recorded;
	int error;

	if (gitkit_config_scope_has_level(level))
		return 0;

	recorded = gitkit_scope_recorded();
	error = git_config_add_file_ondisk(cfg, path, level, repo, force);

	/* A refused include recorded itself already. */
	if (error < 0 && error != GIT_ENOTFOUND && gitkit_scope_recorded() == recorded)
		gitkit_config_scope__record(error);
	return error;
}

static int gitkit_scope_add_level(
	git_config *cfg, const gitkit_config_scope_level *level, git_repository *repo)
{
	git_config_backend_memory_options options = GIT_CONFIG_BACKEND_MEMORY_OPTIONS_INIT;
	git_config_backend *backend = NULL;
	int error;

	if (level->path)
		return git_config_add_file_ondisk(cfg, level->path, level->level, repo, 1);

	options.backend_type = level->backend_type;
	if ((error = git_config_backend_from_string(&backend, level->text, level->text_len, &options)) < 0)
		return error;

	if ((error = git_config_add_backend(cfg, backend, level->level, repo, 1)) < 0)
		backend->free(backend);	/* not owned by the config yet */
	return error;
}

static int gitkit_repository_finish_config(
	git_config *cfg, git_config_level_t *write_order, size_t len,
	git_repository *repo)
{
	gitkit_config_scope *scope = gitkit_current_scope;
	size_t i, recorded;
	int error;

	if (scope) {
		for (i = 0; i < scope->levels_len; i++) {
			recorded = gitkit_scope_recorded();
			if ((error = gitkit_scope_add_level(cfg, &scope->levels[i], repo)) < 0) {
				if (gitkit_scope_recorded() == recorded)
					gitkit_config_scope__record(error);
				return error;
			}
		}
	}

	/* Adding a level makes it the write target; the open's order wins. */
	return git_config_set_writeorder(cfg, write_order, len);
}

#define git_config_add_file_ondisk(cfg, path, level, repo, force) \
	gitkit_repository_add_file(cfg, path, level, repo, force)
#define git_config_set_writeorder(cfg, order, len) \
	gitkit_repository_finish_config(cfg, order, len, repo)
#include "repository.c"
#undef git_config_set_writeorder
#undef git_config_add_file_ondisk
