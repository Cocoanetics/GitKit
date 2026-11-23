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
 * if anything doesn't match, it is renamed back and kept. Entries are
 * opened relative to their directory and never through a symlink, and a
 * directory is removed only while empty. Windows keeps everything.
 */
#include "common.h"
#include "repository.h"
#include "rand.h"
#include "gitkit_created_dir.h"

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
	    renameat(q->parent, q->name, q->parent, q->quarantine) < 0)
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
			result = GITKIT_CREATED_KEPT;
			if (renameat(q[i].parent, q[i].quarantine, q[i].parent, q[i].name) < 0)
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

int gitkit_repository_init_created(
	git_repository **out, const char *path, unsigned bare)
{
	git_repository_init_options opts = GIT_REPOSITORY_INIT_OPTIONS_INIT;
	git_str parent = GIT_STR_INIT, dotgit = GIT_STR_INIT;
	gitkit_file_id root_id = { 0 }, dotgit_id = { 0 };
	gitkit_created_entry entries[GITKIT_INIT_LAYOUT_LEN + 1];
	char prefixed[GITKIT_INIT_LAYOUT_LEN][64];
	struct stat st;
	size_t i;
	int error;

	/* git_repository_init()'s, refusing a repository someone else made. */
	opts.flags = GIT_REPOSITORY_INIT_MKPATH | GIT_REPOSITORY_INIT_NO_REINIT;
	if (bare)
		opts.flags |= GIT_REPOSITORY_INIT_BARE;

	/* The directories the init would make, made here, exclusively. */
	if (lstat(path, &st) < 0 && errno == ENOENT) {
		if (git_fs_path_dirname_r(&parent, path) >= 0)
			git_futils_mkdir(parent.ptr, 0777, GIT_MKDIR_PATH);
		if (mkdir(path, 0777) == 0)
			gitkit_created_id(&root_id, path);
	}
	if (!bare && git_str_joinpath(&dotgit, path, ".git") == 0 &&
	    mkdir(dotgit.ptr, 0777) == 0)
		gitkit_created_id(&dotgit_id, dotgit.ptr);
	git_error_clear();

	error = git_repository_init_ext(out, path, &opts);

	if (error < 0 && root_id.present && (bare || dotgit_id.present)) {
		size_t len = 0;

		if (!bare)
			entries[len++] = (gitkit_created_entry){ ".git", 1, &dotgit_id };
		for (i = 0; i < GITKIT_INIT_LAYOUT_LEN; i++) {
			entries[len] = gitkit_init_layout[i];
			if (!bare) {
				snprintf(prefixed[i], sizeof(prefixed[i]), ".git/%s",
				         gitkit_init_layout[i].path);
				entries[len].path = prefixed[i];
			}
			len++;
		}
		gitkit_created_dir root = { path, &root_id, entries, len };

		gitkit_remove_created_dirs(&root, 1);
	} else if (error < 0 && dotgit_id.present) {
		gitkit_created_dir git_dir = {
			dotgit.ptr, &dotgit_id, gitkit_init_layout, GITKIT_INIT_LAYOUT_LEN
		};

		gitkit_remove_created_dirs(&git_dir, 1);
	}

	git_str_dispose(&parent);
	git_str_dispose(&dotgit);
	return error;
}

#else /* GIT_WIN32 */

int gitkit_repository_init_created(
	git_repository **out, const char *path, unsigned bare)
{
	return git_repository_init(out, path, bare);
}

void gitkit_created_id(gitkit_file_id *out, const char *path)
{
	GIT_UNUSED(path);
	memset(out, 0, sizeof(*out));
}

int gitkit_remove_created_dirs(const gitkit_created_dir *dirs, size_t len)
{
	GIT_UNUSED(dirs);
	GIT_UNUSED(len);
	return GITKIT_CREATED_KEPT;
}

#endif /* GIT_WIN32 */
