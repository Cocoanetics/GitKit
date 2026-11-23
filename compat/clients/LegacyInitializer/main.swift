// A 2.17 client of init(levels:includePolicy:): direct calls, the
// initializer as a function value with and without a type annotation, and
// the stored properties.
import Foundation
import GitKit

let make: ([OperationConfiguration.Level], ConfigIncludePolicy?) -> OperationConfiguration =
    OperationConfiguration.init(levels:includePolicy:)
let unannotated = OperationConfiguration.init(levels:includePolicy:)

var configuration = OperationConfiguration(levels: [.entries([])])
configuration.levels.append(.file(URL(fileURLWithPath: "/tmp/system.cfg"), .system))
configuration.includePolicy = ConfigIncludePolicy { _ in false }
let made = make([.entries([], .global, name: "isolated")], nil)
let other = unannotated([], configuration.includePolicy)

print(configuration.levels.count, made.levels.count, other.levels.count)
