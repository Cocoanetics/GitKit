// A client that only constructs levels and runs an operation with them,
// never matching on them.
import Foundation
import GitKit

let levels: [OperationConfiguration.Level] = [
    .entries([], .system, name: "isolated"),
    .entries([ConfigEntry(name: "core.autocrlf", value: "true")]),
    .file(URL(fileURLWithPath: "/tmp/global.cfg"), .global),
]
let configuration = OperationConfiguration(levels: levels, includePolicy: nil)

func run() throws -> Int {
    try Repository.withOperationConfiguration(configuration) { 1 }
}

print(configuration.levels.count, (try? run()) ?? 0)
