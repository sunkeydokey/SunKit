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
    var requestID: UInt64
    var inFlight: Task<QueryResult<Value>, Never>?
    var lastQuery: Query<Value>?

    init(key: QueryKey<Value>) {
        self.typedKey = key
        self.result = QueryResult(status: .idle)
        self.updatedAt = nil
        self.isInvalidated = false
        self.requestID = 0
        self.inFlight = nil
        self.lastQuery = nil
    }

    func isStale(now: Date, cacheOptions: QueryCacheOptions) -> Bool {
        guard !isInvalidated else {
            return true
        }

        guard let updatedAt else {
            return true
        }

        return now.timeIntervalSince(updatedAt) >= cacheOptions.staleTime
    }
}
