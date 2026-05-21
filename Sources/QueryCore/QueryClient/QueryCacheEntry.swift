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
    struct Subscriber: Sendable {
        let queue: DispatchQueue?
        let listener: @Sendable (QueryResult<Value>) -> Void
    }

    let typedKey: QueryKey<Value>
    var result: QueryResult<Value>
    var updatedAt: Date?
    var isInvalidated: Bool
    var requestID: UInt64
    var inFlight: Task<QueryResult<Value>, Never>?
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
