/*
 * GitKit shim — clean partial filter lists when a later filter fails `check`.
 *
 * libgit2 1.9.4 frees a partially built git_filter_list with git_array_clear
 * when git_filter_list__load fails, bypassing every earlier entry's cleanup
 * callback. Custom filters therefore leak any payload they returned from
 * `check` whenever a later filter rejects the file.
 *
 * Keep the upstream source pristine. Within filter.c only, augment the array
 * clear performed by git_filter_list__load; git_filter_list_free already runs
 * the same cleanup loop before its own array clear.
 */
#include "filter.h"
#include "array.h"

#undef git_array_clear
#define git_array_clear(array) do { \
	if (strcmp(__func__, "git_filter_list__load") == 0) { \
		size_t gitkit_index; \
		for (gitkit_index = 0; gitkit_index < (array).size; ++gitkit_index) { \
			git_filter_entry *gitkit_entry = &(array).ptr[gitkit_index]; \
			if (gitkit_entry->filter->cleanup) \
				gitkit_entry->filter->cleanup( \
					gitkit_entry->filter, gitkit_entry->payload); \
		} \
	} \
	git__free((array).ptr); \
	git_array_init(array); \
} while (0)

#include "filter.c"

#undef git_array_clear
