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
 */
/*
 * config_list.h declares git_config_list_get_unique(), so that declaration
 * is what gives the renamed function its prototype here; it's defined below
 * the include.
 */
#define git_config_list_get_unique gitkit_config_list_get_unique_own
#include "config_file.c"
#undef git_config_list_get_unique

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
