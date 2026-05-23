import Foundation

internal struct QueryCacheID: Hashable, Sendable {
    let key: AnyQueryKey
    let valueType: ObjectIdentifier

    init<Value: Sendable>(_ key: QueryKey<Value>) {
        self.key = key.rawValue
        self.valueType = ObjectIdentifier(Value.self)
    }
}

internal protocol AnyQueryCacheEntry: Sendable {
    var key: AnyQueryKey { get }
    var subscriberCount: Int { get }

    func matches(_ key: AnyQueryKey, exact: Bool) -> Bool
    func markInvalidated() -> [QueryDelivery]
    func makeBackgroundRefetch(_ client: QueryClient) -> Task<Void, Never>?
    func cancelStaleTimer()
}

internal final class QueryCacheEntry<Value: Sendable>: AnyQueryCacheEntry, @unchecked Sendable {
    struct Subscriber: Sendable {
        let queue: DispatchQueue?
        let listener: @Sendable (QueryResult<Value>) -> Void
    }

    let typedKey: QueryKey<Value>
    var key: AnyQueryKey { typedKey.rawValue }
    var result: QueryResult<Value>
    var updatedAt: Date?
    var isInvalidated: Bool
    var requestID: UInt64
    var inFlight: Task<QueryResult<Value>, Never>?
    var staleTimer: Task<Void, Never>?
    var lastQuery: Query<Value>?
    var subscribers: [UUID: Subscriber]

    var subscriberCount: Int {
        subscribers.count
    }

    init(key: QueryKey<Value>) {
        self.typedKey = key
        self.result = QueryResult(status: .idle)
        self.updatedAt = nil
        self.isInvalidated = false
        self.requestID = 0
        self.inFlight = nil
        self.staleTimer = nil
        self.lastQuery = nil
        self.subscribers = [:]
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

    func matches(_ key: AnyQueryKey, exact: Bool) -> Bool {
        exact ? self.key == key : self.key.starts(with: key)
    }

    func markInvalidated() -> [QueryDelivery] {
        staleTimer?.cancel()
        staleTimer = nil
        isInvalidated = true
        result = QueryResult(
            status: result.status,
            isFetching: result.isFetching,
            isStale: true,
            isPlaceholderData: result.isPlaceholderData,
            updatedAt: result.updatedAt
        )
        return deliveries(for: result)
    }

    func markStale() -> [QueryDelivery] {
        result = QueryResult(
            status: result.status,
            isFetching: result.isFetching,
            isStale: true,
            isPlaceholderData: result.isPlaceholderData,
            updatedAt: result.updatedAt
        )
        return deliveries(for: result)
    }

    func makeBackgroundRefetch(_ client: QueryClient) -> Task<Void, Never>? {
        guard subscriberCount > 0, let lastQuery else {
            return nil
        }

        return Task {
            _ = await client.fetchQuery(lastQuery)
        }
    }

    func cancelStaleTimer() {
        staleTimer?.cancel()
        staleTimer = nil
    }

    func deliveries(for result: QueryResult<Value>) -> [QueryDelivery] {
        subscribers.values.map { subscriber in
            delivery(for: subscriber, result: result)
        }
    }

    func delivery(for subscriber: Subscriber, result: QueryResult<Value>) -> QueryDelivery {
        QueryDelivery {
            if let queue = subscriber.queue {
                queue.async {
                    subscriber.listener(result)
                }
            } else {
                Task {
                    subscriber.listener(result)
                }
            }
        }
    }
}

internal struct QueryDelivery: Sendable {
    let deliver: @Sendable () -> Void
}
