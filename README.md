# GitKit

**[libgit2](https://libgit2.org) as a Swift package — C library and idiomatic
Swift SDK.** GitKit compiles the official libgit2 C sources straight from an
upstream git submodule — no CMake, no system install — and layers a full Swift
API over them, on macOS, iOS, Linux, Windows, and Android.

```swift
import GitKit

let repo = try Repository.open(at: URL(fileURLWithPath: "/path/to/repo"))

let branch = try repo.currentBranch()                     // "main"
let report = try repo.status()                            // git status
try repo.add(paths: ["README.md"])                        // git add
let commit = try repo.commitDetailed(
    message: "Update README",
    author: Signature(name: "Jane", email: "jane@example.com"),
    allowEmpty: false)                                    // git commit
print(commit.shortSHA)

for entry in try repo.log(LogQuery(maxCount: 10)) {       // git log
    print(entry.shortSHA, entry.subject)
}
```

## Custom filters

`GitFilters` registers LFS-agnostic clean/smudge filters process-wide. A path
selects a driver with `.gitattributes`, for example `*.txt filter=upper`:

```swift
try GitFilters.register(name: "upper", clean: { source, input in
    Data(String(decoding: input, as: UTF8.self).lowercased().utf8)
}, smudge: { source, input in
    Data(String(decoding: input, as: UTF8.self).uppercased().utf8)
})
// Later, when no new operations should use this driver:
try GitFilters.unregister(name: "upper")
```

For large content, use `GitFilter(clean:smudge:)` with `@Sendable` stream
factories. Each factory receives a `GitFilterSource` (driver, direction,
repository-relative path, file mode, optional object ID, Git directory and
optional working directory) and a `GitFilterOutput`. Return a new
`GitFilterStream` whose `write(_:)` consumes borrowed input chunks and whose
`close()` flushes output with `try output.write(bytes)` or `try output.write(data)`.
Do not retain borrowed chunks or use the output asynchronously. A stream's
callbacks are serial, but different files/repositories can filter concurrently.
Use deinitialization to release temporary resources if a write fails, since
the stream's `close()` is skipped after failure. Downstream is always closed.

```swift
final class CopyFilter: GitFilterStream {
    let output: GitFilterOutput
    init(output: GitFilterOutput) { self.output = output }
    func write(_ chunk: UnsafeRawBufferPointer) throws { try output.write(chunk) }
    func close() throws {}
}

try GitFilters.register(name: "copy", GitFilter(
    clean: { _, output in CopyFilter(output: output) },
    smudge: { _, output in CopyFilter(output: output) }))
```

The default attributes match `filter=<registered name>`; `attributes:` accepts
libgit2's attribute expression syntax. Priority defaults to 200, after CRLF
(0) and ident (100) on smudge, and before them on clean; the `Int32.min` and
`Int32.max` endpoints are reserved for required-driver enforcement. Registration
rejects duplicate names. Use unique names in tests. Unregistering preserves in-flight
Swift streams/closures. Because libgit2 keeps raw pointers in loaded filter
lists, the small C filter struct and its attributes intentionally remain
allocated for process lifetime after each successful registration cycle.
Register/unregister outside callbacks other than stream factories or stream
methods; libgit2 holds its registry read lock during attribute checks.

The first registration enables a guard for missing drivers with
`filter.<name>.required=true`. `GitFilters.enforceRequiredDrivers()` enables
that guard explicitly without registering a driver. It stays enabled after
unregistering. Applications that never use `GitFilters` retain libgit2's
existing behavior. A required driver lacking a closure for the requested
direction fails. Optional missing directions, nil stream-factory results,
and nil buffered-transform results pass through unchanged. Buffered transforms
also fall back to original input on optional errors. Streaming errors always
fail, even for optional drivers, since emitted output cannot be retracted.
Failures throw `GitFilterError` with the driver, path, direction, reason and
original Swift error. A failed checkout can leave partially written files.

The bridge uses libgit2's streaming API exclusively, but libgit2 1.9 still
buffers smudge **input** (the blob), clean **output** during add, and whole
working-tree files during status/diff hashing. Clean input during add arrives
in chunks of at most 64 KiB; smudge output can be emitted in bounded chunks.
This fits LFS, where smudge input and clean output are small pointer files.
Raw blob reads (`catFileBlob`) and archives do not invoke these filters.

## The Swift SDK

`Repository` mirrors libgit2's own `git_repository *` model: open (or
`initialize` / `clone`) a handle, call operations on it, let ARC free it.
Operations are synchronous, `throws` (typed ``Libgit2Error``), and return
`Sendable` value types. The surface covers the everyday git command set:

- **Lifecycle** — `open`, `initialize` (git init), `clone` (with
  `CredentialProvider` closures for HTTPS/SSH auth, a pluggable progress
  sink, and `depth`/`singleBranch`/`branch` for shallow, single-branch
  clones).
- **Preparing before the first checkout** — `clone(…preparation:)` and
  `worktreeAdd(…preparation:)` take a `RepositoryPreparation`: a closure
  given the very `Repository` the operation goes on with, after it exists
  and before any working-tree file is written, so a host can install its
  per-operation config, credentials or filter setup there instead of
  process-wide. A clone runs it from libgit2's `repository_cb`, before
  `origin`, the fetch and the checkout; a worktree is created without an
  index or files, its own repository (private git directory, shared common
  directory) is prepared, and its initial checkout then runs once on it.
  Both return that repository. A thrown error comes back as is, after
  removing only what the operation created (an existing empty clone target
  is emptied, not removed; a branch is deleted only if the call created
  it and it hasn't moved). If a clone fails after its preparation, libgit2 has freed the
  handle: a `Repository` the closure kept stops the process on its next
  use rather than touch freed memory. Without a preparation both check out
  as before. With or without one, `worktreeAdd` puts the repository's
  include policy over libgit2's own open of the new worktree. Adds through
  GitKit take turns per repository for the whole add, rollback included
  (`gitkit-worktree-add.lock` in the common directory, refused while held,
  like git's own locks; so is an add from inside a preparation). If libgit2
  fails part way, a directory that wasn't there before is removed only
  while empty (`rmdir`, one atomic step): nothing proves libgit2 made one
  with content rather than another writer, so it is kept. The exception
  is a creation that fails in the new repository's own init or open,
  before the preparation runs (its config load refusing an include, say):
  the directories GitKit or libgit2 made exclusively for it are moved
  aside in one step and removed, all or none, only if they are still those
  directories and hold nothing but what the init or add wrote, unchanged;
  otherwise they are moved back and kept, with the branch. Missing parent
  directories of a clone target are kept. On Windows identity is the
  volume serial number and file ID, checked by handle; where a volume
  can't open by file ID (FAT/exFAT, network shares) everything is kept, and
  a retry at the same location still fails. (libgit2 itself refuses a
  Windows repository path longer than `MAX_PATH` less 92, whatever
  `core.longpaths` says, so a clone or worktree that deep fails before
  any of this.) A prepared
  worktree whose preparation or checkout fails was made by this add, and
  is pruned. A branch the add created is deleted only while it still
  points where it was created (one moved, or deleted and made again
  elsewhere, is kept); of its config, only the upstream the add wrote is
  removed, and only while unchanged. A name whose administrative directory an incomplete add left
  behind is skipped. A single-branch
  clone discovers the remote's default branch through the clone's own
  config, as the fetch does.
- **Operation-only config levels** — `addConfigFile(at:level:)` reads a
  file as the `.system`, `.xdg`, `.global` or `.app` level of one repository's
  live config (what `GIT_CONFIG_SYSTEM` / `GIT_CONFIG_GLOBAL` select), and
  `addConfigEntries(_:level:name:)` adds a read-only in-memory level from
  `ConfigEntry` name/value pairs (what `-c` / `GIT_CONFIG_COUNT` give),
  keeping their order, a valueless entry (`nil`) apart from an empty one,
  and the subsection exactly (`configEntries()` lists valueless entries,
  which `configList()` leaves out). Each replaces what the level held, reads an
  added file's includes with the repository's `ConfigIncludePolicy`, and
  leaves the config as it was when it throws. Merged-config writes keep
  going to the repository's own file; after a `.global` add, an explicit
  `.global` scope means that file, not the XDG one. libgit2's cached
  `core.*` values, attribute and ignore files, a loaded index's
  capabilities and diff drivers are derived again, so the next use sees
  the new level. Other copies libgit2 keeps are not refreshed, for example
  settings read at open and those the loaded reference and object databases
  copied (`core.precomposeUnicode`, `core.fsyncObjectFiles`, their
  `core.ignorecase`). The
  level belongs to that `Repository` only; add it from a preparation to
  govern a clone or worktree's first checkout. Which files and entries to
  add is the host's policy.
- **Command-line config layers** — `addConfigLayers(_:)` reads git's
  `-c a=1 -c include.path=<file> -c b=2` in order, as `ConfigLayer`s
  (`.entries([...])`, `.file(url)`, `.entries([...])`) at consecutive levels
  from `.app` up: a later layer wins a single read, the included file is the
  origin of its entries, and its own includes go through the include policy.
  The whole set is read before it replaces the previous one (an `.app` add
  replaces it too), a missing layer file reads as empty and an unreadable one
  is an error; writes keep going to the repository's own file. The host
  resolves the include's path and keeps `include.path` among the entries.
- **Layers for a config GitKit doesn't own** — `ConfigLayer.install(_:into:repository:)`
  installs the same layers into a libgit2 `git_config *` the host opened with
  the re-exported C API: a repository's config from `git_repository_open_ext`,
  `git_config_open_default` outside any repository, or `git_config_new`. It
  replaces every level from `APP` up, all or nothing; the layers are never
  write targets and the config's other write order is kept (the repository's
  own file, or the global file). The caller keeps both pointers; the optional
  `git_repository *` is the context of a layer file's includes and must
  outlive the config, since a changed layer file is re-read with it. Each read
  asks the include policy in force for it (a C per-handle registration, the
  thread's operation scope, or the process default). Nothing derived from the
  config is refreshed: install before the repository uses it.
- **Conditional command-line includes** — `CommandLineConfig` provides opaque
  `.entries`, `.include(path:)` and `.includeIf(condition:path:)` elements,
  without adding cases to existing public enums. Apply one to an already-open
  repository with `setCommandLineConfig`, to a caller-owned config with
  `install(into:repository:)`, or to every repository opened in an operation
  with `OperationConfiguration(commandLine:)`. `gitdir:`, `gitdir/i:` and
  `onbranch:` use each handle's own context, including internal submodule and
  linked-worktree opens. `hasconfig:remote.*.url:` works outside a repository
  too, and sees the complete prospective source set, including later command
  entries and includes. Its URL pre-scan reads even nonmatching hasconfig
  targets, subject to the include policy, and forbids remote URLs in every
  conditional target it follows. False gitdir/onbranch/unknown targets are
  never authorized or accessed. Git's nonfatal relative-gitdir diagnostic is
  returned by the live API or delivered after the scoped body through
  `onDiagnostic`; GitKit prints nothing. Failure is atomic and writes stay
  local. An include chain deeper than git's ten levels throws
  `ConfigIncludeDepthError` (`limit`, `includedPath`, `includingPath`), from
  which a host can print git's `exceeded maximum include depth` message. See [the contract and Git oracle results](docs/conditional-config.md).
- **Operation configuration** — `Repository.withOperationConfiguration(_:_:)`
  gives the same levels (`OperationConfiguration.Level.file` /
  `.entries`) and command-line layers (`OperationConfiguration.layers`,
  set with `OperationConfiguration(levels:layers:includePolicy:)`: `nil`
  keeps the outer scope's, `[]` clears them; together with an `.app` level
  they are refused before the body) to every repository opened on the calling thread while its
  synchronous body runs, from the open on, including those libgit2 opens
  itself: each submodule during `status` / `diff`, submodule sync, a staged
  gitlink, worktree checks, a local clone. A replaced level's search-path file
  is not read; writes keep going to each repository's own file; nothing global
  changes; a nested call replaces only the levels it names, and its end
  restores the outer scope. Its optional
  `includePolicy` authorises those repositories' includes. libgit2 clears the
  error of a submodule it fails to open; such a failure (a refused include,
  an unreadable level) is recorded and thrown after a body that returned
  normally, unless a GitKit call already threw it to the body. Repositories
  opened earlier keep their config. Entries git reads from the repository's
  own config only (`core.repositoryformatversion`, `core.bare`,
  `core.worktree`, `extensions.*`) are refused, and skipped in a file level
  and the files it includes. A level's missing file reads as empty; one that
  exists but cannot be read is thrown before the body runs, and fails any open
  that later finds it unreadable. Not covered: configs libgit2
  reads without opening a repository (an init's template directory and
  `init.defaultBranch`, a detached remote).
- **Work** — `add`, `commitDetailed`, `amendDetailed`, `status`, `diff`,
  `checkout`, `checkoutNewBranch`, `checkoutPaths`, `reset`,
  `move`/`remove` (git mv/rm).
- **Amending** — `amendDetailed(message:author:resetAuthor:allowEmpty:allowEmptyMessage:cleanup:env:)`
  is `git commit --amend`: the tip commit is replaced by one with its
  parents and the index's tree, the old message (and author, author date
  included) unless a new one is given (`--author` keeps the date,
  `resetAuthor` is `--reset-author`), the committer resolved as for a new
  commit, and the old commit's extra headers (`mergetag`, not its
  signature) kept. The message is cleaned up as git does (`cleanup:` is `--cleanup`,
  else `commit.cleanup`, else whitespace), a kept one re-encoded to
  `i18n.commitEncoding`. `index.lock` is held until HEAD or its branch has
  moved, with git's reflog entry `commit (amend): <subject>` under the
  committer; a concluded revert's state is cleared. Git's refusals throw
  `CommitAmendError` with git's wording: `nothingToAmend` (unborn HEAD),
  `mergeInProgress`, `cherryPickInProgress`, `invalidCleanupMode`,
  `unmergedFiles`, `wouldBeEmpty` when the tree equals the first parent's
  (the empty tree for a root commit) without `allowEmpty` — a merge commit
  excepted — and `emptyMessage` without `allowEmptyMessage`. The returned
  `Libgit2CommitDetails` carries what git's summary prints: the diffstat and
  `create`/`delete mode` files against the first parent, `renamedFiles`
  for the ` rename` lines (found and scored as git does), `author` /
  `committer` (` Author:` when they differ), and `showsAuthorDate` with
  `ResolvedSignature.formattedDate` for the ` Date:` line git prints after
  every amend that keeps the authorship.
- **Index** — `indexedEntries` (`git ls-files -s`, with the skip-worktree /
  assume-unchanged bits and the `ls-files -v` tag), `isTracked`,
  `setSkipWorktree` / `setAssumeUnchanged` (git update-index; a held
  `index.lock` throws ``Libgit2Error/isLocked`` and leaves the index as it was).
- **History** — `log` (rich `LogQuery`/`LogEntry` incl. `format(_:)`
  placeholders), `blame`, `describe`, `reflog`, `grep`.
- **Branches & refs** — `localBranches`, `remoteBranches(remote:)` (remote-qualified
  names and target SHAs, including symbolic remote HEADs), `references(matching:)`
  (full ref names and target SHAs across namespaces, filtered by an optional glob),
  `branchDelete`/`branchRename`,
  `tagList`/`tagCreate`/`tagCreateAnnotated`/`tagDelete`, `resolveOID`,
  `revParse` helpers, `lsTree`, `catFileBlob`/`objectMetadata`.
- **Integration** — `merge` (fast-forward modes), non-mutating `mergeTree`
  (commit and explicit-tree overloads) and `isAncestor`, octopus merges
  (`mergeHeads(reducing:)`, `octopusMerge`), `rebase` (continue/skip/abort),
  `cherryPick`, `stash` (save/apply/pop/list/show/branch), `apply` (patches).
- **Non-mutating merge-tree & ancestry checks** —
  `mergeTree(ours:theirs:options:)` (commit form with recursive virtual merge
  bases via `git_merge_commits`), `mergeTree(base:ours:theirs:options:)`
  (explicit-tree form via `git_merge_trees`), and `isAncestor(_:of:)`
  (`git merge-base --is-ancestor`). Inputs are resolved and pinned once, and
  only `Sendable` value types (`MergeTreeResult`, `MergeTreeConflict`) are
  returned; refs, reflogs, `HEAD`, `MERGE_*`, the index file, and working-tree
  files are never mutated.
  - *Object policy*: defaults to `MergeTreeOptions.Objects.inMemory` (a private
    mempack layered over the repository's object database as read-only
    alternates with freshening disabled, so no objects are written and existing
    object/pack timestamps are untouched; newly synthesised result tree OIDs
    may not exist in the caller's object database afterwards). Passing
    `.write` persists newly created merge blobs and trees as loose,
    unreferenced objects (eligible for Git GC) via an independently owned
    private handle, leaving the caller's handle and refs/index/worktree
    untouched.
  - *Attribute source*: defaults to `MergeTreeOptions.AttributeSource.ours`,
    reading repository `.gitattributes` from the resolved `ours` tree via a
    private in-memory index — never from the caller's live index or working
    tree (an intentional divergence from `git merge-tree` in a non-bare
    checkout so uncommitted or staged `.gitattributes` edits cannot perturb
    preservation proofs). `.tree(spec)` selects a specific tree; `.none` uses
    an empty in-memory index (omitting all tree `.gitattributes`). In all
    modes, `$GIT_COMMON_DIR/info/attributes`, `core.attributesFile` (from the
    config snapshot, or XDG `git/attributes` when unset), and system
    `gitattributes` still apply in libgit2's standard precedence.
  - *Fail-closed limits*: throws `MergeTreeError.unsupportedRenormalize` when
    `merge.renormalize` is true (libgit2 does not renormalize during merge) and
    `MergeTreeError.externalMergeDriver(path:driver:)` when a path involved in
    the merge — including recursive virtual-base steps — selects a configured
    `merge.<name>.driver` (GitKit never spawns external merge drivers; an
    unconfigured name falls back to text as Git does, and `favor != .normal`
    overrides attribute drivers as libgit2 does). Throws
    `MergeTreeError.invalidRenameThreshold` for thresholds outside `1...100`.
  - *Cancellation*: checks `Task.checkCancellation()` between stages (before
    opening, after pinning inputs, during driver inspection, before the merge,
    and before writing the result tree); an in-flight libgit2 merge call cannot
    be interrupted mid-flight.
- **Remotes** — `fetch` (with shallow `depth`), `unshallow`, `push` (incl.
  `-u` upstream wiring and git's per-ref summary; refs git refuses —
  `fetch first`, `non-fast-forward`, a tag that `already exists` — are
  left out and reported through `PushRejectedError` while the rest go
  through; what git refuses before sending anything — a source that
  matches nothing, two refspecs to one ref, a deletion of nothing, a short
  destination it can't complete — throws `PushRefusedError`, every
  refusal listed with git's message and hint), `addRemote`,
  `remoteList`, `remoteURL`, real-git-style progress output (fetch's per-ref
  summary included, and remotes shown without their credentials). Remotes go in
  as git spells them (`clone(fromRemote:)`, `addRemote(name:remote:)`),
  and `fetch` / `push` take a URL or path as well as a remote's name, and
  a set of refspecs applied together, as git applies them: negative
  refspecs (`^refs/heads/wip`), and for `push`, patterns and the matching
  refspec `:`. A caller that resolves the remote itself — git opens a
  relative remote from the top of the work tree, libgit2 from the
  process's directory — passes `connectingTo:` to `fetch`, `unshallow`
  and `push`: libgit2 connects to exactly that location (no `insteadOf`
  rewriting), so what the caller authorized is what gets opened, while a
  configured remote keeps its name for its refspecs, tracking refs and
  `-u`, and the output (`From`/`To`, `FETCH_HEAD`, `PushRejectedError.url`,
  `PushRefusedError.url`) names the remote as configured or as given
  (`To ../bare`). `push(…leases:)` is `git push --force-with-lease`:
  each ref a ``PushLeases`` lease covers is forced while the remote ref is
  where the lease expects it (its remote-tracking ref, an object ID, or
  absent) and refused as `stale info` otherwise, the rest of the push
  going ahead. `fetch(…tags:)` is `--tags` (`.all`) / `--no-tags`
  (`.off`), `nil` leaving it to `remote.<name>.tagOpt`; as in git, a
  non-forced refspec never moves a tag this repository has — that's
  refused as `would clobber existing tag` and thrown as
  `FetchRejectedError` once the rest is fetched. `GitSSHTransport.register(_:)` lets a
  host plug its own in-process SSH client (e.g. one built on
  swift-nio-ssh) in place of libgit2's process-spawning `ssh_exec`
  transport for `ssh://` and scp-style remotes; `unregister()` restores
  the default.
- **Bulk traversal** — `treeBlobs` walks a tree in one pass with content
  loaded (`git ls-tree -r` order); `commitTime` gives the reproducible
  timestamp `git archive` stamps entries with.
- **`git archive`** — `Repository.archive(treeish:format:to:prefix:)`
  produces tar / tar.gz / tar.bz2 / tar.xz / tar.zst / zip, **behind the
  opt-in `Archive` trait** (see below).

Commit-identity resolution honours real git's `GIT_AUTHOR_*` /
`GIT_COMMITTER_*` env-precedence chain (``SignatureResolver``, returning a
typed ``ResolvedSignature``); pass `env:` explicitly when you virtualise the
environment. `Repository`'s internal libgit2 handle is **not** exposed — the
typed surface is the API. The libgit2 C API itself remains re-exported
(`git_repository_open`, `git_clone`, …) for code that wants to drive libgit2
directly with its own handles.

The SDK performs **no access gating and reads no ambient state** — it's a pure
library. Hosts that sandbox file access (e.g.
[SwiftPorts](https://github.com/Cocoanetics/SwiftPorts)' `GitClient`, which
backs its in-process `git` CLI) authorize paths before opening and wrap calls
in their own isolation, composing this SDK rather than configuring it.

## Installation

```swift
.package(url: "https://github.com/cocoanetics/GitKit.git", from: "2.0.0"),
```

```swift
.target(name: "MyApp", dependencies: [.product(name: "GitKit", package: "GitKit")]),
```

SwiftPM initializes the libgit2 submodule automatically when it resolves the
package — there is nothing else to install.

### The `Archive` trait — `git archive` support

`Repository.archive` needs an archive *writer*, which GitKit gets from
libarchive via [swift-archive](https://github.com/marcprux/swift-archive).
That dependency is gated behind the **`Archive` trait, off by default** —
mirroring SQLiteKit's `FTS5`/`SQLiteVec` pattern — so plain consumers build
zero extra code:

```swift
.package(url: "https://github.com/cocoanetics/GitKit.git", from: "2.1.0",
         traits: ["Archive"]),
```

(or `swift build --traits Archive` when building GitKit directly). With the
trait off, `Repository.archive` and `GitArchiveFormat` simply don't exist;
the underlying tree-walk (`treeBlobs` / `commitTime`) is always available.
The bz2 / xz / zstd filters work where libarchive ships them — macOS /
Linux / Windows; iOS / Android throw libarchive's "filter not enabled".

> **Why 2.1.0?** Before it, GitKit pinned swift-archive by commit (no
> tagged release carried its platform gating), and SwiftPM only lets a
> *version*-referenced package carry such a pin while the guarding trait is
> **off**. Consumers who enabled `Archive` therefore had to reference GitKit
> by branch. 2.1.0 requires swift-archive `from: "3.8.9"`, so the trait now
> works from a plain version requirement.

## Versioning

GitKit follows **independent semantic versioning**, and every release states
the libgit2 it vendors:

| GitKit | vendors libgit2 |
|---|---|
| 2.x | v1.9.4 |
| 1.9.4 (legacy) | v1.9.4 |

Up to `1.9.4`, GitKit's version mirrored the libgit2 release 1:1 — the package
was pure packaging, so the numbers could be identical. With the Swift SDK the
package has its own evolution (API additions, fixes) between libgit2 releases,
which a mirrored version number can't express. SDK changes bump GitKit's
major/minor/patch per SemVer; a libgit2 submodule bump is called out in the
release notes (and in this table).

A new case in a public enum is **not** a compatible minor addition: a client
may switch over the enum exhaustively, with no `default`, and that switch
stops compiling (GitKit is built without library evolution, so `@frozen` or
its absence changes nothing). Such a change is major, or the value goes into
a new property or type instead. `Scripts/check-enum-cases.sh` compares the
public enum cases with `compat/public-enum-cases.txt`, and
`Scripts/check-source-compat.sh` builds the external clients in
`compat/clients` against released versions and the working tree, in the
Swift 5 and Swift 6 language modes (see [compat/README.md](compat/README.md)).

### 2.18.0 broke source compatibility; 2.19 restores 2.17's

2.18.0 added a third case, `OperationConfiguration.Level.layers`, as a
minor release. A 2.17 client with an exhaustive `switch` over `Level` fails
to build against 2.18.0 ("switch must be exhaustive", in Swift 5 and Swift 6
modes). 2.18.0 stays published as it is; 2.19 restores `Level` to exactly
2.17's `.file` and `.entries` and moves the command-line layers to a
property:

```swift
// 2.18.0 only — does not compile with 2.19:
OperationConfiguration(levels: [.file(global, .global), .layers(layers)])
// 2.19:
OperationConfiguration(levels: [.file(global, .global)], layers: layers)
```

Both cannot hold at once: a `Level` with exactly 2.17's cases keeps 2.17
clients building, and the 2.18 code that constructs or matches `.layers`
(`case .layers`, `Level.layers(...)`) has to move to
`OperationConfiguration.layers` / `init(levels:layers:includePolicy:)` when
it updates to 2.19. `ConfigLayer`, `Repository.addConfigLayers(_:)` and
2.17's `init(levels:includePolicy:)` (also as a function value) are
unchanged; the compile probes in `compat/` show the 2.17 exhaustive,
`@unknown default`, initializer and construct-only clients building with
2.19, and the 2.18 `.layers` client failing. 2.19 is therefore not
source-compatible with every 2.x caller: code naming `.layers` must migrate. A package
that requires `from: "2.18.0"` and uses `.layers` should migrate before it
resolves 2.19, or pin `.upToNextMinor(from: "2.18.0")` until it does.

## Supported platforms

| Platform | HTTPS backend | SHA backend | Status |
|---|---|---|---|
| macOS / iOS | SecureTransport | CommonCrypto | ✅ |
| Linux | OpenSSL (dynamic) | builtin (SHA1DC) | ✅ |
| Windows | WinHTTP | Win32 BCrypt | ✅ |
| Android | OpenSSL (dynamic, Bionic) | builtin (SHA1DC) | ✅ |

Every supported platform builds in CI on each push, all with Swift 6.4: macOS, Linux, and Windows
also run the test suite; iOS is cross-compiled (`xcodebuild`); Android
cross-compiles and runs its tests on the emulator. The `Package.swift`
re-expresses libgit2's CMake feature detection as a per-platform `-D` matrix
(`LIBGIT2_NO_FEATURES_H` + explicit defines), choosing the native
TLS/hash/NTLM backend for each platform.

> **tvOS / watchOS** are not supported: libgit2's process layer
> (`src/util/unix/process.c`) uses `fork`/`execve`, which Apple marks
> unavailable on those platforms.

## Acknowledgements

GitKit stands on the shoulders of
**[ibrahimcetin/libgit2](https://github.com/ibrahimcetin/libgit2)**, which
pioneered building libgit2 as a SwiftPM target and worked out much of the
per-platform define matrix this package builds on. Huge thanks to İbrahim Çetin
for that groundwork. GitKit's distinct goals are to (a) track libgit2 release
tags 1:1, (b) keep the libgit2 checkout a *pristine* upstream submodule, and
(c) cover Windows and Android.

## The `struct entry` wrangling (why there are two shim files)

libgit2's `src/libgit2/indexer.c` and `deps/xdiff/xpatience.c` each define a
**file-local `struct entry`**. That is perfectly legal C — a struct tag defined
in a `.c` is private to that translation unit, and CMake compiles each `.c`
separately, so the two never meet.

SwiftPM is different. To expose a C target to Swift it compiles the sources as
a **clang module**, which makes the platform SDK module — including POSIX
[`<search.h>`](https://pubs.opengroup.org/onlinepubs/9699919799/basedefs/search.h.html),
whose `hsearch` API *also* declares `struct entry` — visible to every
translation unit. clang's cross-TU ODR check then rejects libgit2's same-named
struct:

```
error: type 'struct entry' has incompatible definitions in different translation units
  indexer.c:        field has name 'oid' here
  <search.h>:       field has name 'key' here
```

The fix is a tiny rename of the two file-local tags. But we refuse to modify the
submodule, so each is compiled through a **translation-unit-scoped `#include`
shim** in [`Sources/Clibgit2Patches`](Sources/Clibgit2Patches):

```c
#define entry git_indexer_entry   // scoped to THIS file only
#include "indexer.c"              // the pristine upstream source
#undef entry
```

Because the `#define` lives only in the shim's translation unit, libgit2's
public headers — compiled by *your* code without the define — are untouched, so
there is no ABI mismatch. (A package-wide `-Dentry=…` is **not** safe: a bare
`entry` identifier appears in ~21 of libgit2's public headers, and `util.c`
genuinely uses `<search.h>`.)

### Why this isn't a build-tool plugin

The obvious instinct is "use a SwiftPM build plugin to rewrite the two files
before compiling." **It cannot work:** SwiftPM refuses to compile
plugin-generated C sources. Both plugin modes (`buildCommand` and
`prebuildCommand`) emit

```
warning: C source file generation not enabled: …/indexer.c
```

and then silently drop the generated file, so the build fails at link with
undefined `git_indexer_*` symbols. There is no flag to enable it (verified on
Swift 6.3). Plugin-generated **Swift** is compiled; C/C++/Objective-C is not.
The `#include` shim sidesteps the limitation entirely — it's an ordinary
checked-in source file, so SwiftPM compiles it normally.

### Behaviour fixes, the same way

The same kind of shim carries the few changes GitKit makes to how libgit2
behaves, each reported upstream:

- `ssh_exec_patched.c` and `process_patched.c` reap the `ssh` child when an
  `ssh_exec` connection closes, instead of leaving a zombie per connection
  (#38, libgit2/libgit2#7437).
- `remote_patched.c` keeps the refs a negative fetch refspec
  (`^refs/heads/wip`) excludes out of the ref updates, `FETCH_HEAD` and
  pruning, as git does. libgit2 only leaves them out of the negotiation,
  then updates them anyway whenever their objects are present, and prunes
  their remote-tracking refs once they're gone from the remote
  (libgit2/libgit2#7435). It also lets an explicit refspec for a tag
  (`refs/tags/v1:refs/custom/x`) take effect, where libgit2's tag
  auto-following claimed the tag first and never applied the refspec
  (libgit2/libgit2#7438).
- `config_file_patched.c` makes `configSet` / `configUnset` consider only the
  entries of the file being written. libgit2 counted the entries of
  `[include]`d files too, so a key an included file repeats failed with
  "entry is not unique due to being included"; git writes to the file and
  leaves the include alone.
  The same shim lets a host authorise the include files libgit2 reads (see
  below), and keeps libgit2 from crashing when a config reload fails: its
  `get_entry()` freed through an uninitialised pointer after a backend `get`
  error.

#### Authorising `[include]` files

A sandbox has to know which files a config reads. `ConfigIncludePolicy` is
asked for every `[include]`, matching `[includeIf]` and nested include, before
the file is stat'd or read; returning `false` fails the config load with
`include of '<path>' is not authorised`. Policies are per repository, so
several sandboxes can share a process; with none, includes are read as before.

```swift
let policy = ConfigIncludePolicy { include in
    sandbox.mayRead(include.path)       // also: include.includedFrom, include.depth
}
let repo = try Repository.open(at: url, includePolicy: policy)
// or: try repo.setIncludePolicy(policy)
// fallback for repositories without one: ConfigIncludePolicy.setDefault(policy)
```

From C (`CGitKit`): `gitkit_config_set_include_callback(repo, cb, payload)`.

## The curated module and vendored headers (Windows, and why the submodule stays pristine)

libgit2's public headers assume two things the Windows MSVC/clang-cl toolchain
doesn't provide: a lowercase `ssize_t` (used by `git2/sys/stream.h`), and that
its bundled VS2008-era `git2/stdint.h` polyfill won't fight the real
`<stdint.h>`. Upstream forks fix these by editing the headers — we don't, so the
submodule stays byte-for-byte pristine.

Two SwiftPM facts shape the solution:

1. To import a C target into Swift, SwiftPM builds a **clang module**. The
   auto-generated *umbrella-directory* module map pulls in *every* header in the
   target's `publicHeadersPath` — including the vestigial `git2/stdint.h`, which
   then collides with the system `<stdint.h>` on Windows.
2. That module build **only searches the target's `publicHeadersPath`** — never
   its `cSettings` header paths. So a `-Dssize_t=…` define or a header-search
   path can't reach it, and the public headers it needs can't be pointed at from
   elsewhere.

So `GitKit` imports **`CGitKit`**, a curated module whose `publicHeadersPath`
contains a custom umbrella header plus **byte copies of libgit2's public
headers** ([`Sources/CGitKit/include`](Sources/CGitKit/include)). The umbrella
includes `git2.h` (so the `git2/stdint.h` polyfill is never in the module) and
applies the `ssize_t` / `_MSC_STDINT_H_` shims *before* it — fixing Windows for
every consumer, not just CI. The copies are re-synced from the pinned submodule
by [`Scripts/update-libgit2.sh`](Scripts/update-libgit2.sh) on each version bump.

libgit2's **`.c` are still compiled from the pristine submodule** (the `Clibgit2`
target, whose `publicHeadersPath` is a header-free dir so SwiftPM builds no
module over libgit2's raw `include/`). Only the public *headers* are vendored, so
the Swift importer has something to read.

## The feature-define dialect (a silent-failure trap)

With no CMake there is no feature *detection*: `LIBGIT2_NO_FEATURES_H` plus an
explicit per-platform `-D` matrix replaces it. The trap is that **the define
names are not stable across libgit2 versions** — and a `-D` the source never
reads doesn't warn, it just leaves the feature compiled out.

libgit2 renamed much of its feature matrix on `main` after the 1.9 series
([libgit2/libgit2#6994](https://github.com/libgit2/libgit2/pull/6994)):

| 1.9.x reads | main (post-#6994) reads |
|---|---|
| `GIT_USE_NSEC` / `GIT_USE_STAT_MTIMESPEC` / `GIT_USE_STAT_MTIM` | `GIT_NSEC` / `GIT_NSEC_MTIMESPEC` / `GIT_NSEC_MTIM` |
| `GIT_USE_FUTIMENS` | `GIT_FUTIMENS` |
| `GIT_USE_ICONV` | `GIT_I18N_ICONV` |
| `GIT_NTLM` | `GIT_AUTH_NTLM` |
| `GIT_SECURE_TRANSPORT` / `GIT_OPENSSL` / `GIT_WINHTTP` | `GIT_HTTPS_SECURETRANSPORT` / `GIT_HTTPS_OPENSSL_DYNAMIC` / `GIT_HTTPS_WINHTTP` |

GitKit's original matrix was inherited from the ibrahimcetin fork — which, it
turned out, builds a libgit2 *main* snapshot rather than the release its branch
name suggests. So the matrix spoke main's post-rename dialect while GitKit
pinned the `v1.9.4` release, and every renamed define silently no-op'd. The
first GitKit `1.9.4` build shipped with **nanosecond timestamps off** — which
broke `git_stash_apply`/`pop`/`branch` (a working-tree change made in the same
second as the index write is invisible to stat-based comparison, so apply
"succeeded" without writing anything) — and, equally silently, with **no TLS
backend selected** (`GIT_HTTPS` was on with nothing behind it), NTLM off, and
iconv off. Nothing failed at compile time; a downstream stash test caught it
([#1](https://github.com/Cocoanetics/GitKit/issues/1), fixed in
[#2](https://github.com/Cocoanetics/GitKit/pull/2), the `1.9.4` tag re-pointed
to the fixed build).

The rules that came out of it:

- The matrix must speak the **pinned release's** dialect — it is
  version-dependent, not copy-paste-portable between libgit2 lines.
- On every submodule bump, **audit every `-D`** against the pinned source:
  each name must actually appear in `vendor/libgit2/{src,include,deps}`
  (`*.c`/`*.h`). Zero hits = silent no-op. (Exceptions: macros consumed by
  *system* headers — `_GNU_SOURCE`, `OPENSSL_API_COMPAT`, `_WIN32_WINNT`.)
- A bump past the rename (a future 1.10/2.x) must translate the matrix
  *forward* again.
- On every submodule bump, **re-audit the shims that wrap a libgit2 file by
  renaming things inside it** — they depend on its internals.
  `config_file_patched.c` assumes `config_file.c` reads each include through
  one `p_stat()` in `config_file_read()` (at `depth > 0`), calls
  `git_config_list_get_unique()` from `config_file_set()` / `config_file_delete()`,
  uses `git_fs_path_set_error()` right after that `p_stat()`, and assigns
  `config_file_get` in `git_config_backend_from_file()`; and that the entries
  of the file being written are those at `include_depth` 0. A rename or a new
  call site silently loses the patch — the `ConfigInclude*Tests` fail then.
  Check the other `*_patched.c` the same way.

## Repository layout

```
GitKit/
├── Package.swift                 # the per-platform build of libgit2
├── Sources/
│   ├── GitKit/                   # the Swift SDK (Repository + operations)
│   │                             #   + re-export of the full C API
│   ├── CGitKit/                  # curated umbrella + vendored libgit2 public headers
│   └── Clibgit2Patches/          # #include shims over pristine libgit2 sources
├── Tests/GitKitTests/            # the SDK test suite (exercises real repos)
└── vendor/libgit2/               # submodule → libgit2/libgit2 @ vX.Y.Z (pristine)
```

`Clibgit2` (libgit2's compiled `.c`), `CGitKit` (the imported module), and
`Clibgit2Patches` are internal; `GitKit` and `CGitKit` are the products.

## Updating to a new libgit2 release

A libgit2 bump ships as a regular GitKit release (minor or major per SemVer,
noted in the release notes and the versioning table above):

```sh
Scripts/update-libgit2.sh vX.Y.Z      # moves the submodule to the tag, re-vendors headers
# audit the -D matrix against the new tag (see "The feature-define dialect"):
#   every define in Package.swift must appear in vendor/libgit2/{src,include,deps}
swift test                            # verify on this host
git commit -am "libgit2 X.Y.Z"
git tag <next GitKit version> && git push --tags
```

The script repoints the pristine submodule and re-vendors the public headers.
The `struct entry` shims are layout-dependent only (revisit if libgit2 moves
files or adds a new same-named-struct collision) — but the **define matrix is
version-dependent**: libgit2 renames feature defines between lines, and a stale
name fails silently (see above). Audit it on every bump.

## License

GitKit's own code (the manifest, the umbrella, the shims, and the Swift wrapper)
is released under the MIT license — see [LICENSE](LICENSE). libgit2's source is
fetched as a submodule from
[libgit2/libgit2](https://github.com/libgit2/libgit2); its public headers are
also vendored under [`Sources/CGitKit/include/git2`](Sources/CGitKit/include) as
byte copies. Both are libgit2's own files, licensed under **GPLv2 with a linking
exception** — see libgit2's `COPYING` for the terms that apply to the library
and its headers.
