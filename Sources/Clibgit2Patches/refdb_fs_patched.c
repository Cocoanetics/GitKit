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
 * ref. It also routes per-worktree loose refs through gitpath, as lookup and
 * locking do, and locks packed-refs before reloading and rewriting its cache.
 * All helpers remain the file-local implementations from refdb_fs.c.
 */
#define git_refdb_backend_fs gitkit_refdb_backend_fs_upstream
#define refdb_fs_backend__delete gitkit_refdb_fs_backend_delete_upstream
#include "refdb_fs.c"
#undef refdb_fs_backend__delete
#undef git_refdb_backend_fs

static int gitkit_packed_delete(
	refdb_fs_backend *backend,
	const char *ref_name,
	bool *deleted)
{
	git_sortedcache *refcache = backend->refcache;
	git_filebuf pack_file = GIT_FILEBUF_INIT;
	size_t pack_pos, i;
	int error, open_flags = 0;
	bool cache_locked = false;

	*deleted = false;
	if (backend->fsync)
		open_flags = GIT_FILEBUF_FSYNC;

	/* Serialize the load, edit and rewrite across repository handles. */
	if ((error = git_filebuf_open(
			&pack_file, git_sortedcache_path(refcache), open_flags,
			GIT_PACKEDREFS_FILE_MODE)) < 0)
		goto cleanup;

	/* Force this handle's cache to reload after acquiring the file lock. */
	if ((error = git_sortedcache_wlock(refcache)) < 0)
		goto cleanup;
	git_futils_filestamp_set(&refcache->stamp, NULL);
	git_sortedcache_wunlock(refcache);

	if ((error = packed_reload(backend)) < 0)
		goto cleanup;

	if ((error = git_mutex_lock(&backend->prlock)) < 0)
		goto cleanup;
	packed_map_free(backend);
	git_mutex_unlock(&backend->prlock);

	if ((error = git_sortedcache_wlock(refcache)) < 0)
		goto cleanup;
	cache_locked = true;

	error = git_sortedcache_lookup_index(&pack_pos, refcache, ref_name);
	if (error == GIT_ENOTFOUND) {
		error = 0;
		goto cleanup;
	}
	if (error < 0 || (error = git_sortedcache_remove(refcache, pack_pos)) < 0)
		goto cleanup;

	if ((error = git_filebuf_printf(&pack_file, "%s\n", GIT_PACKEDREFS_HEADER)) < 0)
		goto cleanup;

	for (i = 0; i < git_sortedcache_entrycount(refcache); ++i) {
		struct packref *ref = git_sortedcache_entry(refcache, i);

		if (!ref) {
			error = -1;
			goto cleanup;
		}
		if ((error = packed_find_peel(backend, ref)) < 0 ||
		    (error = packed_write_ref(ref, &pack_file)) < 0)
			goto cleanup;
	}

	if ((error = git_filebuf_commit(&pack_file)) < 0)
		goto cleanup;

	/* The filesystem lock is released by commit. Force the next user to
	 * reload instead of racing another writer while refreshing this stamp. */
	git_futils_filestamp_set(&refcache->stamp, NULL);
	*deleted = true;

cleanup:
	if (cache_locked) {
		if (error < 0) {
			GIT_UNUSED(git_sortedcache_clear(refcache, false));
			git_futils_filestamp_set(&refcache->stamp, NULL);
		}
		git_sortedcache_wunlock(refcache);
	}
	git_filebuf_cleanup(&pack_file);
	return error;
}

static int gitkit_loose_delete(refdb_fs_backend *backend, const char *ref_name)
{
	git_str path = GIT_STR_INIT;
	const char *base = is_per_worktree_ref(ref_name)
		? backend->gitpath : backend->commonpath;
	int error;

	if ((error = loose_path(&path, base, ref_name)) < 0)
		return error;

	error = p_unlink(path.ptr);
	if (error < 0 && errno == ENOENT)
		error = GIT_ENOTFOUND;
	else if (error != 0)
		error = -1;

	git_str_dispose(&path);
	return error;
}

static int gitkit_refdb_fs_backend_delete(
	git_refdb_backend *_backend,
	const char *ref_name,
	const git_oid *old_id, const char *old_target)
{
	refdb_fs_backend *backend = GIT_CONTAINER_OF(_backend, refdb_fs_backend, parent);
	git_filebuf file = GIT_FILEBUF_INIT;
	int error = 0, cmp = 0;
	bool packed_deleted = false;

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

	if ((error = gitkit_packed_delete(backend, ref_name, &packed_deleted)) < 0)
		goto cleanup;

	if ((error = gitkit_loose_delete(backend, ref_name)) < 0 &&
	    error != GIT_ENOTFOUND)
		goto cleanup;

	if (error == GIT_ENOTFOUND && !packed_deleted) {
		error = ref_error_notfound(ref_name);
		goto cleanup;
	}

	if ((error = refdb_reflog_fs__delete(_backend, ref_name)) < 0)
		goto cleanup;

cleanup:
	git_filebuf_cleanup(&file);
	if (error == 0)
		error = refdb_fs_backend__prune_refs(backend, ref_name, "");

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
