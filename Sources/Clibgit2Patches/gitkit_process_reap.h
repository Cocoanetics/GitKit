/*
 * GitKit shim helper — bounded reap of a child pid (GitHub issue #38).
 *
 * Shared by ssh_exec_patched.c (the ssh_exec transport's close path) and
 * process_patched.c (git_process_free()'s backstop). Polls waitpid(WNOHANG)
 * for a short grace period, then escalates to SIGTERM and finally SIGKILL
 * before a final blocking wait, so a wedged child can never block the
 * caller forever. "No such child" is treated as already reaped (e.g. by
 * the other call site), not an error.
 *
 * Unix-only: both call sites include this only under GIT_SSH_EXEC (macOS /
 * iOS / Linux), which is never defined on Windows.
 */
#ifndef GITKIT_PROCESS_REAP_H
#define GITKIT_PROCESS_REAP_H

#include <errno.h>
#include <signal.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>

/* Grace period before escalating, in milliseconds; polled every 20ms. */
#define GITKIT_REAP_POLL_MS 20
#define GITKIT_REAP_GRACE_MS 1000

static void gitkit_process_reap(pid_t pid)
{
	struct timespec interval = { 0, GITKIT_REAP_POLL_MS * 1000 * 1000 };
	int waited_ms, status;

	if (pid <= 0)
		return;

	for (waited_ms = 0; waited_ms < GITKIT_REAP_GRACE_MS; waited_ms += GITKIT_REAP_POLL_MS) {
		pid_t ret = waitpid(pid, &status, WNOHANG);

		if (ret == pid || (ret < 0 && errno == ECHILD))
			return;

		nanosleep(&interval, NULL);
	}

	kill(pid, SIGTERM);

	for (waited_ms = 0; waited_ms < GITKIT_REAP_GRACE_MS; waited_ms += GITKIT_REAP_POLL_MS) {
		pid_t ret = waitpid(pid, &status, WNOHANG);

		if (ret == pid || (ret < 0 && errno == ECHILD))
			return;

		nanosleep(&interval, NULL);
	}

	kill(pid, SIGKILL);

	/*
	 * Blocking wait: with a non-restarting handler installed, a signal
	 * arriving while we're blocked here can make waitpid return -1/EINTR
	 * before the (by-now SIGKILLed) child has actually been reaped. Retry
	 * until it hands back the pid, or ECHILD says someone else already did.
	 */
	while (waitpid(pid, &status, 0) < 0 && errno == EINTR)
		;
}

#endif
