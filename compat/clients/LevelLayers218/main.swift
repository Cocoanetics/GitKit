// A client of 2.18.0's three-case Level: it constructs and matches
// `.layers`. 2.19 moves the layers to OperationConfiguration.layers, so this
// client must migrate (see TypedLayers); it is kept to show that consequence.
import Foundation
import GitKit

let level = OperationConfiguration.Level.layers([.entries([])])
let configuration = OperationConfiguration(levels: [level])

func describe(_ level: OperationConfiguration.Level) -> String {
    switch level {
    case .file:
        return "file"
    case .entries:
        return "entries"
    case let .layers(layers):
        return "\(layers.count) layers"
    }
}

print(configuration.levels.map(describe))
