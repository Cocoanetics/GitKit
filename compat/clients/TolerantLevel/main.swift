// A client that switches over OperationConfiguration.Level with an
// `@unknown default`, tolerating cases a later release adds.
import Foundation
import GitKit

func describe(_ level: OperationConfiguration.Level) -> String {
    switch level {
    case .file:
        return "file"
    case .entries:
        return "entries"
    @unknown default:
        return "other"
    }
}

print(describe(.entries([])))
