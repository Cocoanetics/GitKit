/*
 * GitKit shim — `git config set/unset` look only at the file being written.
 *
 * config_file_set() and config_file_delete() refuse a key with
 * git_config_list_get_unique(), which looks the key up in the backend's
 * merged list: entries read from `[include]` files are in it, so a key an
 * included file repeats fails with "entry is not unique due to being
 * included" (or "…a multivar"), though the write only ever touches this
 * backend's own file (config_file_write() never follows includes). git
 * counts the entries of the target file alone.
 *
 * Within config_file.c only, git_config_list_get_unique() is renamed to
 * gitkit_config_list_get_unique_own(), which considers the entries of the
 * backend's own file — the ones read at include depth 0, since an include
 * is read one level deeper — whatever the include files hold: none is
 * GIT_ENOTFOUND (set appends the key, unset reports it missing), several is
 * the multivar error. The "values already match, skip the write" shortcut
 * in set therefore compares with the target file's own entry too.
 *
 * GitKit shim — authorising `[include]` / `[includeIf]` files.
 *
 * A host that sandboxes file access has to know which files libgit2 reads
 * for an include, and be able to refuse one. Every include — `[include]`,
 * a matching `[includeIf]`, and an include inside an include — is read by
 * config_file_read() at a depth above 0, and that function's one p_stat()
 * is the first thing it does with the path. Within config_file.c only,
 * p_stat() is routed through gitkit_include_stat(), which, for an include,
 * asks the policy in force first: the file's path, the path of the file
 * that named it and its depth. A refusal fails the config load with
 * GIT_ERROR_CONFIG "include of '<path>' is not authorised", before the
 * file is stat'd or read. (git_fs_path_set_error(), which would replace the
 * message with a stat error, leaves a refusal's error alone.) The including
 * file's path is kept per thread, by depth, as the reads nest.
 *
 * The policy in force is, in this order: the one set for the repository
 * the config is read for (gitkit_config_set_include_callback(repo, …)), the
 * one set for the calling thread (…_thread_include_callback, for a config
 * read while the repository is still being opened), the process-wide
 * default (gitkit_config_set_include_callback(NULL, …)). With none, nothing
 * is asked and an include is read as before. The hook runs each time the
 * include is read, so again whenever the config is reloaded.
 *
 * A refusal can surface when a changed config is reloaded for a lookup, and
 * there libgit2 has a bug of its own: config_file_get() returns the reload's
 * error without setting `*out`, and get_entry() (config.c) then takes
 * `&be->entry` from its uninitialised local and frees through it. (An
 * include that merely became unreadable crashes the same way.) The backend's
 * `get` is wrapped, from git_config_backend_from_file(), to clear `*out`
 * first.
 *
 * GitKit shim — a GitKit init's own config writes. Within config_file.c
 * only, git_filebuf_commit() is routed through
 * gitkit_created_watch_commit() (created_dir.c), so the config a GitKit
 * init writes between its config reads is recorded as its own, and only
 * that.
 */
#include "common.h"
#include "posix.h"
#include "thread.h"
#include "git2/sys/config.h"
#include "../CGitKit/include/gitkit_libgit2.h"
#include "gitkit_created_dir.h"
#include "gitkit_config_condition.h"
#include "config_parse.h"

static int gitkit_file_parse(git_config_parser *, git_config_parser_section_cb,
	git_config_parser_variable_cb, git_config_parser_comment_cb, git_config_parser_eof_cb, void *);
int gitkit_fs_path_set_error(int errno_value, const char *path, const char *action);

static int gitkit_real_stat(const char *path, struct stat *st) { return p_stat(path, st); }

/* One per thread: the include a refusal came from, and who named each depth. */
#if defined(_MSC_VER)
#  define GITKIT_THREAD_LOCAL __declspec(thread)
#else
#  define GITKIT_THREAD_LOCAL __thread
#endif

#define GITKIT_INCLUDE_DEPTHS 16	/* MAX_INCLUDE_DEPTH (10) + 1, with room */

typedef struct {
	const git_repository *repo;	/* NULL for the process default */
	gitkit_config_include_cb cb;
	void *payload;
	gitkit_config_payload_fn retain, release;
} gitkit_include_policy;

static GITKIT_THREAD_LOCAL int gitkit_include_refused;
static GITKIT_THREAD_LOCAL const char *gitkit_include_paths[GITKIT_INCLUDE_DEPTHS];
static GITKIT_THREAD_LOCAL gitkit_include_policy gitkit_thread_policy;

static gitkit_include_policy *gitkit_policies;	/* per repository, then the default */
static size_t gitkit_policies_len;
static gitkit_include_policy gitkit_default_policy;

static git_mutex *gitkit_policy_lock(void)
{
	static git_mutex *lock;
	git_mutex *created, *found = git_atomic_load(lock);

	if (found)
		return found;

	if ((created = git__malloc(sizeof(git_mutex))) == NULL)
		return NULL;
	git_mutex_init(created);

	if ((found = git_atomic_compare_and_swap(&lock, NULL, created)) != NULL) {
		git_mutex_free(created);
		git__free(created);
		return found;
	}
	return created;
}

/*
 * The policy to ask, its payload retained (when the registration brought
 * a retain function) so that a replace or removal on another thread can't
 * free it while the callback runs; the caller releases it with
 * gitkit_policy_done().
 */
static gitkit_include_policy gitkit_policy_for(const git_repository *repo)
{
	git_mutex *lock = gitkit_policy_lock();
	gitkit_include_policy found = gitkit_thread_policy;
	size_t i;

	if (!lock)
		return found;

	git_mutex_lock(lock);
	for (i = 0; i < gitkit_policies_len; i++) {
		if (repo && gitkit_policies[i].repo == repo) {
			found = gitkit_policies[i];
			goto done;
		}
	}
	if (!found.cb)
		found = gitkit_default_policy;
done:
	if (found.retain)
		found.retain(found.payload);
	git_mutex_unlock(lock);
	return found;
}

static void gitkit_policy_done(const gitkit_include_policy *policy)
{
	if (policy->release)
		policy->release(policy->payload);
}

int gitkit_config_authorize(const git_repository *repo, const char *path, const char *from, int depth)
{
	gitkit_include_policy policy = gitkit_policy_for(repo);
	int refused = policy.cb && policy.cb(path, from, depth, policy.payload) != 0;
	gitkit_policy_done(&policy);
	if (!refused)
		return 0;
	git_error_set(GIT_ERROR_CONFIG, "include of '%s' is not authorised", path);
	gitkit_config_scope__record(-1);
	return -1;
}

int gitkit_config_set_include_policy(
	git_repository *repo, gitkit_config_include_cb cb, void *payload,
	gitkit_config_payload_fn retain, gitkit_config_payload_fn release)
{
	git_mutex *lock = gitkit_policy_lock();
	gitkit_include_policy replaced = {0};
	gitkit_include_policy *slot = NULL;
	size_t i;
	int error = 0;

	if (!lock)
		return -1;

	git_mutex_lock(lock);

	if (!repo) {
		slot = &gitkit_default_policy;
	} else {
		for (i = 0; i < gitkit_policies_len; i++) {
			if (gitkit_policies[i].repo == repo) {
				slot = &gitkit_policies[i];
				break;
			}
		}
	}

	if (slot) {
		replaced = *slot;
		if (cb) {
			slot->cb = cb;
			slot->payload = payload;
			slot->retain = retain;
			slot->release = release;
		} else if (repo) {
			*slot = gitkit_policies[--gitkit_policies_len];
		} else {
			memset(slot, 0, sizeof(*slot));
		}
	} else if (cb) {
		gitkit_include_policy *grown = git__reallocarray(
			gitkit_policies, gitkit_policies_len + 1, sizeof(*grown));

		if (!grown) {
			error = -1;
		} else {
			gitkit_policies = grown;
			slot = &gitkit_policies[gitkit_policies_len++];
			slot->repo = repo;
			slot->cb = cb;
			slot->payload = payload;
			slot->retain = retain;
			slot->release = release;
		}
	}

	git_mutex_unlock(lock);

	/* the registration's own reference to what it replaced */
	if (error == 0 && replaced.cb)
		gitkit_policy_done(&replaced);
	return error;
}

int gitkit_config_set_include_callback(
	git_repository *repo, gitkit_config_include_cb cb, void *payload)
{
	return gitkit_config_set_include_policy(repo, cb, payload, NULL, NULL);
}

void gitkit_config_set_thread_include_callback(
	gitkit_config_include_cb cb, void *payload,
	gitkit_config_include_cb *previous_cb, void **previous_payload)
{
	if (previous_cb)
		*previous_cb = gitkit_thread_policy.cb;
	if (previous_payload)
		*previous_payload = gitkit_thread_policy.payload;
	gitkit_thread_policy.cb = cb;
	gitkit_thread_policy.payload = payload;
}

/*
 * repository_patched.c: records the refusal in the calling thread's
 * operation configuration scope, if any — an open libgit2 makes for itself
 * (a submodule's, during status) clears the error it fails with.
 */
extern void gitkit_config_scope__record(int code);

static int gitkit_include_stat(
	const char *path, struct stat *st, int depth, const git_repository *repo)
{
	if (depth >= 0 && depth < GITKIT_INCLUDE_DEPTHS)
		gitkit_include_paths[depth] = path;

	if (depth > 0) {
		gitkit_include_policy policy = gitkit_policy_for(repo);
		const char *including = depth - 1 < GITKIT_INCLUDE_DEPTHS ?
			gitkit_include_paths[depth - 1] : NULL;

		int refused = policy.cb &&
			policy.cb(path, including, depth, policy.payload) != 0;

		gitkit_policy_done(&policy);
		if (refused) {
			git_error_set(GIT_ERROR_CONFIG, "include of '%s' is not authorised", path);
			gitkit_config_scope__record(-1);
			gitkit_include_refused = 1;
			return -1;
		}
	}

	return p_stat(path, st);
}

#undef p_stat
#define p_stat(path, st) gitkit_include_stat(path, st, depth, repo)

/*
 * config_list.h declares git_config_list_get_unique(), so that declaration
 * is what gives the renamed function its prototype here; it's defined below
 * the include.
 */
#define git_config_list_get_unique gitkit_config_list_get_unique_own
#define git_fs_path_set_error gitkit_fs_path_set_error
#define git_config_backend_from_file gitkit_config_backend_from_file_unwrapped
#define git_filebuf_commit(file) gitkit_created_watch_commit(file)
#define git_config_parse gitkit_file_parse
#include "config_file.c"
#undef git_config_parse
#undef git_filebuf_commit
#undef git_config_backend_from_file
#undef git_fs_path_set_error
#undef git_config_list_get_unique
#undef p_stat

extern int git_fs_path_set_error(int errno_value, const char *path, const char *action);

/* The wrapper lends its owned manifest only while its backend is parsing or
 * refreshing. A repository scope can end before the backend is freed. */
typedef struct {
	git_config_backend parent;
	git_config_backend *inner;
	gitkit_condition_context *context;
	char *command_text;
	size_t command_len, generation;
	int refresh_failed;
} gitkit_condition_backend;

static int condition_backend_parse(gitkit_condition_backend *backend, git_config_level_t level, const git_repository *repo);
static int command_refresh(gitkit_condition_backend *backend);
static int condition_backend_refresh(gitkit_condition_backend *backend);

static int gitkit_read_variable(git_config_parser *, const char *, const char *,
	const char *, const char *, size_t, void *);

static int gitkit_read_include(config_file_parse_data *data, const char *target)
{
	git_str path = GIT_STR_INIT, content = GIT_STR_INIT;
	git_config_parser reader = GIT_CONFIG_PARSER_INIT;
	config_file_parse_data child = *data;
	config_file *file;
	struct stat st;
	int error;
	if ((error = gitkit_condition_path(&path, target, data->file->path)) < 0)
		goto done;
	child.depth++;
	if ((error = gitkit_config_authorize(data->repo, path.ptr, data->file->path, child.depth)) < 0)
		goto done;
	file = git_array_alloc(data->file->includes);
	if (!file) { error = -1; goto done; }
	memset(file, 0, sizeof(*file));
	file->path = git_str_detach(&path);
	child.file = file;
	/* Authorisation precedes the first stat, even for a missing target. */
	if (gitkit_real_stat(file->path, &st) < 0) {
		if (errno == ENOENT || errno == ENOTDIR) { error = 0; goto done; }
		error = git_fs_path_set_error(errno, file->path, "stat");
		goto done;
	}
	if (child.depth > GITKIT_MAX_INCLUDE_DEPTH) {
		error = gitkit_condition_depth_exceeded(file->path, data->file->path);
		goto done;
	}
	if ((error = git_futils_readbuffer(&content, file->path)) < 0)
		goto done;
	git_futils_filestamp_set_from_stat(&file->stamp, &st);
	if ((error = git_hash_buf(file->checksum, content.ptr, content.size, GIT_HASH_ALGORITHM_SHA256)) < 0 ||
	    (error = git_config_parser_init(&reader, file->path, content.ptr, content.size)) < 0)
		goto done;
	error = git_config_parse(&reader, NULL, gitkit_read_variable, NULL, NULL, &child);
done:
	git_config_parser_dispose(&reader);
	git_str_dispose(&path);
	git_str_dispose(&content);
	return error;
}

static int gitkit_read_variable(git_config_parser *parser, const char *section, const char *variable,
	const char *value, const char *line, size_t line_len, void *payload)
{
	config_file_parse_data *data = payload;
	git_config_entry entry = {0};
	git_str name = GIT_STR_INIT;
	const char *c;
	int error, matches, unexpanded;
	GIT_UNUSED(parser); GIT_UNUSED(line); GIT_UNUSED(line_len);
	/* A command element's marker is stored under Git's name, `path`. */
	if ((unexpanded = !data->file->path && !git__strcasecmp(variable, GITKIT_UNEXPANDED_PATH)))
		variable = "path";
	if (section &&(git_str_puts(&name, section) < 0 || git_str_putc(&name, '.') < 0))
		return -1;
	for (c = variable; *c; c++) git_str_putc(&name, git__tolower(*c));
	if (git_str_oom(&name)) { git_str_dispose(&name); return -1; }
	entry.name = name.ptr;
	entry.value = value;
	entry.backend_type = data->file->path ? "file" : "command line";
	entry.origin_path = data->file->path;
	entry.level = data->level;
	entry.include_depth = data->depth;
	error = git_config_list_dup_entry(data->config_list, &entry);
	if (error < 0)
		goto done;
	if (!strcmp(entry.name, "include.path")) {
		error = unexpanded ? gitkit_condition_unexpanded(value) : gitkit_read_include(data, value);
	} else if (section && !git__prefixcmp(section, "includeif.") && !git__strcasecmp(variable, "path")) {
		error = gitkit_condition_match(&matches, gitkit_condition_current(), section + 10, data->file->path);
		if (!error && matches)
			error = unexpanded ? gitkit_condition_unexpanded(value) : gitkit_read_include(data, value);
	}
done:
	git_str_dispose(&name);
	return error;
}

static int gitkit_file_parse(git_config_parser *parser, git_config_parser_section_cb section,
	git_config_parser_variable_cb variable, git_config_parser_comment_cb comment,
	git_config_parser_eof_cb eof, void *payload)
{
	config_file_parse_data *data = NULL;
	int error;
	if (variable == read_on_variable) {
		data = payload;
		if (!data->depth) gitkit_condition_invalidate(gitkit_condition_current());
		variable = gitkit_read_variable;
	}
	error = git_config_parse(parser, section, variable, comment, eof, payload);
	if (error < 0 && data && !data->depth) {
		/* A refused include can fail before it has a child filestamp. Leave
		 * the root dirty so lifting a refusal retries the complete read. */
		memset(&data->file->stamp, 0, sizeof(data->file->stamp));
		memset(data->file->checksum, 0, sizeof(data->file->checksum));
	}
	return error;
}

static int condition_backend_open(git_config_backend *backend, git_config_level_t level, const git_repository *repo)
{
	gitkit_condition_backend *b = (gitkit_condition_backend *)backend;
	gitkit_condition_context *previous;
	int error;
	if (!b->context) {
		b->context = gitkit_condition_new(repo);
		if (!b->context || gitkit_condition_source_add(b->context,
		    ((config_file_backend *)b->inner)->file.path, NULL, 0, level, 0, 0) < 0)
			return -1;
	}
	previous = gitkit_condition_enter(b->context);
	b->inner->cfg = backend->cfg;
	/* A cached clone has a complete list already; its next refresh still
	 * parses with the newly installed prospective manifest. */
	error = b->command_text ? condition_backend_parse(b, level, repo) :
		(((config_file_backend *)b->inner)->config_list ? 0 : b->inner->open(b->inner, level, repo));
	if (!error) b->generation = b->context->generation;
	gitkit_condition_enter(previous);
	return error;
}

#define CONDITION_CALL(expression) \
	gitkit_condition_backend *b = (gitkit_condition_backend *)backend; \
	gitkit_condition_context *previous = gitkit_condition_enter(b->context); \
	int error = condition_backend_refresh(b); \
	if (!error) error = (expression); \
	if (!error || error == GIT_ENOTFOUND) b->generation = b->context->generation; \
	gitkit_condition_enter(previous); \
	return error

static int condition_backend_get(git_config_backend *backend, const char *key, git_config_backend_entry **out)
{
	*out = NULL;
	CONDITION_CALL(b->inner->get(b->inner, key, out));
}
static int condition_backend_set(git_config_backend *backend, const char *key, const char *value)
{ CONDITION_CALL(b->inner->set(b->inner, key, value)); }
static int condition_backend_del(git_config_backend *backend, const char *key)
{ CONDITION_CALL(b->inner->del(b->inner, key)); }
static int condition_backend_set_multivar(git_config_backend *backend, const char *key, const char *regexp, const char *value)
{ CONDITION_CALL(b->inner->set_multivar(b->inner, key, regexp, value)); }
static int condition_backend_del_multivar(git_config_backend *backend, const char *key, const char *regexp)
{ CONDITION_CALL(b->inner->del_multivar(b->inner, key, regexp)); }
static int condition_backend_iterator(git_config_iterator **out, git_config_backend *backend)
{ CONDITION_CALL(b->inner->iterator(out, b->inner)); }
static int condition_backend_snapshot(git_config_backend **out, git_config_backend *backend)
{
	/* Snapshot construction defers its read until open(). Keep the wrapped
	 * backend as its source so that deferred iterator also enters context. */
	return git_config_backend_snapshot(out, backend);
}
static int condition_backend_lock(git_config_backend *backend)
{ CONDITION_CALL(b->inner->lock(b->inner)); }
static int condition_backend_unlock(git_config_backend *backend, int success)
{ CONDITION_CALL(b->inner->unlock(b->inner, success)); }
#undef CONDITION_CALL

static void condition_backend_free(git_config_backend *backend)
{
	gitkit_condition_backend *b = (gitkit_condition_backend *)backend;
	b->inner->free(b->inner);
	gitkit_condition_free(b->context);
	git__free(b->command_text);
	git__free(b);
}

int git_config_backend_from_file(git_config_backend **out, const char *path)
{
	gitkit_condition_backend *b = git__calloc(1, sizeof(*b));
	int error;
	GIT_ERROR_CHECK_ALLOC(b);
	if ((error = gitkit_config_backend_from_file_unwrapped(&b->inner, path)) < 0) { git__free(b); return error; }
	b->context = gitkit_condition_current();
	gitkit_condition_retain(b->context);
	b->parent.version = GIT_CONFIG_BACKEND_VERSION;
	b->parent.open = condition_backend_open;
	b->parent.get = condition_backend_get;
	b->parent.set = condition_backend_set;
	b->parent.del = condition_backend_del;
	b->parent.set_multivar = condition_backend_set_multivar;
	b->parent.del_multivar = condition_backend_del_multivar;
	b->parent.iterator = condition_backend_iterator;
	b->parent.snapshot = condition_backend_snapshot;
	b->parent.lock = condition_backend_lock;
	b->parent.unlock = condition_backend_unlock;
	b->parent.free = condition_backend_free;
	*out = &b->parent;
	return 0;
}

const char *gitkit_config_backend_path(git_config_backend *backend)
{
	if (backend->open != condition_backend_open)
		return NULL;
	return ((config_file_backend *)((gitkit_condition_backend *)backend)->inner)->file.path;
}

gitkit_condition_context *gitkit_config_backend_context(git_config_backend *backend)
{
	GIT_ASSERT_WITH_RETVAL(backend->open == condition_backend_open, NULL);
	return ((gitkit_condition_backend *)backend)->context;
}

int gitkit_config_backend_hasconfig(git_config_backend *backend)
{
	gitkit_condition_backend *b = (gitkit_condition_backend *)backend;
	return backend->open == condition_backend_open && b->context && b->context->hasconfig;
}

static int clone_file(config_file *out, const config_file *source)
{
	config_file *include, *copy;
	uint32_t i;
	*out = *source;
	out->path = git__strdup(source->path);
	git_array_init(out->includes);
	GIT_ERROR_CHECK_ALLOC(out->path);
	git_array_foreach(source->includes, i, include) {
		copy = git_array_alloc(out->includes);
		GIT_ERROR_CHECK_ALLOC(copy);
		if (clone_file(copy, include) < 0)
			return -1;
	}
	return 0;
}

int gitkit_config_backend_clone(git_config_backend **out, git_config_backend *backend)
{
	gitkit_condition_backend *source = (gitkit_condition_backend *)backend, *copy;
	config_file_backend *from = (config_file_backend *)source->inner, *to;
	int error;
	if ((error = git_config_backend_from_file(out, from->file.path)) < 0)
		return error;
	copy = (gitkit_condition_backend *)*out;
	to = (config_file_backend *)copy->inner;
	config_file_clear(&to->file);
	memset(&to->file, 0, sizeof(to->file));
	if ((error = clone_file(&to->file, &from->file)) < 0) {
		copy->parent.free(*out);
		*out = NULL;
		return error;
	}
	to->config_list = from->config_list;
	git_config_list_incref(to->config_list);
	to->repo = from->repo;
	to->level = from->level;
	to->parent.readonly = from->parent.readonly;
	copy->parent.readonly = backend->readonly;
	return 0;
}

/* Reparse into a temporary list and include tree. A URL-source generation
 * change uses this for ordinary files too, even if their own file is unchanged. */
static int condition_backend_parse(gitkit_condition_backend *backend, git_config_level_t level, const git_repository *repo)
{
	config_file_backend *b = (config_file_backend *)backend->inner;
	git_config_list *list = NULL, *old;
	config_file file = {0};
	git_str content = GIT_STR_INIT;
	git_config_parser parser = GIT_CONFIG_PARSER_INIT;
	config_file_parse_data data = {0};
	struct stat st;
	const char *text = backend->command_text;
	size_t len = backend->command_len;
	int error;
	data.repo = repo;
	data.file = &file;
	data.level = level;
	gitkit_condition_invalidate(backend->context);
	if ((error = git_config_list_new(&list)) < 0)
		goto done;
	if (!backend->command_text) {
		file.path = git__strdup(b->file.path);
		if (!file.path) { error = -1; goto done; }
		if (gitkit_real_stat(file.path, &st) < 0) {
			if (errno != ENOENT && errno != ENOTDIR) {
				error = git_fs_path_set_error(errno, file.path, "stat");
				goto done;
			}
			text = "";
			len = 0;
		} else {
			if ((error = git_futils_readbuffer(&content, file.path)) < 0)
				goto done;
			git_futils_filestamp_set_from_stat(&file.stamp, &st);
			if ((error = git_hash_buf(file.checksum, content.ptr, content.size, GIT_HASH_ALGORITHM_SHA256)) < 0)
				goto done;
			text = content.ptr;
			len = content.size;
		}
	}
	if ((error = git_config_parser_init(&parser, file.path, text, len)) < 0)
		goto done;
	data.config_list = list;
	if ((error = git_config_parse(&parser, NULL, gitkit_read_variable, NULL, NULL, &data)) < 0 ||
	    (error = git_mutex_lock(&b->values_mutex)) < 0)
		goto done;
	old = b->config_list;
	b->config_list = list;
	list = NULL;
	git_mutex_unlock(&b->values_mutex);
	git_config_list_free(old);
	config_file_clear(&b->file);
	b->file = file;
	memset(&file, 0, sizeof(file));
	b->repo = repo;
	b->level = level;
	backend->generation = backend->context->generation;
done:
	git_config_parser_dispose(&parser);
	git_str_dispose(&content);
	git_config_list_free(list);
	config_file_clear(&file);
	backend->refresh_failed = error < 0;
	return error;
}

static int command_refresh(gitkit_condition_backend *backend)
{
	config_file_backend *b = (config_file_backend *)backend->inner;
	config_file *include;
	uint32_t i;
	int error, modified;
	if (!backend->command_text)
		return 0;
	if (backend->refresh_failed)
		return condition_backend_parse(backend, b->level, b->repo);
	git_array_foreach(b->file.includes, i, include) {
		error = config_file_is_modified(&modified, include);
		if (error == GIT_ENOTFOUND) { git_error_clear(); continue; }
		if (error < 0) return error;
		if (modified) return condition_backend_parse(backend, b->level, b->repo);
	}
	return 0;
}

static int condition_backend_refresh(gitkit_condition_backend *backend)
{
	gitkit_condition_context *ctx = backend->context;
	config_file_backend *inner = (config_file_backend *)backend->inner;
	int error;
	if (ctx->building || ctx->collecting || ctx->refreshing)
		return 0;
	if ((error = gitkit_condition_check(ctx)) < 0)
		return error;
	if (ctx->hasconfig && backend->generation != ctx->generation) {
		/* Re-evaluating a dependent does not itself change the URL sources:
		 * otherwise dependent backends would invalidate one another forever. */
		ctx->refreshing++;
		error = condition_backend_parse(backend, inner->level, inner->repo);
		ctx->refreshing--;
		return error;
	}
	return command_refresh(backend);
}

int gitkit_config_backend_command(git_config_backend **out, const char *text, size_t len, git_config_level_t level)
{
	gitkit_condition_backend *backend;
	config_file_backend *inner;
	int error;
	GIT_UNUSED(level);
	if ((error = git_config_backend_from_file(out, "")) < 0)
		return error;
	backend = (gitkit_condition_backend *)*out;
	inner = (config_file_backend *)backend->inner;
	git__free(inner->file.path);
	inner->file.path = NULL;
	inner->parent.readonly = backend->parent.readonly = 1;
	backend->command_text = git__substrdup(text, len);
	backend->command_len = len;
	if (!backend->command_text) { backend->parent.free(*out); *out = NULL; return -1; }
	return 0;
}

int gitkit_fs_path_set_error(int errno_value, const char *path, const char *action)
{
	if (gitkit_include_refused) {
		gitkit_include_refused = 0;
		return -1;
	}
	return git_fs_path_set_error(errno_value, path, action);
}

int gitkit_config_list_get_unique_own(
	git_config_list_entry **out,
	git_config_list *config_list,
	const char *key)
{
	git_config_iterator *iter;
	git_config_backend_entry *backend_entry;
	git_config_list_entry *found = NULL;
	int error;

	if ((error = git_config_list_iterator_new(&iter, config_list)) < 0)
		return error;

	while ((error = iter->next(&backend_entry, iter)) == 0) {
		const git_config_entry *entry = &backend_entry->entry;

		if (entry->include_depth != 0 || strcmp(entry->name, key) != 0)
			continue;

		if (found) {
			git_error_set(GIT_ERROR_CONFIG, "entry is not unique due to being a multivar");
			error = -1;
			goto done;
		}

		found = GIT_CONTAINER_OF(backend_entry, git_config_list_entry, base);
	}

	if (error != GIT_ITEROVER)
		goto done;

	if (!found) {
		error = GIT_ENOTFOUND;
		goto done;
	}

	*out = found;
	error = 0;

done:
	/* the entries live as long as the list, which the caller holds */
	iter->free(iter);
	return error;
}
