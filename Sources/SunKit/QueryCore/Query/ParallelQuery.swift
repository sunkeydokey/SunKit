/// A type-erased query for parallel batch execution.
///
/// `AnyParallelQuery` accepts any `Query<Value>` while preserving its typed
/// cache identity internally. Use it with ``QueryClient/fetchQueries(_:)`` to
/// fetch heterogeneous queries concurrently.
public struct AnyParallelQuery: Sendable {
    internal let id: QueryCacheID
    internal let execute: @Sendable (QueryClient) async -> ParallelQueryExecutionResult

    /// Creates a type-erased parallel query from a typed query.
    ///
    /// Only regular ``Query`` values are accepted in v0.1. ``InfiniteQuery``
    /// batching is intentionally not part of this API.
    public init<Value: Sendable>(_ query: Query<Value>) {
        let id = QueryCacheID(query.key)
        self.id = id
        self.execute = { client in
            let result = await client.fetchQuery(query)
            return ParallelQueryExecutionResult(
                id: id,
                result: ParallelQueryResultBox(result)
            )
        }
    }
}

/// Results returned by parallel query batch execution.
///
/// Look up values with the original typed `QueryKey<Value>`. Missing keys
/// return `nil`; no user-visible casting is required. A failed query that ran
/// is still present as a `QueryResult` with `isError == true`.
public struct ParallelQueryResults: Sendable {
    private let storage: [QueryCacheID: any AnyParallelQueryResultBox]

    internal init(storage: [QueryCacheID: any AnyParallelQueryResultBox]) {
        self.storage = storage
    }

    /// Returns the typed result for a query key when it was part of the batch.
    ///
    /// A `nil` value means the batch result has no stored result for this typed
    /// key. It does not mean that a query failed; failures are returned as
    /// `QueryResult` values.
    public subscript<Value: Sendable>(key: QueryKey<Value>) -> QueryResult<Value>? {
        storage[QueryCacheID(key)]?.queryResult()
    }
}

internal struct ParallelQueryExecutionResult: Sendable {
    let id: QueryCacheID
    let result: any AnyParallelQueryResultBox
}

internal protocol AnyParallelQueryResultBox: Sendable {
    func queryResult<Value: Sendable>() -> QueryResult<Value>?
}

private struct ParallelQueryResultBox<Value: Sendable>: AnyParallelQueryResultBox {
    let result: QueryResult<Value>

    init(_ result: QueryResult<Value>) {
        self.result = result
    }

    func queryResult<RequestedValue: Sendable>() -> QueryResult<RequestedValue>? {
        result as? QueryResult<RequestedValue>
    }
}
