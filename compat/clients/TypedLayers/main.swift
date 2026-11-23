// A client migrated to the typed command-line layers: the
// OperationConfiguration.layers property and init(levels:layers:includePolicy:).
import Foundation
import GitKit

let include = URL(fileURLWithPath: "/tmp/inc.cfg")
let layers: [ConfigLayer] = [
    .entries([ConfigEntry(name: "include.path", value: include.path)]),
    .file(include),
    .entries([ConfigEntry(name: "user.email", value: "a@b")], name: "command line"),
]

let full = OperationConfiguration(
    levels: [.entries([], .global, name: "isolated")], layers: layers, includePolicy: nil)
let onlyLayers = OperationConfiguration(layers: layers)
var cleared = OperationConfiguration(levels: [])
cleared.layers = []
let inherited: [ConfigLayer]? = OperationConfiguration(levels: []).layers

func run() throws {
    try Repository.withOperationConfiguration(onlyLayers) {}
}

print(full.layers?.count ?? -1, cleared.layers?.count ?? -1, inherited == nil)
