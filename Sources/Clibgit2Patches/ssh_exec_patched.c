/*
 * GitKit shim — reaps the `ssh` child in the close path (GitHub issue #38).
 *
 * ssh_exec_subtransport_close() hands the finished `ssh` process to
 * git_process_close() + git_process_free() without ever waiting on it, so
 * `waitpid` never runs and the child sits as a zombie until the whole
 * process exits. A short-lived git CLI never notices — its zombies vanish
 * when the CLI exits — but a long-running daemon (e.g. one fetching over
 * SSH in a loop) accumulates one zombie per connection.
 *
 * We rename this file's one `git_process_close` call (inside
 * ssh_exec_subtransport_close()) to a wrapper that reaps the child right
 * after closing its pipes — `ssh` exits as soon as its stdin hits EOF, so
 * the wait is normally immediate; gitkit_process_reap() bounds it in case
 * `ssh` is wedged. process_patched.c adds the same reap as a backstop
 * inside git_process_free() itself, for any caller that skips the wait.
 *
 * (The same gap exists in upstream libgit2; this fix is worth offering
 * there too.)
 */
#include "common.h"
#include "process.h"

#ifdef GIT_SSH_EXEC
#include "gitkit_process_reap.h"

static int gitkit_ssh_exec_process_close(git_process *process);
#endif

#define git_process_close gitkit_ssh_exec_process_close
#include "transports/ssh_exec.c"
#undef git_process_close

#ifdef GIT_SSH_EXEC
static int gitkit_ssh_exec_process_close(git_process *process)
{
	int error = git_process_close(process);
	p_pid_t pid;

	if (process && git_process_id(&pid, process) == 0)
		gitkit_process_reap(pid);

	return error;
}
#endif
