/*
 * GitKit shim — `git update-index --[no-]skip-worktree / --[no-]assume-unchanged`.
 *
 * libgit2's public API has no way to hold the index lock across a
 * read-modify-write: `git_index_write` takes `index.lock` only for the write
 * itself, so a refresh / change / write sequence built from public calls can
 * overwrite a newer index another process committed in between. Real git holds
 * the lock from before it reads the index until it commits it. This does the
 * same with libgit2's internal index writer (src/libgit2/index.h), which is why
 * it lives here, compiled against the pristine submodule's internal headers.
 * Declared for Swift in CGitKit's gitkit_libgit2.h.
 */
#include "common.h"
#include "index.h"
#include "repository.h"

int gitkit_index_update_entry_flags(
	git_repository *repo,
	const char *path,
	uint16_t flags_set,
	uint16_t flags_clear,
	uint16_t extended_set,
	uint16_t extended_clear)
{
	git_index *index = NULL;
	git_indexwriter writer = GIT_INDEXWRITER_INIT;
	const git_index_entry *found;
	git_index_entry *entry;
	int error;

	if ((error = git_repository_index__weakptr(&index, repo)) < 0)
		return error;

	/* Take index.lock first (GIT_ELOCKED when another process holds it)… */
	if ((error = git_indexwriter_init(&writer, index)) < 0)
		goto done;

	/* …then read the index as committed on disk, under the lock. */
	if ((error = git_index_read(index, true)) < 0)
		goto done;

	/*
	 * Exact path only. With core.ignorecase (the macOS default) the by-path
	 * lookup matches case-insensitively, so `foo` could resolve to a tracked
	 * `Foo`; git refuses that ("Unable to mark file").
	 */
	found = git_index_get_bypath(index, path, 0);
	if (found == NULL || strcmp(found->path, path) != 0) {
		git_error_set(GIT_ERROR_INDEX, "Unable to mark file %s", path);
		error = GIT_ENOTFOUND;
		goto done;
	}

	entry = (git_index_entry *)found;
	entry->flags = (uint16_t)((entry->flags | flags_set) & ~flags_clear);
	entry->flags_extended = (uint16_t)((entry->flags_extended | extended_set) & ~extended_clear);

	error = git_indexwriter_commit(&writer);

done:
	git_indexwriter_cleanup(&writer);
	/* On failure, drop any in-memory change so a later write can't persist it. */
	if (error < 0 && index != NULL)
		git_index_read(index, true);
	return error;
}
