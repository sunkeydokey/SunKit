import Foundation

/// Actor-isolated runtime for query cache state.
///
/// `QueryClient` is not `@MainActor`. Separate client instances have isolated
/// cache scopes.
public actor QueryClient {
    /// The default execution options used when a `Query` omits options.
    public nonisolated let defaultQueryOptions: QueryOptions

    /// The default cache lifecycle options used by this client.
    public nonisolated let defaultCacheOptions: QueryCacheOptions

    private var cache: [QueryCacheID: Any]

    /// Creates a query client with isolated cache state.
    ///
    /// - Parameters:
    ///   - defaultQueryOptions: Execution options used when `Query.options` is `nil`.
    ///   - defaultCacheOptions: Cache lifecycle options used by stored entries.
    public init(
        defaultQueryOptions: QueryOptions = .default,
        defaultCacheOptions: QueryCacheOptions = .default
    ) {
        self.defaultQueryOptions = defaultQueryOptions
        self.defaultCacheOptions = defaultCacheOptions
        self.cache = [:]
    }

    /// Returns cached data for a typed key, if present.
    public func getQueryData<Value: Sendable>(_ key: QueryKey<Value>) async -> Value? {
        existingEntry(for: key)?.result.data
    }

    /// Stores data for a typed key.
    public func setQueryData<Value: Sendable>(_ key: QueryKey<Value>, _ value: Value) async {
        let entry = entry(for: key)
        let now = Date()
        entry.updatedAt = now
        entry.isInvalidated = false
        entry.result = QueryResult(
            status: .success(value),
            isStale: false,
            updatedAt: now
        )
    }

    /// Removes all cached queries.
    public func clear() async {
        cache.removeAll()
    }

    private func entry<Value: Sendable>(for key: QueryKey<Value>) -> QueryCacheEntry<Value> {
        if let entry = existingEntry(for: key) {
            return entry
        }

        let entry = QueryCacheEntry(key: key)
        cache[QueryCacheID(key)] = entry
        return entry
    }

    private func existingEntry<Value: Sendable>(for key: QueryKey<Value>) -> QueryCacheEntry<Value>? {
        cache[QueryCacheID(key)] as? QueryCacheEntry<Value>
    }
}
