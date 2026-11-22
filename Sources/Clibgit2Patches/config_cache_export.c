/*
 * GitKit shim — forget the `core.*` values libgit2 caches per repository
 * (git_repository__configmap_lookup), as libgit2 itself does when a config
 * value is set or the repository's config is replaced. Adding a backend to
 * the live config does not, so a value read before the add would ignore the
 * new level. libgit2 keeps the function internal, so it is exported here.
 * Declared for Swift in CGitKit's gitkit_libgit2.h.
 */
#include "repository.h"

void gitkit_repository_configmap_cache_clear(git_repository *repo)
{
	if (repo)
		git_repository__configmap_lookup_cache_clear(repo);
}
