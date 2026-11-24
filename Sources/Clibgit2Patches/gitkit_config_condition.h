#ifndef GITKIT_CONFIG_CONDITION_H
#define GITKIT_CONFIG_CONDITION_H

#include "common.h"
#include "git2/sys/config.h"
#include "str.h"
#include "vector.h"

/* A copied, prospective source list. Never borrows a partially built cfg. */
typedef struct {
	char *path, *text;
	size_t text_len;
	git_config_level_t level;
	int command, worktree;
	struct gitkit_condition_context *context; /* copied lower-source repository context */
} gitkit_condition_source;

typedef struct gitkit_condition_context {
	size_t refs;
	const git_repository *repo;
	char *gitdir, *branch;
	git_vector sources, urls, files;
	size_t generation;
	int collecting, collected, building, worktree, hasconfig, refreshing, checking;
} gitkit_condition_context;

gitkit_condition_context *gitkit_condition_new(const git_repository *repo);
gitkit_condition_context *gitkit_condition_for_repository(gitkit_condition_context *manifest, gitkit_condition_context *original);
int gitkit_condition_source_repository(gitkit_condition_context *manifest, gitkit_condition_context *original);
void gitkit_condition_retain(gitkit_condition_context *ctx);
void gitkit_condition_free(gitkit_condition_context *ctx);
int gitkit_condition_source_add(gitkit_condition_context *ctx, const char *path,
	const char *text, size_t len, git_config_level_t level, int command, int worktree);
gitkit_condition_context *gitkit_condition_current(void);
gitkit_condition_context *gitkit_condition_enter(gitkit_condition_context *ctx);
void gitkit_condition_invalidate(gitkit_condition_context *ctx);
int gitkit_condition_check(gitkit_condition_context *ctx);
int gitkit_condition_match(int *matches, gitkit_condition_context *ctx,
	const char *condition, const char *file);
int gitkit_condition_path(git_str *out, const char *path, const char *from);
int gitkit_config_authorize(const git_repository *repo, const char *path, const char *from, int depth);
int gitkit_condition_build_begin(git_config *cfg, gitkit_condition_context *ctx);
void gitkit_condition_build_end(git_config *cfg);

/* File backend helpers, also for a live config's atomic re-read. */
const char *gitkit_config_backend_path(git_config_backend *backend);
gitkit_condition_context *gitkit_config_backend_context(git_config_backend *backend);
int gitkit_config_backend_hasconfig(git_config_backend *backend);
int gitkit_config_backend_clone(git_config_backend **out, git_config_backend *backend);
git_config_backend *gitkit_config_backend_unwrap(git_config_backend *backend, int *filtered);
int gitkit_config_backend_filter(git_config_backend **out, git_config_backend *inner);
int gitkit_config_backend_command(git_config_backend **out, const char *text, size_t len, git_config_level_t level);
int gitkit_config_manifest_existing(gitkit_condition_context *ctx, git_config *cfg);
int gitkit_config_rebuild(git_config *cfg, git_config *commands, gitkit_condition_context *ctx);
int gitkit_scope_manifest(gitkit_condition_context *ctx);
void gitkit_config_scope__diagnostic(const char *condition, const char *gitdir);
void gitkit_config_scope__record(int code);

#endif
