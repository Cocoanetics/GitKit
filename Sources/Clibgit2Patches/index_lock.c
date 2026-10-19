/*
 * GitKit shim — hold `index.lock` across an operation that only reads the
 * index, as `git commit` does from before it reads the index until HEAD has
 * moved. libgit2 takes the lock only inside `git_index_write`, so reading the
 * index and writing its tree never notice another process holding it. This
 * takes it with libgit2's internal index writer (src/libgit2/index.h), which
 * is why it lives here. Declared for Swift in CGitKit's gitkit_libgit2.h.
 */
#include "common.h"
#include "index.h"
#include "repository.h"

struct gitkit_index_lock {
	git_indexwriter writer;
};

int gitkit_index_lock_acquire(struct gitkit_index_lock **out, git_repository *repo)
{
	struct gitkit_index_lock *lock;
	git_index *index = NULL;
	int error;

	*out = NULL;
	if ((error = git_repository_index__weakptr(&index, repo)) < 0)
		return error;

	lock = git__calloc(1, sizeof(*lock));
	GIT_ERROR_CHECK_ALLOC(lock);

	/* GIT_ELOCKED when another process holds index.lock. */
	if ((error = git_indexwriter_init(&lock->writer, index)) < 0) {
		git_indexwriter_cleanup(&lock->writer);
		git__free(lock);
		return error;
	}

	*out = lock;
	return 0;
}

void gitkit_index_lock_release(struct gitkit_index_lock *lock)
{
	if (lock == NULL)
		return;
	/* Removes index.lock without writing the index. */
	git_indexwriter_cleanup(&lock->writer);
	git__free(lock);
}
