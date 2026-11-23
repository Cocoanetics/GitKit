/*
 * GitKit shim — replace a config's command-line levels in one step.
 *
 * git reads its command-line config (`-c`, `GIT_CONFIG_COUNT`) as ordered
 * layers: entries, then a file an `-c include.path=<file>` names, then the
 * entries after it. GitKit installs them as consecutive levels from
 * GIT_CONFIG_LEVEL_APP up, so a later layer wins a single read. Replacing
 * such a set on a repository's live config means removing every level from
 * APP up and adding the new ones, and a failure half-way must leave the old
 * set in force. libgit2 has no public way to remove a backend, and its
 * reader/writer entries (backend_entry) are private to config.c, so this
 * translation unit compiles config.c unchanged and adds one function that
 * reaches them.
 *
 * The new levels are opened and parsed first in a staging git_config — their
 * files read and their includes put to the include policy — so the swap
 * itself only moves entries and cannot fail once its vectors have room.
 */
#include "config.c"

#include "../CGitKit/include/gitkit_libgit2.h"

int gitkit_config_replace_levels_from(
	git_config *live, git_config *staged, git_config_level_t from)
{
	backend_entry *entry;
	size_t i, needed;

	GIT_ASSERT_ARG(live);
	GIT_ASSERT_ARG(staged);

	git_vector_foreach(&staged->readers, i, entry) {
		if (entry->level < from) {
			git_error_set(GIT_ERROR_INVALID,
				"a replacing config level %d is below level %d", (int)entry->level, (int)from);
			return -1;
		}
	}

	/* Room for every entry first: the moves below never allocate. */
	needed = git_vector_length(&live->readers) + git_vector_length(&staged->readers);
	if (git_vector_size_hint(&live->readers, needed) < 0 ||
	    git_vector_size_hint(&live->writers, needed) < 0)
		return -1;

	/* Readers and writers share each entry; it is freed once, as a reader. */
	for (i = git_vector_length(&live->writers); i > 0; i--) {
		entry = git_vector_get(&live->writers, i - 1);
		if (entry->level >= from)
			git_vector_remove(&live->writers, i - 1);
	}
	for (i = git_vector_length(&live->readers); i > 0; i--) {
		entry = git_vector_get(&live->readers, i - 1);
		if (entry->level < from)
			continue;
		git_vector_remove(&live->readers, i - 1);
		GIT_REFCOUNT_DEC(entry->instance, backend_instance_free);
		git__free(entry);
	}

	git_vector_foreach(&staged->readers, i, entry) {
		entry->instance->backend->cfg = live;
		if (git_vector_insert_sorted(&live->readers, entry, &duplicate_level) < 0 ||
		    git_vector_insert_sorted(&live->writers, entry, NULL) < 0)
			return -1;	/* unreachable: room was made and the levels are new */
	}

	/* The entries and their instances' references now belong to `live`. */
	git_vector_clear(&staged->readers);
	git_vector_clear(&staged->writers);
	return 0;
}
