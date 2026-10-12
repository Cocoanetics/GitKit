/*
 * GitKit shim — backstop reap in git_process_free() (GitHub issue #38).
 *
 * Nothing in libgit2's public API forces a caller to git_process_wait()
 * before freeing a git_process — ssh_exec_patched.c covers the one caller
 * in this codebase (the ssh_exec transport's close path) directly, but as
 * a backstop this reaps any child whose pid is still set when the process
 * is freed, the same bounded way: close the pipes, poll waitpid(WNOHANG)
 * briefly, escalate to SIGTERM then SIGKILL if it's still running, then a
 * final blocking wait. Not shimmed on Windows — src/util/unix is excluded
 * there already (win32's process backend has no equivalent zombie risk).
 */
#include "git2_util.h"
#include "process.h"

static void gitkit_process_free_original(git_process *process);

#define git_process_free gitkit_process_free_original
#include "unix/process.c"
#undef git_process_free

#include "gitkit_process_reap.h"

void git_process_free(git_process *process)
{
	if (process && process->pid) {
		git_process_close(process);
		gitkit_process_reap(process->pid);
		process->pid = 0;
	}

	gitkit_process_free_original(process);
}
