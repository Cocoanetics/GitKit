/*
 * GitKit shim — remove what a failed clone or worktree add provably made,
 * and nothing else.
 *
 * libgit2 rolls nothing back when a repository's init or a worktree's add
 * fails part way, for example in the new repository's own open, whose
 * config load can refuse an include. What it wrote stays, and a retry into
 * the same place fails. Removing it is only safe for what this operation
 * made: by the time the error comes back, host code (the include policy)
 * has run and other writers may have added to, replaced or linked from the
 * same paths.
 *
 * So a directory is removed only when it was created exclusively by this
 * operation (its device and inode recorded then), is still that directory,
 * and holds nothing but what the operation writes there — by name and type,
 * and, where the operation recorded them, the very files it wrote, unchanged
 * (device, inode and ctime). It is renamed to a private name next to it
 * first, in one step, so it can't change or be replaced while it is checked;
 * if anything doesn't match, it is renamed back and kept. Neither rename
 * replaces what is at its destination (renameatx_np / renameat2 no-replace;
 * elsewhere nothing is renamed): if something took the name meanwhile, it
 * stays, and the creation stays under its private name. Entries are
 * opened relative to their directory and never through a symlink, and a
 * directory is removed only while empty.
 *
 * Here: what an init records and when, the init itself and the created
 * branch's removal, and the POSIX identity and removal. Windows has its
 * own identity and removal, by handle and file ID (created_dir_win32.c).
 */
#include "common.h"
#include "repository.h"
#include "rand.h"
#include "refs.h"
#include "config.h"
#include "git2/branch.h"
#include "gitkit_created_dir.h"

static GITKIT_THREAD_LOCAL gitkit_created_restore_hook gitkit_restore_hook;

void gitkit_created_set_restore_hook(gitkit_created_restore_hook hook)
{
	gitkit_restore_hook = hook;
}

void gitkit_created_before_restore(const char *path)
{
	if (gitkit_restore_hook)
		gitkit_restore_hook(path);
}

static GITKIT_THREAD_LOCAL gitkit_created_restore_hook gitkit_delete_hook;

void gitkit_created_set_delete_hook(gitkit_created_restore_hook hook)
{
	gitkit_delete_hook = hook;
}

void gitkit_created_before_delete(const char *path)
{
	if (gitkit_delete_hook)
		gitkit_delete_hook(path);
}

#ifndef GIT_WIN32
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#if defined(__APPLE__)
#  define GITKIT_CTIME_NSEC(st) ((st)->st_ctimespec.tv_nsec)
#else
#  define GITKIT_CTIME_NSEC(st) ((st)->st_ctim.tv_nsec)
#endif

#define GITKIT_DIR_FLAGS (O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)

#if defined(__linux__) || defined(__ANDROID__)
#  include <sys/syscall.h>
#  ifndef RENAME_NOREPLACE
#    define RENAME_NOREPLACE (1 << 0)
#  endif
#endif

/*
 * renameat() that fails (EEXIST) instead of replacing what is at `to`:
 * plain rename silently replaces an empty directory, which may be someone
 * else's. Where the platform or file system can't, nothing is renamed.
 */
static int gitkit_rename_noreplace(int fromfd, const char *from, int tofd, const char *to)
{
#if defined(__APPLE__)
	return renameatx_np(fromfd, from, tofd, to, RENAME_EXCL);
#elif (defined(__linux__) || defined(__ANDROID__)) && defined(SYS_renameat2)
	return (int)syscall(SYS_renameat2, fromfd, from, tofd, to, RENAME_NOREPLACE);
#else
	GIT_UNUSED(fromfd);
	GIT_UNUSED(from);
	GIT_UNUSED(tofd);
	GIT_UNUSED(to);
	errno = ENOSYS;
	return -1;
#endif
}

static void gitkit_id_from_stat(gitkit_file_id *out, const struct stat *st)
{
	out->present = 1;
	out->dev = (uint64_t)st->st_dev;
	out->ino = (uint64_t)st->st_ino;
	out->ctime_sec = (int64_t)st->st_ctime;
	out->ctime_nsec = (int64_t)GITKIT_CTIME_NSEC(st);
}

void gitkit_created_id(gitkit_file_id *out, const char *path)
{
	struct stat st;

	memset(out, 0, sizeof(*out));
	if (lstat(path, &st) == 0)
		gitkit_id_from_stat(out, &st);
	else if (errno != ENOENT && errno != ENOTDIR)
		out->unprovable = 1;
}

int gitkit_created_same(const gitkit_file_id *id, const gitkit_file_id *now, int with_change)
{
	return id->present && now->present &&
		now->dev == id->dev && now->ino == id->ino &&
		(!with_change ||
		 (now->ctime_sec == id->ctime_sec && now->ctime_nsec == id->ctime_nsec));
}

/* A directory's ctime changes with its entries, and with the rename. */
static int gitkit_is_id(const struct stat *st, const gitkit_file_id *id, int with_ctime)
{
	return id->present &&
		(uint64_t)st->st_dev == id->dev &&
		(uint64_t)st->st_ino == id->ino &&
		(!with_ctime ||
		 ((int64_t)st->st_ctime == id->ctime_sec &&
		  (int64_t)GITKIT_CTIME_NSEC(st) == id->ctime_nsec));
}

/* The names in `fd`, read before any is removed; NULL-terminated. */
static char **gitkit_list_dir(int fd)
{
	DIR *dir;
	struct dirent *entry;
	char **names = NULL, **grown;
	size_t len = 0, cap = 0;
	int dup_fd = dup(fd);

	if (dup_fd < 0 || (dir = fdopendir(dup_fd)) == NULL) {
		if (dup_fd >= 0)
			close(dup_fd);
		return NULL;
	}
	/* The duplicate shares the offset an earlier listing left at the end. */
	rewinddir(dir);
	while ((entry = readdir(dir)) != NULL) {
		if (!strcmp(entry->d_name, ".") || !strcmp(entry->d_name, ".."))
			continue;
		if (len + 2 > cap) {
			cap = cap ? cap * 2 : 8;
			if ((grown = realloc(names, cap * sizeof(char *))) == NULL)
				goto fail;
			names = grown;
		}
		if ((names[len] = strdup(entry->d_name)) == NULL)
			goto fail;
		names[++len] = NULL;
	}
	closedir(dir);
	if (names == NULL)
		names = calloc(1, sizeof(char *));
	return names;

fail:
	closedir(dir);
	while (len > 0)
		free(names[--len]);
	free(names);
	return NULL;
}

static void gitkit_free_names(char **names)
{
	size_t i;

	for (i = 0; names && names[i]; i++)
		free(names[i]);
	free(names);
}

static const gitkit_created_entry *gitkit_find_entry(
	const gitkit_created_entry *entries, size_t len, const char *path)
{
	size_t i;

	for (i = 0; i < len; i++)
		if (!strcmp(entries[i].path, path))
			return &entries[i];
	return NULL;
}

/*
 * Checks the directory open at `fd` (at `prefix`) and, when `remove` is
 * set, removes what it checked, children first. 0 when everything in it
 * is the operation's (and, removing, is gone).
 */
static int gitkit_walk(
	int fd, const char *prefix,
	const gitkit_created_entry *entries, size_t len, int remove)
{
	char **names = gitkit_list_dir(fd);
	char path[4096];
	const gitkit_created_entry *entry;
	struct stat st, opened;
	size_t i;
	int sub, error = 0;

	if (names == NULL)
		return -1;
	for (i = 0; !error && names[i]; i++) {
		if (snprintf(path, sizeof(path), "%s%s%s", prefix, *prefix ? "/" : "",
		             names[i]) >= (int)sizeof(path) ||
		    (entry = gitkit_find_entry(entries, len, path)) == NULL ||
		    fstatat(fd, names[i], &st, AT_SYMLINK_NOFOLLOW) < 0 ||
		    (entry->is_dir ? !S_ISDIR(st.st_mode) : !S_ISREG(st.st_mode)) ||
		    (entry->id && !gitkit_is_id(&st, entry->id, !entry->is_dir))) {
			error = -1;
			break;
		}
		if (entry->is_dir) {
			if ((sub = openat(fd, names[i], GITKIT_DIR_FLAGS)) < 0)
				error = -1;
			else {
				if (fstat(sub, &opened) < 0 ||
				    opened.st_dev != st.st_dev || opened.st_ino != st.st_ino)
					error = -1;
				else
					error = gitkit_walk(sub, path, entries, len, remove);
				close(sub);
			}
			if (!error && remove && unlinkat(fd, names[i], AT_REMOVEDIR) < 0)
				error = -1;
		} else if (remove && unlinkat(fd, names[i], 0) < 0) {
			error = -1;
		}
	}
	gitkit_free_names(names);
	return error;
}

/* One directory being rolled back: where it was, and its private name. */
typedef struct {
	int parent;
	char name[256];
	char quarantine[256];
	int moved;
} gitkit_quarantine;

/* Renames `dir` to a private name next to it if it still is `dir->id`. */
static int gitkit_quarantine_dir(gitkit_quarantine *q, const gitkit_created_dir *dir)
{
	char parent_path[4096];
	const char *slash;
	size_t path_len = strlen(dir->path), name_len;
	struct stat st;

	if (!dir->id->present)
		return -1;
	while (path_len > 1 && dir->path[path_len - 1] == '/')
		path_len--;
	if (path_len >= sizeof(parent_path))
		return -1;
	memcpy(parent_path, dir->path, path_len);
	parent_path[path_len] = '\0';
	if ((slash = strrchr(parent_path, '/')) == NULL)
		return -1;
	name_len = strlen(slash + 1);
	if (name_len == 0 || name_len >= sizeof(q->name))
		return -1;
	memcpy(q->name, slash + 1, name_len + 1);
	parent_path[slash == parent_path ? 1 : (size_t)(slash - parent_path)] = '\0';
	snprintf(q->quarantine, sizeof(q->quarantine), ".%.200s.gitkit-rollback-%016llx",
	         q->name, (unsigned long long)git_rand_next());

	if ((q->parent = open(parent_path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)) < 0)
		return -1;
	if (fstatat(q->parent, q->name, &st, AT_SYMLINK_NOFOLLOW) < 0 ||
	    !S_ISDIR(st.st_mode) || !gitkit_is_id(&st, dir->id, 0) ||
	    gitkit_rename_noreplace(q->parent, q->name, q->parent, q->quarantine) < 0)
		return -1;
	q->moved = 1;
	return 0;
}

/* Checks the quarantined directory (and, `remove` set, removes it). */
static int gitkit_quarantined_walk(
	const gitkit_quarantine *q, const gitkit_created_dir *dir, int remove)
{
	struct stat st;
	int fd, error = -1;

	if ((fd = openat(q->parent, q->quarantine, GITKIT_DIR_FLAGS)) < 0)
		return -1;
	if (fstat(fd, &st) == 0 && gitkit_is_id(&st, dir->id, 0) &&
	    gitkit_walk(fd, "", dir->entries, dir->entries_len, remove) == 0)
		error = 0;
	close(fd);
	if (!error && remove && unlinkat(q->parent, q->quarantine, AT_REMOVEDIR) < 0)
		error = -1;
	return error;
}

int gitkit_remove_created_dirs(const gitkit_created_dir *dirs, size_t len)
{
	gitkit_quarantine q[GITKIT_CREATED_DIRS_MAX];
	git_error *saved = NULL;
	size_t i;
	int result = GITKIT_CREATED_REMOVED, error = 0;

	if (len == 0 || len > GITKIT_CREATED_DIRS_MAX)
		return GITKIT_CREATED_KEPT;
	memset(q, 0, sizeof(q));
	for (i = 0; i < len; i++)
		q[i].parent = -1;

	git_error_save(&saved);
	/* All or nothing: every directory out of reach and checked first. */
	for (i = 0; !error && i < len; i++)
		error = gitkit_quarantine_dir(&q[i], &dirs[i]);
	for (i = 0; !error && i < len; i++)
		error = gitkit_quarantined_walk(&q[i], &dirs[i], 0);
	for (i = 0; !error && i < len; i++) {
		/* Only what appeared since the check can stop this. */
		if (gitkit_quarantined_walk(&q[i], &dirs[i], 1) == 0)
			q[i].moved = 0;
		else
			error = -1;
	}

	for (i = 0; i < len; i++) {
		if (q[i].moved) {
			if (result == GITKIT_CREATED_REMOVED)
				result = GITKIT_CREATED_KEPT;
			gitkit_created_before_restore(dirs[i].path);
			/* Whatever took its name meanwhile is not replaced: it stays,
			 * and so does this, under its private name. */
			if (gitkit_rename_noreplace(q[i].parent, q[i].quarantine,
			                            q[i].parent, q[i].name) < 0)
				result = GITKIT_CREATED_STRANDED;
		}
		if (q[i].parent >= 0)
			close(q[i].parent);
	}
	if (error && result == GITKIT_CREATED_REMOVED)
		result = GITKIT_CREATED_KEPT;
	git_error_restore(saved);
	return result;
}

void gitkit_created_trace(char *out, size_t len)
{
	if (out && len)
		out[0] = '\0';
}

#endif /* GIT_WIN32 */

/* What git_repository_init() writes in a new git directory: its internal
 * template (repo_template.h), then the config and HEAD. */
static const gitkit_created_entry gitkit_init_layout[] = {
	{ "objects", 1, NULL }, { "objects/info", 1, NULL }, { "objects/pack", 1, NULL },
	{ "refs", 1, NULL }, { "refs/heads", 1, NULL }, { "refs/tags", 1, NULL },
	{ "hooks", 1, NULL }, { "info", 1, NULL },
	{ "description", 0, NULL }, { "hooks/README.sample", 0, NULL },
	{ "info/exclude", 0, NULL }, { "config", 0, NULL }, { "HEAD", 0, NULL },
};

#define GITKIT_INIT_LAYOUT_LEN ARRAY_SIZE(gitkit_init_layout)

/*
 * What an init wrote, recorded each time it is about to read config, the
 * only point where it runs host code (the include policy; the repository.c
 * shim calls gitkit_created_watch_notify() there). A file is the init's
 * as first recorded, before any host code could touch it; changed or gone
 * at a later record, it is no longer provably the init's.
 */
typedef struct {
	const char *git_dir;
	gitkit_file_id ids[GITKIT_INIT_LAYOUT_LEN];
} gitkit_created_watch;

static GITKIT_THREAD_LOCAL gitkit_created_watch *gitkit_current_watch;

void gitkit_created_watch_notify(void)
{
	gitkit_created_watch *watch = gitkit_current_watch;
	gitkit_file_id now;
	git_str path = GIT_STR_INIT;
	size_t i;

	if (watch == NULL)
		return;
	for (i = 0; i < GITKIT_INIT_LAYOUT_LEN; i++) {
		gitkit_file_id *id = &watch->ids[i];
		int is_dir = gitkit_init_layout[i].is_dir;

		if (id->unprovable)
			continue;
		if (git_str_joinpath(&path, watch->git_dir, gitkit_init_layout[i].path) < 0) {
			memset(id, 0, sizeof(*id));
			id->unprovable = 1;	/* never recorded again */
			continue;
		}
		gitkit_created_id(&now, path.ptr);
		if (!id->present) {
			*id = now;	/* first seen now, or still absent */
		} else if (!gitkit_created_same(id, &now, !is_dir)) {
			memset(id, 0, sizeof(*id));
			id->unprovable = 1;	/* changed since */
		}
	}
	git_str_dispose(&path);
}

int gitkit_repository_init_created(
	git_repository **out, const char *path, unsigned bare)
{
	git_repository_init_options opts = GIT_REPOSITORY_INIT_OPTIONS_INIT;
	git_str parent = GIT_STR_INIT, dotgit = GIT_STR_INIT;
	gitkit_file_id root_id = { 0 }, dotgit_id = { 0 };
	gitkit_created_watch watch, *previous = gitkit_current_watch;
	gitkit_created_entry entries[GITKIT_INIT_LAYOUT_LEN + 1];
	char prefixed[GITKIT_INIT_LAYOUT_LEN][64];
	struct stat st;
	size_t i, len = 0;
	int error;

	/* git_repository_init()'s, refusing a repository someone else made. */
	opts.flags = GIT_REPOSITORY_INIT_MKPATH | GIT_REPOSITORY_INIT_NO_REINIT;
	if (bare)
		opts.flags |= GIT_REPOSITORY_INIT_BARE;

	/* The directories the init would make, made here, exclusively. */
	if (p_lstat(path, &st) < 0 && errno == ENOENT) {
		if (git_fs_path_dirname_r(&parent, path) >= 0)
			git_futils_mkdir(parent.ptr, 0777, GIT_MKDIR_PATH);
		if (p_mkdir(path, 0777) == 0)
			gitkit_created_id(&root_id, path);
	}
	if (!bare && git_str_joinpath(&dotgit, path, ".git") == 0 &&
	    p_mkdir(dotgit.ptr, 0777) == 0)
		gitkit_created_id(&dotgit_id, dotgit.ptr);
	git_error_clear();

	memset(&watch, 0, sizeof(watch));
	watch.git_dir = bare ? path : dotgit.ptr;
	gitkit_current_watch = &watch;
	error = git_repository_init_ext(out, path, &opts);
	gitkit_current_watch = previous;

	/* Each file of the layout only as the init wrote it. */
	if (!bare)
		entries[len++] = (gitkit_created_entry){ ".git", 1, &dotgit_id };
	for (i = 0; i < GITKIT_INIT_LAYOUT_LEN; i++, len++) {
		entries[len] = gitkit_init_layout[i];
		entries[len].id = &watch.ids[i];
		if (!bare && root_id.present) {
			snprintf(prefixed[i], sizeof(prefixed[i]), ".git/%s",
			         gitkit_init_layout[i].path);
			entries[len].path = prefixed[i];
		}
	}

	if (error < 0 && root_id.present && (bare || dotgit_id.present)) {
		gitkit_created_dir root = { path, &root_id, entries, len };

		gitkit_remove_created_dirs(&root, 1);
	} else if (error < 0 && dotgit_id.present) {
		gitkit_created_dir git_dir = { dotgit.ptr, &dotgit_id, entries + 1, len - 1 };

		gitkit_remove_created_dirs(&git_dir, 1);
	}

	git_str_dispose(&parent);
	git_str_dispose(&dotgit);
	return error;
}

/*
 * Deletes `branch.<short>.<var>` only where it still is `value` — under
 * the config file's lock, which the write takes and re-reads the file in.
 * Gone or changed meanwhile, it is someone else's and stays.
 */
static int gitkit_delete_written_var(
	git_config *config, const char *short_name, const char *var, const char *value)
{
	git_str key = GIT_STR_INIT, regexp = GIT_STR_INIT;
	const char *c;
	int error;

	if ((error = git_str_printf(&key, "branch.%s.%s", short_name, var)) < 0 ||
	    (error = git_str_putc(&regexp, '^')) < 0)
		goto done;
	for (c = value; !error && *c; c++) {
		if (strchr("\\^$.|?*+()[]{}", *c))
			error = git_str_putc(&regexp, '\\');
		if (!error)
			error = git_str_putc(&regexp, *c);
	}
	if (error || (error = git_str_putc(&regexp, '$')) < 0)
		goto done;
	error = git_config_delete_multivar(config, key.ptr, regexp.ptr);
	if (error == GIT_ENOTFOUND) {
		git_error_clear();
		error = 0;
	}
done:
	git_str_dispose(&key);
	git_str_dispose(&regexp);
	return error;
}

/*
 * git_branch_delete(), for a branch the operation created, in the other
 * order and narrower: it removes all of `branch.<name>.*` before its
 * compare-and-delete of the ref, so a branch someone moved meanwhile kept
 * its ref but lost its config, and config someone else wrote for the
 * branch went with it. Here the ref goes first, only while it still points
 * where `branch` does; after that only the upstream the operation wrote
 * (`remote`, `merge`; NULL when it wrote none) is removed, and only while
 * it still holds those values.
 */
int gitkit_branch_delete_created(
	git_reference *branch, const char *remote, const char *merge)
{
	git_config *config;
	const char *short_name;
	int error;

	GIT_ASSERT_ARG(branch);

	if (!git_reference_is_branch(branch)) {
		git_error_set(GIT_ERROR_INVALID, "reference '%s' is not a local branch",
		              git_reference_name(branch));
		return -1;
	}
	if (git_branch_is_checked_out(branch)) {
		git_error_set(GIT_ERROR_REFERENCE, "cannot delete branch '%s' as it is "
		              "the current HEAD of a repository", git_reference_name(branch));
		return -1;
	}
	if ((error = git_reference_delete(branch)) < 0)
		return error;
	if (remote == NULL && merge == NULL)
		return 0;

	short_name = git_reference_name(branch) + strlen(GIT_REFS_HEADS_DIR);
	if ((error = git_repository_config__weakptr(&config, git_reference_owner(branch))) < 0)
		return error;
	if (remote && (error = gitkit_delete_written_var(config, short_name, "remote", remote)) < 0)
		return error;
	if (merge)
		error = gitkit_delete_written_var(config, short_name, "merge", merge);
	return error;
}
