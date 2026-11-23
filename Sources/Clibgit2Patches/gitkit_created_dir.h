/*
 * GitKit — removing a directory a failed operation provably created
 * (created_dir.c; created_dir_win32.c on Windows). Internal to the shims;
 * not a stable API.
 */
#ifndef GITKIT_CREATED_DIR_H
#define GITKIT_CREATED_DIR_H

#include <stddef.h>
#include <stdint.h>
#include "../CGitKit/include/gitkit_libgit2.h"

#if defined(_MSC_VER)
#  define GITKIT_THREAD_LOCAL __declspec(thread)
#else
#  define GITKIT_THREAD_LOCAL __thread
#endif

/*
 * A file's identity, and what proves it unchanged. POSIX: device and
 * inode, and the ctime any change to the file or its metadata moves.
 * Windows: the volume serial number and 128-bit file ID, and the change
 * and last-write times, size, attributes and a digest of the contents.
 */
typedef struct {
	int present;		/* recorded: there, and provable */
	int unprovable;		/* there (or unreadable), but never provable */
	uint64_t dev, ino, ino_hi;
	int64_t ctime_sec, ctime_nsec;
#if defined(_WIN32)
	int64_t write_time;
	uint64_t size;
	uint32_t attributes;
	unsigned char digest[32];
#endif
} gitkit_file_id;

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

/*
 * Records `path`'s identity, not following a symlink or other reparse
 * point. Absent: all zero. There but not provable (a reparse point, a
 * volume without stable file IDs): `unprovable`, and not `present`.
 */
void gitkit_created_id(gitkit_file_id *out, const char *path);

/*
 * Whether `now` is still the file recorded as `id`; with `with_change`,
 * also unchanged since (a directory's own change stamp moves with its
 * entries, so directories are compared without it).
 */
int gitkit_created_same(const gitkit_file_id *id, const gitkit_file_id *now, int with_change);

/*
 * Removes the directories `dirs` (at most GITKIT_CREATED_DIRS_MAX), all or
 * none: each must still be the directory recorded and hold nothing but
 * entries its list names, each of the listed type and, when the entry
 * names one, the very file recorded, unchanged. Each is first renamed to a
 * private name next to it, in one step, so nothing can be added to it or
 * put in its place while they are checked; if any doesn't match, all are
 * renamed back and kept. Neither rename replaces anything (where the
 * platform can't promise that, nothing is renamed): one whose name was
 * taken meanwhile stays under its private name. Something added to one
 * after the check (through a handle opened before) stops the removal there
 * and keeps what is left.
 * Never follows a symlink. Leaves libgit2's last error as it was.
 */
int gitkit_remove_created_dirs(const gitkit_created_dir *dirs, size_t len);

/* Runs the calling thread's restore hook, if any, for `path`. */
void gitkit_created_before_restore(const char *path);

/* Runs the calling thread's delete hook, if any, for `path`. */
void gitkit_created_before_delete(const char *path);

/*
 * Called before each config read on the calling thread: while a GitKit
 * init runs on it, records what the init wrote so far, the first time,
 * and after that checks it against the record (created_dir.c).
 */
void gitkit_created_watch_notify(void);

/*
 * Called as each such config read returns: what changed since the record
 * is no longer provably the init's (created_dir.c).
 */
void gitkit_created_watch_settle(void);

/*
 * git_filebuf_commit(), for the repository.c and config_file.c shims:
 * within a GitKit init, once recorded, what it replaces is checked first
 * and the file it leaves is recorded as the init's (created_dir.c).
 */
struct git_filebuf;
int gitkit_created_watch_commit(struct git_filebuf *file);

#endif /* GITKIT_CREATED_DIR_H */
