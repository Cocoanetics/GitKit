/*
 * GitKit shim — git's lock files (`<path>.lock`, created exclusively) for
 * Swift, through libgit2's internal git_filebuf (src/util/filebuf.h): hold a
 * ref's lock while rewriting its reflog, and replace a file by committing its
 * lock, as git does. Declared for Swift in CGitKit's gitkit_libgit2.h.
 */
#include "common.h"
#include "filebuf.h"

struct gitkit_lockfile {
	git_filebuf file;
};

int gitkit_lockfile_acquire(struct gitkit_lockfile **out, const char *path)
{
	struct gitkit_lockfile *lock;
	int error;

	*out = NULL;
	lock = git__calloc(1, sizeof(*lock));
	GIT_ERROR_CHECK_ALLOC(lock);

	/* GIT_ELOCKED when `<path>.lock` exists. */
	if ((error = git_filebuf_open(&lock->file, path, 0, 0666)) < 0) {
		git_filebuf_cleanup(&lock->file);
		git__free(lock);
		return error;
	}

	*out = lock;
	return 0;
}

int gitkit_lockfile_commit(struct gitkit_lockfile *lock, const void *data, size_t len)
{
	int error;

	if ((error = git_filebuf_write(&lock->file, data, len)) < 0)
		return error;
	return git_filebuf_commit(&lock->file);
}

void gitkit_lockfile_release(struct gitkit_lockfile *lock)
{
	if (lock == NULL)
		return;
	/* Removes `<path>.lock` unless it was committed. */
	git_filebuf_cleanup(&lock->file);
	git__free(lock);
}
