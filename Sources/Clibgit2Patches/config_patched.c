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
#include "gitkit_config_condition.h"
#define git_config_free gitkit_config_free_unwrapped
#define git_config_open_default gitkit_config_open_default_unwrapped
#include "config.c"
#undef git_config_free
#undef git_config_open_default

#include "../CGitKit/include/gitkit_libgit2.h"

void git_config_free(git_config *cfg)
{
	gitkit_condition_build_end(cfg);
	gitkit_config_free_unwrapped(cfg);
}

int git_config_open_default(git_config **out)
{
	gitkit_condition_context *ctx = gitkit_condition_new(NULL), *previous;
	git_str path = GIT_STR_INIT;
	int error = -1;
	if (!ctx)
		return -1;
	/* Discover the complete no-repository view before the first file parses. */
	if (!git_config__find_programdata(&path) &&
	    gitkit_condition_source_add(ctx, path.ptr, NULL, 0, GIT_CONFIG_LEVEL_PROGRAMDATA, 0, 0) < 0) goto done;
	if (!git_config__find_system(&path) &&
	    gitkit_condition_source_add(ctx, path.ptr, NULL, 0, GIT_CONFIG_LEVEL_SYSTEM, 0, 0) < 0) goto done;
	if (!git_config__find_xdg(&path) &&
	    gitkit_condition_source_add(ctx, path.ptr, NULL, 0, GIT_CONFIG_LEVEL_XDG, 0, 0) < 0) goto done;
	if ((!git_config__find_global(&path) || !git_config__global_location(&path)) &&
	    gitkit_condition_source_add(ctx, path.ptr, NULL, 0, GIT_CONFIG_LEVEL_GLOBAL, 0, 0) < 0) goto done;
	git_error_clear();
	previous = gitkit_condition_enter(ctx);
	ctx->building++;
	error = gitkit_config_open_default_unwrapped(out);
	ctx->building--;
	gitkit_condition_enter(previous);
done:
	git_str_dispose(&path);
	gitkit_condition_free(ctx);
	return error;
}

/* In-memory lower levels do not follow includes. Only their URLs contribute
 * to a prospective scan; serialising those avoids querying a partial cfg. */
static int manifest_memory(gitkit_condition_context *ctx, backend_entry *entry)
{
	git_config_iterator *iterator;
	git_config_backend_entry *value;
	git_config_backend *backend = entry->instance->backend;
	git_str text = GIT_STR_INIT;
	const char *c;
	int error;
	if ((error = backend->iterator(&iterator, backend)) < 0)
		return error;
	while (!(error = iterator->next(&value, iterator))) {
		const git_config_entry *e = &value->entry;
		if (git__prefixcmp(e->name, "remote.") || git__suffixcmp(e->name, ".url") || !e->value)
			continue;
		git_str_puts(&text, "[remote \"prospective\"]\nurl = \"");
		for (c = e->value; *c; c++) {
			switch (*c) {
			case '\\': case '"': git_str_putc(&text, '\\'); git_str_putc(&text, *c); break;
			case '\n': git_str_puts(&text, "\\n"); break;
			case '\t': git_str_puts(&text, "\\t"); break;
			case '\b': git_str_puts(&text, "\\b"); break;
			default: git_str_putc(&text, *c);
			}
		}
		git_str_puts(&text, "\"\n");
	}
	iterator->free(iterator);
	if (error == GIT_ITEROVER)
		error = git_str_oom(&text) ? -1 : gitkit_condition_source_add(ctx, NULL,
			git_str_cstr(&text), text.size, entry->level, 0, 0);
	git_str_dispose(&text);
	return error;
}

int gitkit_config_manifest_existing(gitkit_condition_context *ctx, git_config *cfg)
{
	backend_entry *entry;
	git_config_backend *inner;
	const char *path;
	size_t i;
	int filtered, error;
	/* Readers are sorted highest first; a scan reads lowest first. */
	for (i = git_vector_length(&cfg->readers); i > 0; i--) {
		entry = git_vector_get(&cfg->readers, i - 1);
		if (entry->level >= GIT_CONFIG_LEVEL_APP)
			continue;
		inner = gitkit_config_backend_unwrap(entry->instance->backend, &filtered);
		path = gitkit_config_backend_path(inner);
		error = path ? gitkit_condition_source_add(ctx, path, NULL, 0, entry->level, 0, 0) : manifest_memory(ctx, entry);
		if (error < 0)
			return error;
	}
	return 0;
}

/*
 * `never_write` gives every moved level write order -1 before it is sorted
 * into the writers, so none of them is a write target and the order of the
 * levels below `from` stays as it was.
 */
static int replace_levels(
	git_config *live, git_config *staged, git_config_level_t from, int never_write)
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
		if (never_write)
			entry->write_order = -1;
		if (git_vector_insert_sorted(&live->readers, entry, &duplicate_level) < 0 ||
		    git_vector_insert_sorted(&live->writers, entry, NULL) < 0)
			return -1;	/* unreachable: room was made and the levels are new */
	}

	/* The entries and their instances' references now belong to `live`. */
	git_vector_clear(&staged->readers);
	git_vector_clear(&staged->writers);
	return 0;
}

int gitkit_config_replace_levels_from(
	git_config *live, git_config *staged, git_config_level_t from)
{
	return replace_levels(live, staged, from, 0);
}

int gitkit_config_replace_levels_readonly_from(
	git_config *live, git_config *staged, git_config_level_t from)
{
	return replace_levels(live, staged, from, 1);
}

int gitkit_config_rebuild(git_config *live, git_config *commands, gitkit_condition_context *ctx)
{
	git_config *rebuilt = NULL;
	backend_entry *entry, *copy;
	git_config_backend *backend, *inner;
	git_vector readers, writers;
	const char *path;
	size_t i;
	int error = -1, filtered;
	if (git_config_new(&rebuilt) < 0)
		return -1;
	/* Stage lower files too: their hasconfig may depend on a new -c URL. */
	git_vector_foreach(&live->readers, i, entry) {
		if (entry->level >= GIT_CONFIG_LEVEL_APP)
			continue;
		inner = gitkit_config_backend_unwrap(entry->instance->backend, &filtered);
		path = gitkit_config_backend_path(inner);
		if (path) {
			/* No hasconfig: keep cached values without extra file reads, but
			 * attach the new manifest for any later on-disk refresh. */
			error = ctx->hasconfig || gitkit_config_backend_hasconfig(inner) ?
				git_config_backend_from_file(&backend, path) : gitkit_config_backend_clone(&backend, inner);
			if (error < 0)
				goto done;
			if (filtered && (error = gitkit_config_backend_filter(&backend, backend)) < 0)
				goto done;
			error = git_config_add_backend(rebuilt, backend, entry->level, ctx->repo, 0);
			if (error < 0) { backend->free(backend); goto done; }
			/* Insertion is sorted; locate this level rather than assume last. */
			{
				size_t j;
				git_vector_foreach(&rebuilt->readers, j, copy)
					if (copy->level == entry->level) break;
			}
			copy->write_order = entry->write_order;
		} else {
			copy = git__malloc(sizeof(*copy));
			if (!copy) { error = -1; goto done; }
			*copy = *entry;
			GIT_REFCOUNT_INC(copy->instance);
			if (git_vector_insert_sorted(&rebuilt->readers, copy, NULL) < 0) {
				GIT_REFCOUNT_DEC(copy->instance, backend_instance_free);
				git__free(copy);
				error = -1;
				goto done;
			}
			if (git_vector_insert_sorted(&rebuilt->writers, copy, NULL) < 0) { error = -1; goto done; }
		}
	}
	git_vector_set_sorted(&rebuilt->writers, 0);
	git_vector_sort(&rebuilt->writers);
	if ((error = replace_levels(rebuilt, commands, GIT_CONFIG_LEVEL_APP, 1)) < 0)
		goto done;
	/* No allocation or parsing beyond this point. Snapshots retain old instances. */
	readers = live->readers;
	writers = live->writers;
	live->readers = rebuilt->readers;
	live->writers = rebuilt->writers;
	rebuilt->readers = readers;
	rebuilt->writers = writers;
	git_vector_foreach(&live->readers, i, entry) entry->instance->backend->cfg = live;
	error = 0;
done:
	git_config_free(rebuilt);
	return error;
}
