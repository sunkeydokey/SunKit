/// A typed fetch declaration for a query.
///
/// `Query` describes how to fetch data for a `QueryKey`. It does not execute
/// work by itself and is not tied to a specific `QueryClient`. When `options`
/// is `nil`, the executing client supplies its `defaultQueryOptions`.
public struct Query<Value: Sendable>: Sendable {
    /// The cache identity for this query.
    public let key: QueryKey<Value>

    /// Query execution options, or `nil` to use the executing client's defaults.
    public let options: QueryOptions?

    internal let fetch: @Sendable () async throws -> Value

    /// Creates a query from an async throwing fetcher.
    ///
    /// - Parameters:
    ///   - key: The typed cache identity for this query.
    ///   - options: Execution options for this query, or `nil` to use the
    ///     executing client's defaults.
    ///   - fetch: The async operation that loads the query value.
    public init(
        key: QueryKey<Value>,
        options: QueryOptions? = nil,
        fetch: @escaping @Sendable () async throws -> Value
    ) {
        self.key = key
        self.options = options
        self.fetch = fetch
    }

    /// Creates a query from a completion-based fetcher.
    ///
    /// The completion must be called exactly once. Cancellation of the
    /// underlying completion operation is intentionally not defined by Core.
    ///
    /// - Parameters:
    ///   - key: The typed cache identity for this query.
    ///   - options: Execution options for this query, or `nil` to use the
    ///     executing client's defaults.
    ///   - fetch: A completion-based operation that loads the query value.
    public init(
        key: QueryKey<Value>,
        options: QueryOptions? = nil,
        fetch: @escaping @Sendable (@escaping @Sendable (Result<Value, Error>) -> Void) -> Void
    ) {
        self.key = key
        self.options = options
        self.fetch = {
            try await withCheckedThrowingContinuation { continuation in
                fetch { result in
                    continuation.resume(with: result)
                }
            }
        }
    }
}
