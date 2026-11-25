# Conditional includes

This is the revised #107 contract on top of #111's corrective API and #112's
caller-owned config installation. The examined baseline is
`495da21ed46e33abf10d4aa0f91aa3df95de558e`. Existing public enum cases and both
`OperationConfiguration` initializer signatures are preserved. The new API
uses opaque struct elements and a required `commandLine:` initializer label.
Released tags are unchanged. The external Swift 5/6 compilation probes, not
the absence of `@frozen`, determine source compatibility.

```swift
let command = CommandLineConfig([
    .includeIf(condition: "onbranch:feature/**", path: included.path),
    .entries([ConfigEntry(name: "remote.origin.url", value: remoteURL)])
])
let diagnostics = try repository.setCommandLineConfig(command)
try Repository.withOperationConfiguration(
    OperationConfiguration(commandLine: command, onDiagnostic: consumeDiagnostics)
) {
    // Every repository opened here evaluates its own conditions.
}
// Also supported: an independently opened libgit2 config, with no repository.
try command.install(into: config)
```

An entries element stores directives without following them, preserving the
existing entries API. The include factories store the directive and follow it
in place. Element `i` keeps level `APP+i`, including a false condition; nested
file entries keep their origin, backend type and include depth. Supply paths
after invocation-specific interpolation. File patterns retain libgit2's `~/`
handling; `~user` and `%(prefix)` inside files remain outside this change.
Direct/live installation retains all valid entries, including repository-layout
settings. The repository-opening restriction on those entries applies only to
operation scopes; installing entries into an existing handle does not reopen it.

## Repository context and diagnostics

Each config build copies its own git directory and branch context. HEAD is read
directly, avoiding recursive repository-config reads through the refdb. Unborn
branches match; detached or unreadable HEAD does not. Gitdir patterns use
realpath then the absolute git directory, a literal prefix for `./` file
patterns, `**/` for unanchored patterns, directory suffix expansion, and case
folding for `gitdir/i`. Unknown conditions are false.

Without a repository, gitdir and onbranch are false without diagnostics or
target access. Hasconfig still runs. No relative-gitdir condition is lowered
by the host into an unconditional file. Within a repository a command-line
`gitdir:./` condition produces Git's nonfatal diagnostic and matches. A
relative command include target is an error only if reached. Live diagnostics
are returned; a scoped callback receives ordered diagnostics once after the
body returns or throws. Nothing is written to stderr. A handle keeps its
repository/branch context; a new application or open captures a new context.

## Complete prospective sources

Before `load_config` adds its first backend, a native hook copies a manifest:
PROGRAMDATA, SYSTEM, XDG, GLOBAL, LOCAL, applicable WORKTREE, and all prospective
APP elements. Scope replacements replace the corresponding path without
reading the original. Worktree applicability is determined from LOCAL during
the scan. Default configs get the complete repository-less search-path view.
An independently opened single file gets that file's view. Explicit
installation on an existing config copies its lower file paths and in-memory
URLs and appends the entire new command set before parsing any element.

The first hasconfig triggers a standalone parser over that manifest. It never
queries a partly built config and never calls `git_repository_config*` or
constructs a config recursively. It collects URLs from unconditional sources
and follows every hasconfig target, even one whose glob will not match. During
this pre-scan, **every followed conditional target**, including gitdir and
onbranch targets, and its descendants forbid `remote.*.url`. This is what Git
2.54 does. Normal unconditional includes contribute URLs. The URL set is reused
within the build and invalidated when a file is reparsed.

The pre-scan is the explicit exception to false-condition non-access. Every
include read in it is authorized first. A denial, cancellation expressed by
denial, unreadable target, forbidden URL or parse error fails the build. Missing
files are empty. False non-hasconfig targets are never offered, stat'd or read.

Live installation stages both command elements and any lower files whose
hasconfig decisions may change, then swaps complete backend vectors. Failure
leaves the live config untouched. With no hasconfig, lower file backends are
cloned from cached values without extra reads; their new manifest is retained
for subsequent refresh. Backends own their manifests beyond the scope lifetime;
command includes refresh with that same context. Snapshots keep old values.
URL collection also retains the file stamps and authorization origins of every
source it reads, including missing and nonmatching hasconfig targets. Before a
backend read, changed sources invalidate the shared URL set and advance a shared
generation. Each backend then reparses atomically against that generation, even
if its own file has not changed or its condition previously included nothing.
This works regardless of lookup order and does not recursively reopen config.
Lower write order is preserved and command elements never become writers;
typed repository writes retain LOCAL as their target. Internal-open failures
continue to use the scope's existing swallowed-error reporting and rollback.

Operation scopes still cover repository opens only. Default configs read by
init templates or detached remotes evaluate file conditions without a repository;
command elements are explicitly installed there through the #112 foundation.
No host workaround or reflected typed handle is required.

## Recorded Git oracle

Disposable fixtures were run with Apple Git `2.54.0 (Apple Git-157)`, isolated
HOME/global/system config, no network, and an unborn `main` repository. Stdout
below is either `Included\n` or empty. Diagnostic prefixes describe stderr;
platform launcher warnings were absent in these runs.

| Case | Exit | Stdout | Stderr |
|---|---|---|---|
| command `gitdir:./x/`, absolute target, no repository | 1 | empty | empty |
| same, inside repository | 0 | Included | relative condition diagnostic |
| `onbranch:main`, relative target | 128 | empty | relative include diagnostic; command parse failure |
| `onbranch:other`, relative target | 1 | empty | empty |
| no-repo hasconfig, URL in later command entry | 0 | Included | empty |
| nonmatching hasconfig target defines URL | 128 | empty | remote URL prohibition |
| matched gitdir target defines URL, unrelated hasconfig | 128 | empty | remote URL prohibition |
| nonmatching hasconfig target missing | 1 | empty | empty |
| nonmatching hasconfig target unreadable | 128 | empty | permission denied |
| hasconfig URL in a later unconditional include | 0 | Included | empty |
| LOCAL hasconfig, URL only in linked worktree config | 0 | Included | empty |
| same common config in the primary worktree | 1 | empty | empty |
| ten command include levels | 0 | Included | empty |
| eleven command include levels | 128 | empty | maximum include depth exceeded |
| ten existing files, missing eleventh target | 0 | Included | empty |

Primary references: [Git 2.54 config.c](https://github.com/git/git/blob/v2.54.0/config.c#L186-L418)
and [t1305-config-include.sh](https://github.com/git/git/blob/v2.54.0/t/t1305-config-include.sh).
GitKit returns values, diagnostics and errors; the host owns CLI exit-code
mapping. An eleventh include level, read for the config or during the
hasconfig URL pre-scan, throws `ConfigIncludeDepthError` with the limit (10),
the resolved path of the file being included and the path of the file that
includes it, so a host can print Git's `exceeded maximum include depth (10)
while including … from …` message. Public-consumer tests reproduce the old hasconfig failures and cover
the corrected no-repository behavior, policy, metadata, ordering and atomicity.
Native integration tests exercise internal submodule status/diff and linked
worktrees, alongside the existing scope, write and creation-rollback suites.

Verification on macOS: default and Archive builds and full suites, focused
AddressSanitizer configuration/rollback tests, SwiftLint with no violations,
and all 72 external-client Swift 5/6 outcomes across 2.17, 2.18, 2.19 and the
candidate match their expectations. The public enum inventory remains 163
cases. The intentional rejection of 2.18's removed `Level.layers` remains
visible; this does not claim compatibility for those unmigrated clients.
Other operating systems require CI confirmation. Existing toolchain warnings
and Archive's installed-library deployment-target warnings remain.
