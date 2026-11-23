// A 2.18 client of ConfigLayer: an exhaustive switch over its two cases, and
// the live Repository.addConfigLayers(_:).
import Foundation
import GitKit

func describe(_ layer: ConfigLayer) -> String {
    switch layer {
    case let .entries(entries, name):
        return "\(entries.count) \(name) entries"
    case let .file(url):
        return "file \(url.path)"
    }
}

let add: (Repository) -> ([ConfigLayer]) throws -> Void = Repository.addConfigLayers
print(describe(.file(URL(fileURLWithPath: "/tmp/inc.cfg"))), describe(.entries([])))
_ = add
