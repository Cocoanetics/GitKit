/*
 * GitKit — removing a directory a failed operation provably created
 * (created_dir.c). Internal to the shims; not a stable API.
 */
#ifndef GITKIT_CREATED_DIR_H
#define GITKIT_CREATED_DIR_H

#include <stddef.h>
#include "../CGitKit/include/gitkit_libgit2.h"

/* One entry the operation may have left in the directory. */
typedef struct {
	const char *path;		/* relative to the directory, '/'-separated */
	int is_dir;
	const gitkit_file_id *id;	/* when set, the entry must still be this file */
} gitkit_created_entry;

/* A directory the operation made exclusively, and what it may hold. */
typedef struct {
	const char *path;
	const gitkit_file_id *id;	/* recorded when it was made */
	const gitkit_created_entry *entries;
	size_t entries_len;
} gitkit_created_dir;

#define GITKIT_CREATED_DIRS_MAX 4

/* What gitkit_remove_created_dirs() did. */
#define GITKIT_CREATED_REMOVED 1	/* the directories are gone */
#define GITKIT_CREATED_KEPT 0		/* kept */
#define GITKIT_CREATED_STRANDED -1	/* kept, one under its private name:
					 * something else took its name */

/* Records `path`'s identity, not following a symlink. */
void gitkit_created_id(gitkit_file_id *out, const char *path);

/*
 * Removes the directories `dirs` (at most GITKIT_CREATED_DIRS_MAX), all or
 * none: each must still be the directory recorded and hold nothing but
 * entries its list names, each of the listed type and, when the entry
 * names one, the very file recorded, unchanged. Each is first renamed to a
 * private name next to it, in one step, so nothing can be added to it or
 * put in its place while they are checked; if any doesn't match, all are
 * renamed back and kept. Neither rename replaces anything (where the
 * platform can't promise that, nothing is renamed): one whose name was
 * taken meanwhile stays under its private name. Something added to one after the check (through a
 * handle opened before) stops the removal there and keeps what is left.
 * Never follows a symlink. Leaves libgit2's last error as it was.
 */
int gitkit_remove_created_dirs(const gitkit_created_dir *dirs, size_t len);

/*
 * Called before each config read on the calling thread: while a GitKit
 * init runs on it, records what the init wrote so far (created_dir.c).
 */
void gitkit_created_watch_notify(void);

#endif /* GITKIT_CREATED_DIR_H */
