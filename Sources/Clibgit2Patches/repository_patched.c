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
 * Each scope level's backend hides the settings git reads from the
 * repository's own config only — core.repositoryformatversion, core.bare,
 * core.worktree, extensions.* — whether its file, a file that includes or
 * its entries set them, so an operation level never changes a repository's
 * format or layout.
 *
 * Before each file is added there, and before each git_config_open_default()
 * (an init's `init.defaultBranch`), gitkit_created_watch_notify() lets a
 * GitKit init record what it wrote before the include policy can run, and
 * check it after, and gitkit_created_watch_settle() checks it again as each
 * returns; git_filebuf_commit() (an init's HEAD) is routed through
 * gitkit_created_watch_commit(), which records the init's own write
 * (created_dir.c). Outside such an init all three do as before.
 *
 * The APP level is git's whole command-line config, which may be layered:
 * entries, a file an `-c include.path=<file>` names, later entries. Its
 * sources are added in order at APP, APP + 1, …, so a later one wins a
 * single read; a scope naming APP replaces the whole set.
 *
 * With no scope on the calling thread both behave exactly as before. A
 * scope is pushed and popped by the thread it belongs to (LIFO, so a
 * nested scope restores the outer one). A level is the innermost pushed
 * scope's that has it: a nested scope replaces only the levels it names,
 * the outer scopes' others stay in force. A scope holds only copies — a file's
 * path, an entries level's text — so no caller memory is lent to libgit2;
 * each load reads the file and parses the text again into backends the
 * config owns.
 *
 * A scope's file that is missing reads as empty; one that exists but
 * cannot be read is refused when the scope is built and fails any open
 * that finds it so later (libgit2 would read it as missing and open the
 * repository with no config at all).
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
#include "config_backend.h"
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
#include "gitkit_created_dir.h"
#include "gitkit_config_condition.h"

#if defined(_MSC_VER)
#  define GITKIT_THREAD_LOCAL __declspec(thread)
#else
#  define GITKIT_THREAD_LOCAL __thread
#endif

/* SYSTEM, XDG, GLOBAL and APP: the levels a scope may replace. */
#define GITKIT_SCOPE_LEVELS 4

typedef struct {
	char *path;		/* a file, or NULL */
	char *text;		/* entries: their config text */
	size_t text_len;
	char *backend_type;
	int command;
} gitkit_config_scope_source;

/* One source, or for APP the command-line layers in order (maybe none). */
typedef struct {
	git_config_level_t level;
	gitkit_config_scope_source *sources;
	size_t sources_len;
} gitkit_config_scope_level;

typedef struct {
	int code;
	int klass;
	char *message;
	int reported;		/* handed back by the call that failed */
} gitkit_config_scope_failure;

typedef struct {
	char *condition, *gitdir;
} gitkit_config_diagnostic;

struct gitkit_config_scope {
	size_t refs;
	gitkit_config_scope_level levels[GITKIT_SCOPE_LEVELS];
	size_t levels_len;

	enum { GITKIT_SCOPE_NEW, GITKIT_SCOPE_PUSHED, GITKIT_SCOPE_POPPED } state;
	gitkit_config_scope *previous;

	gitkit_config_scope_failure *failures;
	size_t failures_len;
	int failure_lost;	/* one could not be recorded */
	gitkit_config_diagnostic *diagnostics;
	size_t diagnostics_len;
};

static GITKIT_THREAD_LOCAL gitkit_config_scope *gitkit_current_scope;

/* Contexts retain their owner, not whatever scope happens to be current
 * during a later refresh. Popped owners stay inert until the last context
 * releases them, so neither a dangling pointer nor cross-scope delivery is
 * possible when a config outlives its operation. */
void gitkit_config_scope__retain(gitkit_config_scope *scope) { if (scope) scope->refs++; }

gitkit_config_scope *gitkit_config_scope__diagnostic_owner(void)
{
	gitkit_config_scope *scope;
	size_t i;
	for (scope = gitkit_current_scope; scope; scope = scope->previous)
		for (i = 0; i < scope->levels_len; i++)
			if (scope->levels[i].level == GIT_CONFIG_LEVEL_APP)
				return scope;
	return gitkit_current_scope;
}

void gitkit_config_scope__diagnostic(gitkit_config_scope *scope, const char *condition, const char *gitdir)
{
	gitkit_config_diagnostic *grown;
	char *condition_copy, *gitdir_copy;
	if (!scope || scope->state == GITKIT_SCOPE_POPPED)
		return;
	condition_copy = git__strdup(condition);
	gitdir_copy = gitdir ? git__strdup(gitdir) : NULL;
	if (!condition_copy || (gitdir && !gitdir_copy))
		goto fail;
	grown = git__reallocarray(scope->diagnostics, scope->diagnostics_len + 1, sizeof(*grown));
	if (!grown)
		goto fail;
	scope->diagnostics = grown;
	grown[scope->diagnostics_len].condition = condition_copy;
	grown[scope->diagnostics_len++].gitdir = gitdir_copy;
	return;
fail:
	git__free(condition_copy);
	git__free(gitdir_copy);
	scope->failure_lost = 1;
}

size_t gitkit_config_scope_diagnostic_count(const gitkit_config_scope *scope) { return scope->diagnostics_len; }
void gitkit_config_scope_diagnostic(const gitkit_config_scope *scope, size_t index,
	const char **condition, const char **gitdir)
{
	*condition = scope->diagnostics[index].condition;
	*gitdir = scope->diagnostics[index].gitdir;
}

int gitkit_config_scope_new(gitkit_config_scope **out)
{
	GIT_ASSERT_ARG(out);

	*out = git__calloc(1, sizeof(gitkit_config_scope));
	GIT_ERROR_CHECK_ALLOC(*out);
	(*out)->refs = 1;
	return 0;
}

static void gitkit_scope_level_dispose(gitkit_config_scope_level *level)
{
	size_t i;

	for (i = 0; i < level->sources_len; i++) {
		git__free(level->sources[i].path);
		git__free(level->sources[i].text);
		git__free(level->sources[i].backend_type);
	}
	git__free(level->sources);
	memset(level, 0, sizeof(*level));
}

void gitkit_config_scope__release(gitkit_config_scope *scope)
{
	size_t i;

	if (!scope || --scope->refs)
		return;

	for (i = 0; i < scope->levels_len; i++)
		gitkit_scope_level_dispose(&scope->levels[i]);
	for (i = 0; i < scope->failures_len; i++)
		git__free(scope->failures[i].message);
	git__free(scope->failures);
	for (i = 0; i < scope->diagnostics_len; i++) {
		git__free(scope->diagnostics[i].condition);
		git__free(scope->diagnostics[i].gitdir);
	}
	git__free(scope->diagnostics);
	git__free(scope);
}

void gitkit_config_scope_free(gitkit_config_scope *scope)
{
	/* Freeing a scope still in force would leave the thread pointing at it. */
	if (!scope || scope->state == GITKIT_SCOPE_PUSHED)
		return;
	scope->state = GITKIT_SCOPE_POPPED;
	gitkit_config_scope__release(scope);
}

/*
 * The slot for `level`: emptied when `replace`, else kept as it is (an empty
 * one when the scope had none).
 */
static gitkit_config_scope_level *gitkit_scope_slot(
	gitkit_config_scope *scope, git_config_level_t level, int replace)
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
			if (replace) {
				gitkit_scope_level_dispose(&scope->levels[i]);
				scope->levels[i].level = level;
			}
			return &scope->levels[i];
		}
	}

	scope->levels[scope->levels_len].level = level;
	return &scope->levels[scope->levels_len++];
}

/* A new, empty source appended to `slot`. */
static gitkit_config_scope_source *gitkit_scope_source_append(gitkit_config_scope_level *slot)
{
	gitkit_config_scope_source *grown;

	grown = git__reallocarray(slot->sources, slot->sources_len + 1, sizeof(*grown));
	if (!grown)
		return NULL;
	slot->sources = grown;
	memset(&grown[slot->sources_len], 0, sizeof(*grown));
	return &grown[slot->sources_len++];
}

static int gitkit_scope_source_set_file(gitkit_config_scope_level *slot, const char *path)
{
	gitkit_config_scope_source *source;
	char *copy = git__strdup(path);

	GIT_ERROR_CHECK_ALLOC(copy);
	if ((source = gitkit_scope_source_append(slot)) == NULL) {
		git__free(copy);
		return -1;
	}
	source->path = copy;
	return 0;
}

static int gitkit_scope_source_set_entries(
	gitkit_config_scope_level *slot, const char *text, size_t len, const char *backend_type)
{
	gitkit_config_scope_source *source;
	char *copy, *type = NULL;

	/* An empty level still needs a text, to tell it from a file level. */
	copy = git__malloc(len + 1);
	GIT_ERROR_CHECK_ALLOC(copy);
	if (len)
		memcpy(copy, text, len);
	copy[len] = '\0';

	if (backend_type && (type = git__strdup(backend_type)) == NULL) {
		git__free(copy);
		return -1;
	}
	if ((source = gitkit_scope_source_append(slot)) == NULL) {
		git__free(copy);
		git__free(type);
		return -1;
	}
	source->text = copy;
	source->text_len = len;
	source->backend_type = type;
	return 0;
}

/*
 * A scope's file reads as empty when it is missing, as a search-path file
 * does. One that exists but cannot be read is an error, not git's silently
 * ignored search-path file: config_file_open() reports it as GIT_ENOTFOUND
 * with no error set, and an open handed GIT_ENOTFOUND from load_config()
 * carries on with no config at all — no repository config, workdir or
 * format checks.
 */
static int gitkit_scope_file_readable(const char *path)
{
	if (p_access(path, R_OK) == 0 || errno == ENOENT || errno == ENOTDIR)
		return 0;

	git_error_set(GIT_ERROR_OS, "failed to read config file '%s'", path);
	return -1;
}

int gitkit_config_file_check_readable(const char *path)
{
	GIT_ASSERT_ARG(path);

	return gitkit_scope_file_readable(path);
}

int gitkit_config_scope_add_file(
	gitkit_config_scope *scope, git_config_level_t level, const char *path)
{
	gitkit_config_scope_level *slot;

	GIT_ASSERT_ARG(scope);
	GIT_ASSERT_ARG(path);

	/* Refused here already, before the operation runs. */
	if (gitkit_scope_file_readable(path) < 0)
		return -1;

	if ((slot = gitkit_scope_slot(scope, level, 1)) == NULL)
		return -1;
	return gitkit_scope_source_set_file(slot, path);
}

int gitkit_config_scope_add_entries(
	gitkit_config_scope *scope, git_config_level_t level,
	const char *text, size_t len, const char *backend_type)
{
	gitkit_config_scope_level *slot;

	GIT_ASSERT_ARG(scope);
	GIT_ASSERT_ARG(text || !len);

	if ((slot = gitkit_scope_slot(scope, level, 1)) == NULL)
		return -1;
	return gitkit_scope_source_set_entries(slot, text, len, backend_type);
}

int gitkit_config_scope_reset_layers(gitkit_config_scope *scope)
{
	GIT_ASSERT_ARG(scope);

	return gitkit_scope_slot(scope, GIT_CONFIG_LEVEL_APP, 1) ? 0 : -1;
}

int gitkit_config_scope_add_layer_file(gitkit_config_scope *scope, const char *path)
{
	gitkit_config_scope_level *slot;

	GIT_ASSERT_ARG(scope);
	GIT_ASSERT_ARG(path);

	if (gitkit_scope_file_readable(path) < 0)
		return -1;
	if ((slot = gitkit_scope_slot(scope, GIT_CONFIG_LEVEL_APP, 0)) == NULL)
		return -1;
	return gitkit_scope_source_set_file(slot, path);
}

int gitkit_config_scope_add_layer_entries(
	gitkit_config_scope *scope, const char *text, size_t len, const char *backend_type)
{
	gitkit_config_scope_level *slot;

	GIT_ASSERT_ARG(scope);
	GIT_ASSERT_ARG(text || !len);

	if ((slot = gitkit_scope_slot(scope, GIT_CONFIG_LEVEL_APP, 0)) == NULL)
		return -1;
	return gitkit_scope_source_set_entries(slot, text, len, backend_type);
}

int gitkit_config_scope_add_layer_command(gitkit_config_scope *scope, const char *text, size_t len)
{
	gitkit_config_scope_level *slot = gitkit_scope_slot(scope, GIT_CONFIG_LEVEL_APP, 0);
	int error;
	if (!slot)
		return -1;
	error = gitkit_scope_source_set_entries(slot, text, len, "command line");
	if (!error) slot->sources[slot->sources_len - 1].command = 1;
	return error;
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

/*
 * The level in force on the calling thread: the innermost pushed scope's
 * that has it, so a nested scope replaces only the levels it names and the
 * outer scopes' others stay in force.
 */
static const gitkit_config_scope_level *gitkit_scope_effective_level(git_config_level_t level)
{
	const gitkit_config_scope *scope;
	size_t i;

	for (scope = gitkit_current_scope; scope; scope = scope->previous)
		for (i = 0; i < scope->levels_len; i++)
			if (scope->levels[i].level == level)
				return &scope->levels[i];
	return NULL;
}

int gitkit_config_scope_has_level(git_config_level_t level)
{
	return gitkit_scope_effective_level(level) != NULL;
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

	/* With no error set, git_error_last() is libgit2's "no error". */
	last = git_error_last();
	if (last && last->klass == GIT_ERROR_NONE)
		last = NULL;
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
	/* Around this file's includes reaching the host's include policy. */
	gitkit_created_watch_notify();
	error = git_config_add_file_ondisk(cfg, path, level, repo, force);
	gitkit_created_watch_settle();

	/* A refused include recorded itself already. */
	if (error < 0 && error != GIT_ENOTFOUND && gitkit_scope_recorded() == recorded)
		gitkit_config_scope__record(error);
	return error;
}

/*
 * git reads the repository format and layout — core.repositoryformatversion,
 * core.bare, core.worktree, extensions.* — from the repository's own config
 * only, while libgit2 reads them from the merged config at open. A scope
 * level must not change them, from its file, the files that includes, or
 * its entries, so its backend hides them.
 */
static int gitkit_repository_only(const char *name)
{
	const char *dot = name ? strchr(name, '.') : NULL;
	const char *variable;

	if (!dot)
		return 0;
	if (dot - name == 10 && !git__strncasecmp(name, "extensions", 10))
		return 1;
	if (dot - name != 4 || git__strncasecmp(name, "core", 4))
		return 0;

	variable = dot + 1;
	if (strchr(variable, '.'))
		return 0;	/* core.<subsection>.<variable> */
	return !git__strcasecmp(variable, "repositoryformatversion") ||
	       !git__strcasecmp(variable, "bare") ||
	       !git__strcasecmp(variable, "worktree");
}

typedef struct {
	git_config_backend parent;
	git_config_backend *inner;
} gitkit_scope_backend;

typedef struct {
	git_config_iterator parent;
	git_config_iterator *inner;
} gitkit_scope_iterator;

#define GITKIT_INNER(backend) (((gitkit_scope_backend *)(backend))->inner)

static int gitkit_scope_backend_open(
	git_config_backend *backend, git_config_level_t level, const git_repository *repo)
{
	return GITKIT_INNER(backend)->open(GITKIT_INNER(backend), level, repo);
}

static int gitkit_scope_backend_get(
	git_config_backend *backend, const char *key, git_config_backend_entry **out)
{
	if (gitkit_repository_only(key))
		return GIT_ENOTFOUND;
	return GITKIT_INNER(backend)->get(GITKIT_INNER(backend), key, out);
}

static int gitkit_scope_backend_set(git_config_backend *backend, const char *key, const char *value)
{
	return GITKIT_INNER(backend)->set(GITKIT_INNER(backend), key, value);
}

static int gitkit_scope_backend_set_multivar(
	git_config_backend *backend, const char *name, const char *regexp, const char *value)
{
	return GITKIT_INNER(backend)->set_multivar(GITKIT_INNER(backend), name, regexp, value);
}

static int gitkit_scope_backend_del(git_config_backend *backend, const char *key)
{
	return GITKIT_INNER(backend)->del(GITKIT_INNER(backend), key);
}

static int gitkit_scope_backend_del_multivar(
	git_config_backend *backend, const char *key, const char *regexp)
{
	return GITKIT_INNER(backend)->del_multivar(GITKIT_INNER(backend), key, regexp);
}

static int gitkit_scope_iterator_next(git_config_backend_entry **out, git_config_iterator *iter)
{
	git_config_iterator *inner = ((gitkit_scope_iterator *)iter)->inner;
	int error;

	while ((error = inner->next(out, inner)) == 0 && gitkit_repository_only((*out)->entry.name))
		;	/* the inner backend owns its entries */
	return error;
}

static void gitkit_scope_iterator_free(git_config_iterator *iter)
{
	git_config_iterator *inner = ((gitkit_scope_iterator *)iter)->inner;

	inner->free(inner);
	git__free(iter);
}

static int gitkit_scope_backend_iterator(git_config_iterator **out, git_config_backend *backend)
{
	gitkit_scope_iterator *iter;
	git_config_iterator *inner;
	int error;

	if ((error = GITKIT_INNER(backend)->iterator(&inner, GITKIT_INNER(backend))) < 0)
		return error;

	if ((iter = git__calloc(1, sizeof(*iter))) == NULL) {
		inner->free(inner);
		return -1;
	}

	iter->parent.backend = backend;
	iter->parent.flags = inner->flags;
	iter->parent.next = gitkit_scope_iterator_next;
	iter->parent.free = gitkit_scope_iterator_free;
	iter->inner = inner;
	*out = &iter->parent;
	return 0;
}

static int gitkit_scope_backend_wrap(git_config_backend **out, git_config_backend *inner);

static int gitkit_scope_backend_snapshot(git_config_backend **out, git_config_backend *backend)
{
	git_config_backend *snapshot;
	int error;

	if ((error = GITKIT_INNER(backend)->snapshot(&snapshot, GITKIT_INNER(backend))) < 0)
		return error;
	return gitkit_scope_backend_wrap(out, snapshot);
}

static int gitkit_scope_backend_lock(git_config_backend *backend)
{
	return GITKIT_INNER(backend)->lock(GITKIT_INNER(backend));
}

static int gitkit_scope_backend_unlock(git_config_backend *backend, int success)
{
	return GITKIT_INNER(backend)->unlock(GITKIT_INNER(backend), success);
}

static void gitkit_scope_backend_free(git_config_backend *backend)
{
	if (!backend)
		return;
	GITKIT_INNER(backend)->free(GITKIT_INNER(backend));
	git__free(backend);
}

/* Wraps `inner`, which it takes ownership of — freeing it on failure. */
static int gitkit_scope_backend_wrap(git_config_backend **out, git_config_backend *inner)
{
	gitkit_scope_backend *backend;

	if ((backend = git__calloc(1, sizeof(*backend))) == NULL) {
		inner->free(inner);
		return -1;
	}

	backend->parent.version = GIT_CONFIG_BACKEND_VERSION;
	backend->parent.readonly = inner->readonly;
	backend->parent.open = gitkit_scope_backend_open;
	backend->parent.get = gitkit_scope_backend_get;
	backend->parent.set = gitkit_scope_backend_set;
	backend->parent.set_multivar = gitkit_scope_backend_set_multivar;
	backend->parent.del = gitkit_scope_backend_del;
	backend->parent.del_multivar = gitkit_scope_backend_del_multivar;
	backend->parent.iterator = gitkit_scope_backend_iterator;
	backend->parent.snapshot = gitkit_scope_backend_snapshot;
	backend->parent.lock = gitkit_scope_backend_lock;
	backend->parent.unlock = gitkit_scope_backend_unlock;
	backend->parent.free = gitkit_scope_backend_free;
	backend->inner = inner;
	*out = &backend->parent;
	return 0;
}

git_config_backend *gitkit_config_backend_unwrap(git_config_backend *backend, int *filtered)
{
	*filtered = backend->open == gitkit_scope_backend_open;
	return *filtered ? GITKIT_INNER(backend) : backend;
}

int gitkit_config_backend_filter(git_config_backend **out, git_config_backend *inner)
{
	return gitkit_scope_backend_wrap(out, inner);
}

static int gitkit_scope_add_source(
	git_config *cfg, const gitkit_config_scope_source *level,
	git_config_level_t at, git_repository *repo, int filter)
{
	git_config_backend_memory_options options = GIT_CONFIG_BACKEND_MEMORY_OPTIONS_INIT;
	git_config_backend *inner = NULL, *backend = NULL;
	int error;

	if (level->path) {
		/* It may have become unreadable since the scope was built. */
		if (gitkit_scope_file_readable(level->path) < 0)
			return -1;
		error = git_config_backend_from_file(&inner, level->path);
	} else if (level->command) {
		error = gitkit_config_backend_command(&inner, level->text, level->text_len, at);
	} else {
		options.backend_type = level->backend_type;
		error = git_config_backend_from_string(&inner, level->text, level->text_len, &options);
	}
	if (error < 0)
		return error;
	if (filter) {
		if ((error = gitkit_scope_backend_wrap(&backend, inner)) < 0) return error;
	} else backend = inner;

	if ((error = git_config_add_backend(cfg, backend, at, repo, 1)) < 0)
		backend->free(backend);	/* not owned by the config yet */

	/*
	 * Only config_file_open() reports GIT_ENOTFOUND: the file became
	 * unreadable since the check above. Never hand that code to the open.
	 */
	if (error == GIT_ENOTFOUND) {
		if (!level->path)
			git_error_set(GIT_ERROR_CONFIG, "an operation config level could not be loaded");
		else if (gitkit_scope_file_readable(level->path) == 0)
			git_error_set(GIT_ERROR_CONFIG, "config file '%s' changed while it was read", level->path);
		error = -1;
	}
	return error;
}

static int gitkit_repository_finish_config_inner(
	git_config *cfg, git_config_level_t *write_order, size_t len,
	git_repository *repo)
{
	static const git_config_level_t levels[GITKIT_SCOPE_LEVELS] = {
		GIT_CONFIG_LEVEL_SYSTEM, GIT_CONFIG_LEVEL_XDG,
		GIT_CONFIG_LEVEL_GLOBAL, GIT_CONFIG_LEVEL_APP
	};
	const gitkit_config_scope_level *level;
	git_config_level_t at;
	size_t i, j, recorded;
	int error;

	for (i = 0; i < GITKIT_SCOPE_LEVELS; i++) {
		if ((level = gitkit_scope_effective_level(levels[i])) == NULL)
			continue;

		/* The command-line layers go at APP, APP + 1, …, in order. */
		for (j = 0; j < level->sources_len; j++) {
			at = (git_config_level_t)((int)level->level + (int)j);
			recorded = gitkit_scope_recorded();
			if ((error = gitkit_scope_add_source(cfg, &level->sources[j], at, repo, 1)) < 0) {
				if (gitkit_scope_recorded() == recorded)
					gitkit_config_scope__record(error);
				return error;
			}
		}
	}

	/* Adding a level makes it the write target; the open's order wins. */
	return git_config_set_writeorder(cfg, write_order, len);
}

static int gitkit_repository_finish_config(git_config *cfg, git_config_level_t *order, size_t len, git_repository *repo)
{
	int error = gitkit_repository_finish_config_inner(cfg, order, len, repo);
	gitkit_condition_build_end(cfg);
	return error;
}

static int manifest_level(gitkit_condition_context *ctx, const gitkit_config_scope_level *level)
{
	size_t i;
	int error;
	for (i = 0; i < level->sources_len; i++) {
		const gitkit_config_scope_source *source = &level->sources[i];
		if ((error = gitkit_condition_source_add(ctx, source->path, source->text, source->text_len,
		    (git_config_level_t)(level->level + i), source->command, 0)) < 0)
			return error;
	}
	return 0;
}

int gitkit_scope_manifest(gitkit_condition_context *ctx)
{
	const gitkit_config_scope_level *level = gitkit_scope_effective_level(GIT_CONFIG_LEVEL_APP);
	return level ? manifest_level(ctx, level) : 0;
}

static int gitkit_repository_config_new(git_config **out, git_repository *repo,
	const char *global, const char *xdg, const char *system, const char *programdata)
{
	const char *paths[] = { programdata, system, xdg, global };
	git_config_level_t levels[] = { GIT_CONFIG_LEVEL_PROGRAMDATA, GIT_CONFIG_LEVEL_SYSTEM,
		GIT_CONFIG_LEVEL_XDG, GIT_CONFIG_LEVEL_GLOBAL };
	gitkit_condition_context *ctx = gitkit_condition_new(repo);
	const gitkit_config_scope_level *level;
	git_str path = GIT_STR_INIT;
	size_t i;
	int error = -1;
	if (!ctx)
		return -1;
	for (i = 0; i < ARRAY_SIZE(paths); i++) {
		level = gitkit_scope_effective_level(levels[i]);
		if (level) error = manifest_level(ctx, level);
		else error = paths[i] ? gitkit_condition_source_add(ctx, paths[i], NULL, 0, levels[i], 0, 0) : 0;
		if (error < 0) goto done;
	}
	/* git_repository_new() has no files of its own, as load_config finds. */
	if (repo && git_repository_path(repo)) {
		if ((error = git_repository__item_path(&path, repo, GIT_REPOSITORY_ITEM_CONFIG)) < 0 ||
		    (error = gitkit_condition_source_add(ctx, path.ptr, NULL, 0, GIT_CONFIG_LEVEL_LOCAL, 0, 0)) < 0 ||
		    (error = git_repository__item_path(&path, repo, GIT_REPOSITORY_ITEM_WORKTREE_CONFIG)) < 0 ||
		    (error = gitkit_condition_source_add(ctx, path.ptr, NULL, 0, GIT_CONFIG_LEVEL_WORKTREE, 0, 1)) < 0)
			goto done;
	}
	if ((error = gitkit_scope_manifest(ctx)) < 0 || (error = git_config_new(out)) < 0)
		goto done;
	if ((error = gitkit_condition_build_begin(*out, ctx)) < 0) {
		git_config_free(*out);
		*out = NULL;
	}
done:
	git_str_dispose(&path);
	gitkit_condition_free(ctx);
	return error;
}

/* An explicitly supplied command-line set on a live or repository-less cfg.
 * The manifest includes every lower file and entry before any is re-read. */
int gitkit_config_scope_install(gitkit_config_scope *scope, git_config *cfg, git_repository *repo)
{
	gitkit_condition_context *ctx = gitkit_condition_new(repo), *previous;
	const gitkit_config_scope_level *level = NULL;
	git_config *staged = NULL;
	size_t i;
	int error = -1;
	if (!ctx)
		return -1;
	gitkit_condition_diagnostics(ctx, scope);
	for (i = 0; i < scope->levels_len; i++)
		if (scope->levels[i].level == GIT_CONFIG_LEVEL_APP) level = &scope->levels[i];
	if ((error = gitkit_config_manifest_existing(ctx, cfg)) < 0 ||
	    (level && (error = manifest_level(ctx, level)) < 0) ||
	    (error = git_config_new(&staged)) < 0)
		goto done;
	previous = gitkit_condition_enter(ctx);
	ctx->building++;
	if (level) {
		for (i = 0; i < level->sources_len; i++) {
			error = gitkit_scope_add_source(staged, &level->sources[i],
				(git_config_level_t)(GIT_CONFIG_LEVEL_APP + i), repo, 0);
			if (error < 0) break;
		}
	}
	if (!error) error = gitkit_config_rebuild(cfg, staged, ctx);
	ctx->building--;
	gitkit_condition_enter(previous);
done:
	git_config_free(staged);
	gitkit_condition_free(ctx);
	return error;
}

/* An init's own config reads (`init.defaultBranch`) reach the include
 * policy too: what a GitKit init wrote is checked before and after each. */
static int gitkit_repository_config_open_default(git_config **out)
{
	int error;

	gitkit_created_watch_notify();
	error = git_config_open_default(out);
	gitkit_created_watch_settle();
	return error;
}

#define git_config_add_file_ondisk(cfg, path, level, repo, force) \
	gitkit_repository_add_file(cfg, path, level, repo, force)
#define git_config_open_default(out) gitkit_repository_config_open_default(out)
#define git_config_set_writeorder(cfg, order, len) \
	gitkit_repository_finish_config(cfg, order, len, repo)
#define git_filebuf_commit(file) gitkit_created_watch_commit(file)
#define git_config_new(out) gitkit_repository_config_new(out, repo, global_config_path, xdg_config_path, system_config_path, programdata_path)
#include "repository.c"
#undef git_config_new
#undef git_filebuf_commit
#undef git_config_open_default
#undef git_config_set_writeorder
#undef git_config_add_file_ondisk
