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

    /// Fetches a query, using in-flight deduplication for matching typed keys.
    ///
    /// If the same key and value type is already fetching, this method joins
    /// the existing task and does not run the later fetcher.
    @discardableResult
    public func fetchQuery<Value: Sendable>(_ query: Query<Value>) async -> QueryResult<Value> {
        let now = Date()
        let entry = entry(for: query.key)

        if let inFlight = entry.inFlight {
            return await inFlight.value
        }

        let options = query.options ?? defaultQueryOptions
        let previousData = entry.result.data
        let previousFailureCount = entry.result.failureCount
        let previousUpdatedAt = entry.updatedAt
        entry.requestID += 1
        let requestID = entry.requestID
        entry.lastQuery = query

        entry.result = QueryResult(
            status: .pending(previous: previousData),
            isFetching: true,
            isStale: entry.isStale(now: now, cacheOptions: defaultCacheOptions),
            updatedAt: previousUpdatedAt
        )

        let task = Task<QueryResult<Value>, Never> {
            await Self.execute(
                query: query,
                options: options,
                stale: previousData,
                previousUpdatedAt: previousUpdatedAt,
                previousFailureCount: previousFailureCount,
                cacheOptions: defaultCacheOptions
            )
        }
        entry.inFlight = task

        let result = await task.value
        finishFetch(result, for: query.key, requestID: requestID)
        return result
    }

    /// Returns cached fresh data for a query or fetches it when the cache is stale.
    ///
    /// This method throws when fetching fails and no successful value is available.
    public func ensureQueryData<Value: Sendable>(_ query: Query<Value>) async throws -> Value {
        let entry = existingEntry(for: query.key)
        if let entry, !entry.isStale(now: Date(), cacheOptions: defaultCacheOptions), let data = entry.result.data {
            return data
        }

        let result = await fetchQuery(query)
        if let data = result.data, result.isSuccess {
            return data
        }

        throw result.error ?? QueryClientError.missingData
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
            isStale: entry.isStale(now: now, cacheOptions: defaultCacheOptions),
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

    private func finishFetch<Value: Sendable>(
        _ result: QueryResult<Value>,
        for key: QueryKey<Value>,
        requestID: UInt64
    ) {
        guard let entry = existingEntry(for: key), entry.requestID == requestID else {
            return
        }

        entry.inFlight = nil
        entry.result = result
        entry.updatedAt = result.updatedAt
        entry.isInvalidated = result.isError
        if result.isSuccess {
            entry.isInvalidated = false
        }
    }

    private nonisolated static func execute<Value: Sendable>(
        query: Query<Value>,
        options: QueryOptions,
        stale: Value?,
        previousUpdatedAt: Date?,
        previousFailureCount: Int,
        cacheOptions: QueryCacheOptions
    ) async -> QueryResult<Value> {
        do {
            let value = try await run(query: query, options: options)
            let updatedAt = Date()
            return QueryResult(
                status: .success(value),
                isStale: Date().timeIntervalSince(updatedAt) >= cacheOptions.staleTime,
                updatedAt: updatedAt
            )
        } catch {
            return QueryResult(
                status: .failure(
                    error,
                    stale: stale,
                    failureCount: previousFailureCount + 1
                ),
                isStale: stale != nil,
                updatedAt: previousUpdatedAt
            )
        }
    }

    private nonisolated static func run<Value: Sendable>(
        query: Query<Value>,
        options: QueryOptions
    ) async throws -> Value {
        let maximumRetries: Int
        switch options.retry {
        case .never:
            maximumRetries = 0
        case let .count(count):
            maximumRetries = max(0, count)
        }

        var attempt = 0
        while true {
            do {
                return try await query.fetch()
            } catch {
                guard attempt < maximumRetries else {
                    throw error
                }

                attempt += 1
                await sleep(for: options.retryDelay, attempt: attempt)
            }
        }
    }

    private nonisolated static func sleep(for retryDelay: RetryDelay, attempt: Int) async {
        let seconds: TimeInterval
        switch retryDelay {
        case .none:
            return
        case let .fixed(delay):
            seconds = delay
        case let .exponential(maxDelay):
            seconds = min(pow(2, Double(attempt - 1)), maxDelay)
        }

        guard seconds > 0 else {
            return
        }

        let nanoseconds = UInt64(seconds * 1_000_000_000)
        try? await Task.sleep(nanoseconds: nanoseconds)
    }
}

private enum QueryClientError: Error {
    case missingData
}
