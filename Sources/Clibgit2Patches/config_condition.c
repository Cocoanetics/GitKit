/*
 * Conditional includes, following Git v2.54 config.c's pattern preparation,
 * URL collection and forbid_remote_url rules. This parser only collects
 * URLs: it never constructs a config or re-enters repository config loading.
 */
#include "gitkit_config_condition.h"
#include "config_parse.h"
#include "futils.h"
#include "fs_path.h"
#include "repository.h"
#include "sysdir.h"
#include "wildmatch.h"
#include "posix.h"

/* Every file consulted by URL collection, including absent targets. These
 * are dependencies of every backend evaluated with this prospective view. */
typedef struct {
	char *path, *from;
	const git_repository *repo;
	git_futils_filestamp stamp;
	int depth, present;
} gitkit_condition_file;

static void condition_files_clear(git_vector *files)
{
	gitkit_condition_file *file;
	size_t i;
	git_vector_foreach(files, i, file) {
		git__free(file->path);
		git__free(file->from);
		git__free(file);
	}
	git_vector_clear(files);
}

#if defined(_MSC_VER)
# define GITKIT_TLS __declspec(thread)
#else
# define GITKIT_TLS __thread
#endif

static GITKIT_TLS gitkit_condition_context *current;
typedef struct gitkit_condition_build {
	git_config *cfg;
	gitkit_condition_context *ctx, *previous;
	struct gitkit_condition_build *next;
} gitkit_condition_build;
static GITKIT_TLS gitkit_condition_build *builds;

gitkit_condition_context *gitkit_condition_current(void) { return current; }
gitkit_condition_context *gitkit_condition_enter(gitkit_condition_context *ctx)
{
	gitkit_condition_context *previous = current;
	current = ctx;
	return previous;
}

gitkit_condition_context *gitkit_condition_new(const git_repository *repo)
{
	gitkit_condition_context *ctx = git__calloc(1, sizeof(*ctx));
	git_str path = GIT_STR_INIT, head = GIT_STR_INIT;
	const char *branch;
	if (!ctx)
		return NULL;
	ctx->refs = 1;
	ctx->repo = repo;
	gitkit_condition_diagnostics(ctx, gitkit_config_scope__diagnostic_owner());
	if (git_vector_init(&ctx->sources, 8, NULL) < 0 || git_vector_init(&ctx->urls, 8, NULL) < 0 ||
	    git_vector_init(&ctx->files, 8, NULL) < 0)
		goto fail;
	/* A repository without a path (git_repository_new) is no repository here. */
	if (repo && git_repository_path(repo)) {
		ctx->gitdir = git__strdup(git_repository_path(repo));
		if (!ctx->gitdir)
			goto fail;
		/* Direct HEAD read: the refdb can recursively load config here. */
		if (git_str_joinpath(&path, ctx->gitdir, "HEAD") < 0)
			goto fail;
		if (git_futils_readbuffer(&head, path.ptr) == 0) {
			git_str_rtrim(&head);
			if (!git__prefixcmp(head.ptr, "ref: refs/heads/")) {
				branch = head.ptr + strlen("ref: refs/heads/");
				if (!(ctx->branch = git__strdup(branch)))
					goto fail;
			}
		} else {
			/* An unreadable or detached HEAD makes onbranch false. */
			git_error_clear();
		}
	}
	git_str_dispose(&path);
	git_str_dispose(&head);
	return ctx;
fail:
	git_str_dispose(&path);
	git_str_dispose(&head);
	gitkit_condition_free(ctx);
	return NULL;
}

void gitkit_condition_retain(gitkit_condition_context *ctx) { if (ctx) ctx->refs++; }

void gitkit_condition_diagnostics(gitkit_condition_context *ctx, struct gitkit_config_scope *scope)
{
	gitkit_config_scope__retain(scope);
	gitkit_config_scope__release(ctx->diagnostic_scope);
	ctx->diagnostic_scope = scope;
}

/* A direct install's new layers may have no repository, while the lower
 * files still belong to their original handles. Give those files the same
 * complete prospective sources without replacing their evaluation context. */
static gitkit_condition_context *copy_repository(gitkit_condition_context *original)
{
	gitkit_condition_context *ctx = gitkit_condition_new(NULL);
	if (!ctx)
		return NULL;
	ctx->repo = original->repo;
	gitkit_condition_diagnostics(ctx, original->diagnostic_scope);
	if ((original->gitdir && !(ctx->gitdir = git__strdup(original->gitdir))) ||
	    (original->branch && !(ctx->branch = git__strdup(original->branch)))) {
		gitkit_condition_free(ctx);
		return NULL;
	}
	return ctx;
}

int gitkit_condition_source_repository(gitkit_condition_context *manifest, gitkit_condition_context *original)
{
	gitkit_condition_source *source = git_vector_last(&manifest->sources);
	source->context = copy_repository(original);
	return source->context ? 0 : -1;
}

gitkit_condition_context *gitkit_condition_for_repository(gitkit_condition_context *manifest, gitkit_condition_context *original)
{
	gitkit_condition_context *ctx;
	gitkit_condition_source *source, *copy;
	size_t i;
	if (!(ctx = copy_repository(original)))
		return NULL;
	gitkit_condition_diagnostics(ctx, manifest->diagnostic_scope);
	git_vector_foreach(&manifest->sources, i, source) {
		if (gitkit_condition_source_add(ctx, source->path, source->text,
		    source->text_len, source->level, source->command, source->worktree) < 0) {
			gitkit_condition_free(ctx);
			return NULL;
		}
		copy = git_vector_last(&ctx->sources);
		if (source->context) {
			copy->context = source->context;
			gitkit_condition_retain(copy->context);
		} else if (!(copy->context = copy_repository(manifest))) {
			gitkit_condition_free(ctx);
			return NULL;
		}
	}
	return ctx;
}

void gitkit_condition_invalidate(gitkit_condition_context *ctx)
{
	char *url;
	size_t i;
	if (!ctx || ctx->building || ctx->collecting || ctx->refreshing)
		return;
	git_vector_foreach(&ctx->urls, i, url) git__free(url);
	git_vector_clear(&ctx->urls);
	ctx->collected = ctx->worktree = 0;
	ctx->generation++;
}

int gitkit_condition_check(gitkit_condition_context *ctx)
{
	gitkit_condition_file *file;
	git_futils_filestamp stamp;
	size_t i;
	int error = 0, changed;
	if (!ctx || !ctx->hasconfig || !ctx->collected || ctx->building ||
	    ctx->collecting || ctx->refreshing || ctx->checking)
		return 0;
	ctx->checking = 1;
	git_vector_foreach(&ctx->files, i, file) {
		if (file->depth && (error = gitkit_config_authorize(file->repo,
		    file->path, file->from, file->depth)) < 0)
			break;
		/* Checking must not accept a new stamp until a successful collection. */
		stamp = file->stamp;
		changed = git_futils_filestamp_check(&stamp, file->path);
		if (changed == GIT_ENOTFOUND) {
			if (errno != ENOENT && errno != ENOTDIR) {
				git_error_set(GIT_ERROR_OS, "failed to stat config file '%s'", file->path);
				error = -1;
				break;
			}
			changed = file->present;
		} else if (!file->present) changed = 1;
		if (changed) {
			gitkit_condition_invalidate(ctx);
			break;
		}
	}
	ctx->checking = 0;
	return error;
}

void gitkit_condition_free(gitkit_condition_context *ctx)
{
	gitkit_condition_source *source;
	char *url;
	size_t i;
	if (!ctx || --ctx->refs)
		return;
	git_vector_foreach(&ctx->sources, i, source) {
		git__free(source->path);
		git__free(source->text);
		gitkit_condition_free(source->context);
		git__free(source);
	}
	git_vector_foreach(&ctx->urls, i, url) git__free(url);
	git_vector_dispose(&ctx->sources);
	git_vector_dispose(&ctx->urls);
	condition_files_clear(&ctx->files);
	git_vector_dispose(&ctx->files);
	git__free(ctx->gitdir);
	git__free(ctx->branch);
	gitkit_config_scope__release(ctx->diagnostic_scope);
	git__free(ctx);
}

int gitkit_condition_source_add(gitkit_condition_context *ctx, const char *path,
	const char *text, size_t len, git_config_level_t level, int command, int worktree)
{
	gitkit_condition_source *source = git__calloc(1, sizeof(*source));
	if (!source)
		return -1;
	source->level = level;
	source->command = command;
	source->worktree = worktree;
	if (path && !(source->path = git__strdup(path)))
		goto fail;
	if (text && !(source->text = git__substrdup(text, len)))
		goto fail;
	source->text_len = len;
	if (git_vector_insert(&ctx->sources, source) < 0)
		goto fail;
	return 0;
fail:
	git__free(source->path);
	git__free(source->text);
	git__free(source);
	return -1;
}

int gitkit_condition_build_begin(git_config *cfg, gitkit_condition_context *ctx)
{
	gitkit_condition_build *build = git__calloc(1, sizeof(*build));
	if (!build)
		return -1;
	build->cfg = cfg;
	build->ctx = ctx;
	gitkit_condition_retain(ctx);
	ctx->building++;
	build->previous = gitkit_condition_enter(ctx);
	build->next = builds;
	builds = build;
	return 0;
}

void gitkit_condition_build_end(git_config *cfg)
{
	gitkit_condition_build *build = builds;
	/* Config destruction on an error and normal completion share cleanup. */
	if (!build || build->cfg != cfg)
		return;
	builds = build->next;
	gitkit_condition_enter(build->previous);
	build->ctx->building--;
	gitkit_condition_free(build->ctx);
	git__free(build);
}

int gitkit_condition_path(git_str *out, const char *path, const char *from)
{
	git_str directory = GIT_STR_INIT;
	int error;
	if (!path) {
		git_error_set(GIT_ERROR_CONFIG, "missing value for 'include.path'");
		return -1;
	}
	if (path[0] == '~' && git_fs_path_is_dirsep(path[1]))
		return git_sysdir_expand_homedir_file(out, path + 1);
	if (git_fs_path_root(path) >= 0)
		return git_str_sets(out, path);
	if (!from) {
		git_error_set(GIT_ERROR_CONFIG, "relative config includes must come from files");
		return -1;
	}
	error = git_fs_path_dirname_r(&directory, from);
	if (error >= 0)
		error = git_str_joinpath(out, directory.ptr, path);
	git_str_dispose(&directory);
	return error;
}

int gitkit_condition_unexpanded(const char *path)
{
	git_error_set(GIT_ERROR_CONFIG, "could not expand include path '%s'", path ? path : "");
	return -1;
}

static int match_gitdir(int *matches, gitkit_condition_context *ctx, const char *condition,
	const char *file, const char *value, int insensitive)
{
	git_str pattern = GIT_STR_INIT, path = GIT_STR_INIT, directory = GIT_STR_INIT;
	size_t prefix = 0;
	int error = 0, attempt;
	unsigned int flags = WM_PATHNAME | (insensitive ? WM_CASEFOLD : 0);
	if (!ctx->gitdir)
		return 0;
	if (value[0] == '.' && git_fs_path_is_dirsep(value[1])) {
		if (!file) {
			gitkit_config_scope__diagnostic(ctx->diagnostic_scope, condition, ctx->gitdir);
			*matches = 1; /* Git's negative diagnostic return is truthy. */
			return 0;
		}
		if ((error = git_fs_path_prettify(&path, file, NULL)) < 0 ||
		    (error = git_fs_path_dirname_r(&directory, path.ptr)) < 0 ||
		    (error = git_str_joinpath(&pattern, directory.ptr, value + 2)) < 0)
			goto done;
		prefix = directory.size + (directory.size && directory.ptr[directory.size - 1] != '/');
	} else if (value[0] == '~' && git_fs_path_is_dirsep(value[1])) {
		error = git_sysdir_expand_homedir_file(&pattern, value + 1);
	} else if (git_fs_path_root(value) < 0) {
		error = git_str_joinpath(&pattern, "**", value);
	} else {
		error = git_str_sets(&pattern, value);
	}
	if (error < 0)
		goto done;
	if (pattern.size && git_fs_path_is_dirsep(pattern.ptr[pattern.size - 1]) &&
	    (error = git_str_puts(&pattern, "**")) < 0)
		goto done;
	for (attempt = 0; attempt < 2; attempt++) {
		error = attempt ? git_str_sets(&path, ctx->gitdir) :
			git_fs_path_prettify(&path, ctx->gitdir, NULL);
		if (error < 0)
			goto done;
		while (path.size && git_fs_path_is_dirsep(path.ptr[path.size - 1])) git_str_truncate(&path, path.size - 1);
		if (path.size < prefix || (prefix && (insensitive ?
		    git__strncasecmp(pattern.ptr, path.ptr, prefix) : strncmp(pattern.ptr, path.ptr, prefix))))
			continue;
		*matches = wildmatch(pattern.ptr + prefix, path.ptr + prefix, flags) == WM_MATCH;
		if (*matches)
			break;
	}
done:
	git_str_dispose(&pattern);
	git_str_dispose(&path);
	git_str_dispose(&directory);
	return error;
}

typedef struct {
	gitkit_condition_context *ctx;
	gitkit_condition_context *evaluation;
	const char *path;
	int depth, forbid, active;
	git_config_level_t level;
} url_scan;

static int scan_file(url_scan *parent, const char *target, int conditional);
static int scan_variable(git_config_parser *parser, const char *section, const char *variable,
	const char *value, const char *line, size_t line_len, void *payload)
{
	url_scan *scan = payload;
	const char *condition;
	char *url;
	int matches = 0, error = 0, enabled, unexpanded;
	GIT_UNUSED(parser); GIT_UNUSED(line); GIT_UNUSED(line_len);
	if (!section)
		return 0;
	if (!git__strncasecmp(section, "remote.", 7) && !git__strcasecmp(variable, "url")) {
		if (scan->forbid) {
			git_error_set(GIT_ERROR_CONFIG,
				"remote URLs cannot be configured in file directly or indirectly included by includeIf.hasconfig:remote.*.url");
			return -1;
		}
		if (value) {
			url = git__strdup(value);
			GIT_ERROR_CHECK_ALLOC(url);
			if (git_vector_insert(&scan->ctx->urls, url) < 0) { git__free(url); return -1; }
		}
	}
	if (scan->level == GIT_CONFIG_LEVEL_LOCAL && !git__strcasecmp(section, "extensions") &&
	    !git__strcasecmp(variable, "worktreeconfig") && git_config_parse_bool(&enabled, value) == 0)
		scan->ctx->worktree = enabled;
	/* Only a command element's own text (no path) carries the marker. */
	unexpanded = !scan->path && !git__strcasecmp(variable, GITKIT_UNEXPANDED_PATH);
	if (!scan->active || (git__strcasecmp(variable, "path") && !unexpanded))
		return 0;
	if (!git__strcasecmp(section, "include"))
		return unexpanded ? gitkit_condition_unexpanded(value) : scan_file(scan, value, 0);
	if (git__strncasecmp(section, "includeif.", 10))
		return 0;
	condition = section + 10;
	/* In the pre-scan ALL conditional targets run with URLs forbidden. */
	if (!git__prefixcmp(condition, "hasconfig:remote.*.url:"))
		matches = 1;
	else
		error = gitkit_condition_match(&matches, scan->evaluation, condition, scan->path);
	if (!error && matches)
		error = unexpanded ? gitkit_condition_unexpanded(value) : scan_file(scan, value, 1);
	return error;
}

static int scan_text(url_scan *scan, const char *text, size_t len)
{
	git_config_parser parser = GIT_CONFIG_PARSER_INIT;
	int error;
	if ((error = git_config_parser_init(&parser, scan->path, text, len)) < 0)
		return error;
	error = git_config_parse(&parser, NULL, scan_variable, NULL, NULL, scan);
	git_config_parser_dispose(&parser);
	return error;
}

static int condition_read(url_scan *scan, const char *from, git_str *content)
{
	gitkit_condition_file *file = git__calloc(1, sizeof(*file));
	struct stat st;
	int error = -1;
	if (!file)
		return -1;
	file->depth = scan->depth;
	file->repo = scan->evaluation->repo;
	file->path = git__strdup(scan->path);
	file->from = from ? git__strdup(from) : NULL;
	if (!file->path || (from && !file->from))
		goto fail;
	if (p_stat(scan->path, &st) == 0) {
		file->present = 1;
		git_futils_filestamp_set_from_stat(&file->stamp, &st);
	} else if (errno != ENOENT && errno != ENOTDIR) {
		git_error_set(GIT_ERROR_OS, "failed to stat config file '%s'", scan->path);
		goto fail;
	}
	if (git_vector_insert(&scan->ctx->files, file) < 0)
		goto fail;
	return file->present ? git_futils_readbuffer(content, scan->path) : GIT_ENOTFOUND;
fail:
	git__free(file->path);
	git__free(file->from);
	git__free(file);
	return error;
}

static int scan_file(url_scan *parent, const char *target, int conditional)
{
	git_str path = GIT_STR_INIT, content = GIT_STR_INIT;
	url_scan scan = *parent;
	int error;
	if ((error = gitkit_condition_path(&path, target, parent->path)) < 0)
		goto done;
	scan.depth++;
	scan.path = path.ptr;
	scan.active = 1;
	scan.forbid |= conditional;
	if ((error = gitkit_config_authorize(scan.evaluation->repo, path.ptr, parent->path, scan.depth)) < 0)
		goto done;
	error = condition_read(&scan, parent->path, &content);
	if (error == GIT_ENOTFOUND) { git_error_clear(); error = 0; }
	else if (!error) {
		if (scan.depth > 10) {
			git_error_set(GIT_ERROR_CONFIG, "maximum config include depth reached");
			error = -1;
		} else error = scan_text(&scan, content.ptr, content.size);
	}
done:
	git_str_dispose(&path);
	git_str_dispose(&content);
	return error;
}

static int collect_urls(gitkit_condition_context *ctx)
{
	gitkit_condition_source *source;
	git_str text = GIT_STR_INIT;
	size_t i;
	int error = 0;
	char *url;
	condition_files_clear(&ctx->files);
	git_vector_foreach(&ctx->urls, i, url) git__free(url);
	git_vector_clear(&ctx->urls);
	ctx->collecting = 1;
	git_vector_foreach(&ctx->sources, i, source) {
		url_scan scan = { ctx, source->context ? source->context : ctx, source->path,
			0, 0, source->path != NULL || source->command, source->level };
		if (source->worktree && !ctx->worktree)
			continue;
		if (source->path) {
			error = condition_read(&scan, NULL, &text);
			if (error == GIT_ENOTFOUND) { git_error_clear(); error = 0; continue; }
			if (!error) error = scan_text(&scan, text.ptr, text.size);
		} else {
			error = scan_text(&scan, source->text, source->text_len);
		}
		if (error < 0)
			break;
	}
	ctx->collecting = 0;
	ctx->collected = error == 0;
	git_str_dispose(&text);
	return error;
}

int gitkit_condition_match(int *matches, gitkit_condition_context *ctx,
	const char *condition, const char *file)
{
	git_str pattern = GIT_STR_INIT;
	char *url;
	size_t i;
	int error = 0;
	*matches = 0;
	if (!git__prefixcmp(condition, "gitdir:"))
		return match_gitdir(matches, ctx, condition, file, condition + 7, 0);
	if (!git__prefixcmp(condition, "gitdir/i:"))
		return match_gitdir(matches, ctx, condition, file, condition + 9, 1);
	if (!git__prefixcmp(condition, "onbranch:")) {
		if (!ctx->branch)
			return 0;
		if ((error = git_str_sets(&pattern, condition + 9)) < 0)
			goto done;
		if (pattern.size && git_fs_path_is_dirsep(pattern.ptr[pattern.size - 1]) &&
		    (error = git_str_puts(&pattern, "**")) < 0)
			goto done;
		*matches = wildmatch(pattern.ptr, ctx->branch, WM_PATHNAME) == WM_MATCH;
	} else if (!git__prefixcmp(condition, "hasconfig:remote.*.url:")) {
		ctx->hasconfig = 1;
		if (!ctx->collected && (error = collect_urls(ctx)) < 0)
			goto done;
		git_vector_foreach(&ctx->urls, i, url) {
			if (wildmatch(condition + strlen("hasconfig:remote.*.url:"), url, WM_PATHNAME) == WM_MATCH) {
				*matches = 1;
				break;
			}
		}
	}
done:
	git_str_dispose(&pattern);
	return error;
}
