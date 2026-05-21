import Foundation

internal struct QueryCacheID: Hashable, Sendable {
    let key: AnyQueryKey
    let valueType: ObjectIdentifier

    init<Value: Sendable>(_ key: QueryKey<Value>) {
        self.key = key.rawValue
        self.valueType = ObjectIdentifier(Value.self)
    }
}

internal final class QueryCacheEntry<Value: Sendable>: @unchecked Sendable {
    let typedKey: QueryKey<Value>
    var result: QueryResult<Value>
    var updatedAt: Date?
    var isInvalidated: Bool

    init(key: QueryKey<Value>) {
        self.typedKey = key
        self.result = QueryResult(status: .idle)
        self.updatedAt = nil
        self.isInvalidated = false
    }
}
