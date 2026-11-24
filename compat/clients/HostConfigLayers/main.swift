// A host that owns its libgit2 config (git_config_new here; also a
// git_repository_open_ext repository's config or git_config_open_default)
// and installs command-line layers into it with ConfigLayer.install.
import Foundation
import GitKit

func run() throws {
    let install: ([ConfigLayer], OpaquePointer, OpaquePointer?) throws -> Void =
        ConfigLayer.install(_:into:repository:)
    var config: OpaquePointer?
    guard git_config_new(&config) == 0, let config else { return }
    defer { git_config_free(config) }
    let layers: [ConfigLayer] = [.entries([ConfigEntry(name: "user.email", value: "a@b")])]
    try ConfigLayer.install(layers, into: config, repository: nil)
    try install([], config, nil)
}

try run()
