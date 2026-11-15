/* Keep signed-commit ref updates and reflogs identical to git_commit_create.
 * Recheck this internal entry point whenever the vendored libgit2 changes. */
#include "refs.h"

int gitkit_reference_update_for_commit(
	git_repository *repo, git_reference *ref, const char *ref_name,
	const git_oid *id, const char *operation)
{
	return git_reference__update_for_commit(repo, ref, ref_name, id, operation);
}
