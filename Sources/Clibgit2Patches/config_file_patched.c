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
 */
#include "common.h"
#include "posix.h"
#include "thread.h"
#include "git2/sys/config.h"
#include "../CGitKit/include/gitkit_libgit2.h"

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
	git_mutex_unlock(lock);
	return found;
}

int gitkit_config_set_include_callback(
	git_repository *repo, gitkit_config_include_cb cb, void *payload)
{
	git_mutex *lock = gitkit_policy_lock();
	size_t i;
	int error = 0;

	if (!lock)
		return -1;

	git_mutex_lock(lock);

	if (!repo) {
		gitkit_default_policy.cb = cb;
		gitkit_default_policy.payload = payload;
		goto done;
	}

	for (i = 0; i < gitkit_policies_len; i++) {
		if (gitkit_policies[i].repo != repo)
			continue;
		if (cb) {
			gitkit_policies[i].cb = cb;
			gitkit_policies[i].payload = payload;
		} else {
			gitkit_policies[i] = gitkit_policies[--gitkit_policies_len];
		}
		goto done;
	}

	if (cb) {
		gitkit_include_policy *grown = git__reallocarray(
			gitkit_policies, gitkit_policies_len + 1, sizeof(*grown));

		if (!grown) {
			error = -1;
			goto done;
		}
		gitkit_policies = grown;
		gitkit_policies[gitkit_policies_len].repo = repo;
		gitkit_policies[gitkit_policies_len].cb = cb;
		gitkit_policies[gitkit_policies_len].payload = payload;
		gitkit_policies_len++;
	}

done:
	git_mutex_unlock(lock);
	return error;
}

void gitkit_config_set_thread_include_callback(gitkit_config_include_cb cb, void *payload)
{
	gitkit_thread_policy.cb = cb;
	gitkit_thread_policy.payload = payload;
}

static int gitkit_include_stat(
	const char *path, struct stat *st, int depth, const git_repository *repo)
{
	if (depth >= 0 && depth < GITKIT_INCLUDE_DEPTHS)
		gitkit_include_paths[depth] = path;

	if (depth > 0) {
		gitkit_include_policy policy = gitkit_policy_for(repo);
		const char *including = depth - 1 < GITKIT_INCLUDE_DEPTHS ?
			gitkit_include_paths[depth - 1] : NULL;

		if (policy.cb && policy.cb(path, including, depth, policy.payload) != 0) {
			git_error_set(GIT_ERROR_CONFIG, "include of '%s' is not authorised", path);
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
#include "config_file.c"
#undef git_config_backend_from_file
#undef git_fs_path_set_error
#undef git_config_list_get_unique
#undef p_stat

extern int git_fs_path_set_error(int errno_value, const char *path, const char *action);

static int gitkit_config_file_get(
	git_config_backend *cfg, const char *key, git_config_backend_entry **out)
{
	*out = NULL;
	return config_file_get(cfg, key, out);
}

int git_config_backend_from_file(git_config_backend **out, const char *path)
{
	int error = gitkit_config_backend_from_file_unwrapped(out, path);

	if (!error)
		(*out)->get = gitkit_config_file_get;
	return error;
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
