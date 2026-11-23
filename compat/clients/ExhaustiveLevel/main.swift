// A 2.17 client: an exhaustive switch over OperationConfiguration.Level,
// with no default — what 2.18.0's `.layers` case broke.
import Foundation
import GitKit

func describe(_ level: OperationConfiguration.Level) -> String {
    switch level {
    case let .file(url, level):
        return "file \(url.path) at \(level)"
    case let .entries(entries, level, name):
        return "\(entries.count) \(name) entries at \(level)"
    }
}

print(describe(.entries([ConfigEntry(name: "user.name", value: "A")])))
print(describe(.file(URL(fileURLWithPath: "/tmp/global.cfg"), .global)))
