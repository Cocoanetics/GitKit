/*
 * GitKit shim — preserve a reflog when compare-and-delete fails.
 *
 * libgit2 1.9.4's filesystem ref backend deletes the reflog before its
 * delete tail compares the current ref with old_id / old_target. A ref that
 * moved after git_reference_lookup() is therefore retained with
 * GIT_EMODIFIED while its newer reflog is silently removed.
 *
 * Keep the upstream source pristine: compile it here with its public factory
 * and delete callback renamed, then expose the original factory name with the
 * backend's delete callback replaced. The replacement takes the same loose
 * ref lock, compares under that lock, and only then removes the reflog and
 * ref. All helpers remain the file-local implementations from refdb_fs.c.
 */
#define git_refdb_backend_fs gitkit_refdb_backend_fs_upstream
#define refdb_fs_backend__delete gitkit_refdb_fs_backend_delete_upstream
#include "refdb_fs.c"
#undef refdb_fs_backend__delete
#undef git_refdb_backend_fs

static int gitkit_refdb_fs_backend_delete(
	git_refdb_backend *_backend,
	const char *ref_name,
	const git_oid *old_id, const char *old_target)
{
	refdb_fs_backend *backend = GIT_CONTAINER_OF(_backend, refdb_fs_backend, parent);
	git_filebuf file = GIT_FILEBUF_INIT;
	int error = 0, cmp = 0;

	GIT_ASSERT_ARG(backend);
	GIT_ASSERT_ARG(ref_name);

	if ((error = loose_lock(&file, backend, ref_name)) < 0)
		return error;

	if ((error = cmp_old_ref(&cmp, _backend, ref_name, old_id, old_target)) < 0)
		goto cleanup;

	if (cmp) {
		git_error_set(GIT_ERROR_REFERENCE, "old reference value does not match");
		error = GIT_EMODIFIED;
		goto cleanup;
	}

	if ((error = refdb_reflog_fs__delete(_backend, ref_name)) < 0)
		goto cleanup;

	/* The loose lock prevents normal ref writers after the comparison. */
	return refdb_fs_backend__delete_tail(_backend, &file, ref_name, NULL, NULL);

cleanup:
	git_filebuf_cleanup(&file);
	return error;
}

int git_refdb_backend_fs(
	git_refdb_backend **backend_out,
	git_repository *repository)
{
	int error = gitkit_refdb_backend_fs_upstream(backend_out, repository);

	if (!error)
		(*backend_out)->del = &gitkit_refdb_fs_backend_delete;

	return error;
}
