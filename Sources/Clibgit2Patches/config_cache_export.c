/*
 * GitKit shim — make a repository derive again what it derived from its
 * config, after a backend was added to its live config. libgit2 forgets its
 * cached `core.*` values (git_repository__configmap_lookup) when a value is
 * set or the config replaced, but not when a backend is added; a loaded
 * index keeps the `core.ignorecase` / `core.filemode` / `core.symlinks` it
 * read when it was loaded, and the diff driver registry keeps each
 * `diff.<driver>.*` it looked up. libgit2 keeps all three internal, so this
 * is exported here. Declared for Swift in CGitKit's gitkit_libgit2.h.
 */
#include "repository.h"
#include "index.h"
#include "diff_driver.h"

int gitkit_repository_config_changed(git_repository *repo)
{
	git_index *index;
	git_diff_driver_registry *drivers;

	GIT_ASSERT_ARG(repo);

	git_repository__configmap_lookup_cache_clear(repo);

	/* Rebuilt on the next driver lookup, from the current config. */
	if ((drivers = git_atomic_swap(repo->diff_drivers, NULL)) != NULL)
		git_diff_driver_registry_free(drivers);

	/* An index not loaded yet reads its capabilities when it is. */
	if ((index = git_atomic_load(repo->_index)) != NULL)
		return git_index_set_caps(index, GIT_INDEX_CAPABILITY_FROM_OWNER);

	return 0;
}
