# Source-compatibility gates

GitKit is an ordinary SwiftPM dependency, built without library evolution, so
its clients see its public API as source: a new case in a public enum breaks
a client that switches over it exhaustively. 2.18.0 did exactly that with
`OperationConfiguration.Level.layers`; 2.19 restores 2.17's `Level` (see the
README's Versioning section). Two scripts keep that from passing as a minor
change again. Neither is wired into CI here; both run on a developer's Mac or
a CI job that has the tags (`git fetch --tags`).

## `Scripts/check-source-compat.sh` — the compile probes

Builds each client in `clients/` as an external package that depends on
GitKit, in the Swift 5 and Swift 6 language modes, against every revision in
`expectations.txt` (2.17.0, 2.18.0 and the working tree, `HEAD`), and checks
each outcome and the error a failing build reports. Exit 0: every outcome
matches; 1: one differs; 2: setup error. These builds are the evidence.

| client | 2.17.0 | 2.18.0 | HEAD |
|---|---|---|---|
| `ExhaustiveLevel` — `switch` over `Level`, no `default` | pass | **fail** (switch must be exhaustive) | pass |
| `TolerantLevel` — `switch` with `@unknown default` | pass | pass | pass |
| `LegacyInitializer` — `init(levels:includePolicy:)`, also as a function value | pass | pass | pass |
| `ConstructingOnly` — builds levels, runs an operation | pass | pass | pass |
| `TypedLayers` — `OperationConfiguration.layers`, `init(levels:layers:includePolicy:)` | fail | fail | pass |
| `ExhaustiveConfigLayer` — `switch` over `ConfigLayer`, `addConfigLayers` | fail | pass | pass |
| `LevelLayers218` — constructs and matches 2.18's `Level.layers` | fail | pass | **fail** (migrate to `TypedLayers`) |

`LevelLayers218` is the cost of restoring 2.17's contract, kept visible on
purpose: 2.18 code that names `.layers` must migrate.

```sh
COMPAT_SCRATCH=/path/to/scratch Scripts/check-source-compat.sh          # all revisions
COMPAT_SCRATCH=/path/to/scratch Scripts/check-source-compat.sh HEAD     # the working tree only
```

A revision other than `HEAD` is a copy of the working tree with
`Package.swift`, `Sources` and `Tests` from that tag (the vendored libgit2 is
the same); each revision builds GitKit once for all its clients.

## `Scripts/check-enum-cases.sh` — the enum-case inventory

Lists every public enum case of the `GitKit` module from its symbol graph and
diffs the list against `public-enum-cases.txt`; it fails on any added or
removed case (against 2.18.0 it reports `+OperationConfiguration.Level.layers(_:)`).
An added case is a major change, or the value belongs in a property or a new
type. Refresh the file with `--update` only together with that release
classification, and add a client to `clients/` for the new API. It uses
SwiftPM's native build system, whose `dump-symbol-graph` works for this
package, and covers the default traits (no `Archive`).
