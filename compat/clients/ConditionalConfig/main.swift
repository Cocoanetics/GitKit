import Foundation
import GitKit

let legacy: ([OperationConfiguration.Level], ConfigIncludePolicy?) -> OperationConfiguration =
    OperationConfiguration.init(levels:includePolicy:)
let typed: ([OperationConfiguration.Level], [ConfigLayer]?, ConfigIncludePolicy?) -> OperationConfiguration =
    OperationConfiguration.init(levels:layers:includePolicy:)
let command = CommandLineConfig([
    .entries([ConfigEntry(name: "remote.origin.url", value: "https://example.com/repo")]),
    .includeIf(condition: "hasconfig:remote.*.url:https://example.com/**", path: "/missing"),
    .include(path: "/missing")
])
let configuration = OperationConfiguration(commandLine: command, onDiagnostic: { _ in })
try Repository.withOperationConfiguration(configuration) {}
_ = legacy([], nil)
_ = typed([], [], nil)
var config: OpaquePointer?
guard git_config_new(&config) == 0, let config else { fatalError("no config") }
defer { git_config_free(config) }
try CommandLineConfig([]).install(into: config)
