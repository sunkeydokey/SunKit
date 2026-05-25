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

    private var cache: [QueryCacheID: any AnyQueryCacheEntry]
    private var nextRequestID: UInt64 = 0

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
        entry.requestID = issueRequestID()
        let requestID = entry.requestID
        entry.lastQuery = query

        let pending = QueryResult(
            status: .pending(previous: previousData),
            isFetching: true,
            isStale: entry.isStale(now: now, cacheOptions: defaultCacheOptions),
            updatedAt: previousUpdatedAt
        )
        entry.result = pending

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

        deliver(entry.deliveries(for: pending))

        let result = await task.value
        let deliveries = finishFetch(result, for: query.key, requestID: requestID)
        deliver(deliveries)
        return result
    }

    /// Fetches heterogeneous queries concurrently and returns typed lookup results.
    ///
    /// Each unique query executes through ``fetchQuery(_:)``, so normal cache
    /// writes, retries, stale state, `lastQuery`, invalidation refetch behavior,
    /// and in-flight deduplication remain unchanged. Duplicate typed keys in
    /// the same batch are deterministic: the first query wins and later
    /// duplicates are skipped before execution.
    ///
    /// The returned batch can contain both successes and failures. A failed
    /// query is represented by its own `QueryResult.failure`; this method does
    /// not throw. This is Swift concurrency convenience, not HTTP batching.
    @discardableResult
    public func fetchQueries(_ queries: [AnyParallelQuery]) async -> ParallelQueryResults {
        var seen = Set<QueryCacheID>()
        var uniqueQueries: [AnyParallelQuery] = []

        for query in queries where seen.insert(query.id).inserted {
            uniqueQueries.append(query)
        }

        guard !uniqueQueries.isEmpty else {
            return ParallelQueryResults(storage: [:])
        }

        var storage: [QueryCacheID: any AnyParallelQueryResultBox] = [:]
        await withTaskGroup(of: ParallelQueryExecutionResult.self) { group in
            for query in uniqueQueries {
                group.addTask {
                    await query.execute(self)
                }
            }

            for await result in group {
                storage[result.id] = result.result
            }
        }

        return ParallelQueryResults(storage: storage)
    }

    /// Fetches the first page of an infinite query and stores accumulated data.
    ///
    /// The MVP infinite-query model refetches from `initialPageParam` and
    /// replaces the accumulated pages with that single first page. It does not
    /// refetch every previously loaded page.
    @discardableResult
    public func fetchInfiniteQuery<PageParam: Sendable, Page: Sendable>(
        _ query: InfiniteQuery<PageParam, Page>
    ) async -> QueryResult<InfiniteData<PageParam, Page>> {
        await fetchQuery(Query(key: query.key, options: query.options) {
            let page = try await query.fetchPage(query.initialPageParam)
            return InfiniteData(
                pages: [page],
                pageParams: [query.initialPageParam]
            )
        })
    }

    /// Fetches and appends the next page for an infinite query when available.
    ///
    /// If the query has no cached pages yet, this method loads the initial page.
    /// If `getNextPageParam` returns `nil`, no fetch is started and the current
    /// cached result is returned. Concurrent calls for the same typed key join
    /// the existing in-flight task through the normal query dedupe path.
    @discardableResult
    public func fetchNextPage<PageParam: Sendable, Page: Sendable>(
        _ query: InfiniteQuery<PageParam, Page>
    ) async -> QueryResult<InfiniteData<PageParam, Page>> {
        let entry = entry(for: query.key)

        if let inFlight = entry.inFlight {
            return await inFlight.value
        }

        guard let current = entry.result.data,
              let lastPage = current.pages.last else {
            return await fetchInfiniteQuery(query)
        }

        guard let nextPageParam = query.getNextPageParam(lastPage, current.pages) else {
            return entry.result
        }

        return await fetchQuery(Query(key: query.key, options: query.options) {
            let nextPage = try await query.fetchPage(nextPageParam)
            return InfiniteData(
                pages: current.pages + [nextPage],
                pageParams: current.pageParams + [nextPageParam]
            )
        })
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
        if let data = result.data {
            return data
        }

        throw result.error ?? QueryClientError.missingData
    }

    /// Returns whether the typed query key is currently stale.
    ///
    /// Missing cache entries are treated as stale. UI adapters can use this to
    /// decide whether `.ifStale` observer triggers should start a fetch without
    /// relying on stale-only result publications.
    public func isQueryStale<Value: Sendable>(_ key: QueryKey<Value>) async -> Bool {
        guard let entry = existingEntry(for: key) else {
            return true
        }

        return entry.isStale(now: Date(), cacheOptions: defaultCacheOptions)
    }

    /// Subscribes to result changes for a typed query key.
    ///
    /// Subscribing only registers a listener and optionally delivers the current
    /// value. It never starts a fetch by itself.
    public func subscribe<Value: Sendable>(
        to key: QueryKey<Value>,
        receiveCurrentValue: Bool = true,
        deliverOn queue: DispatchQueue? = nil,
        _ listener: @escaping @Sendable (QueryResult<Value>) -> Void
    ) async -> QuerySubscription {
        let entry = entry(for: key)
        entry.cancelGCTimer()
        let id = UUID()
        let subscriber = QueryCacheEntry.Subscriber(queue: queue, listener: listener)
        entry.subscribers[id] = subscriber

        if receiveCurrentValue {
            deliver([entry.delivery(for: subscriber, result: entry.result)])
        }

        return QuerySubscription {
            await self.cancelSubscription(id, key: key)
        }
    }

    /// Invalidates one typed query key exactly.
    ///
    /// If the matching query is active and has a known previous fetcher, the
    /// client starts a background refetch. Otherwise the entry is only marked
    /// stale.
    public func invalidate<Value: Sendable>(key: QueryKey<Value>) async {
        await invalidate(id: QueryCacheID(key), key: key.rawValue, exact: true)
    }

    /// Invalidates queries by exact or prefix key matching.
    ///
    /// Prefix invalidation is type-erased and may match multiple value types
    /// that share the same raw key parts.
    public func invalidateQueries(_ key: AnyQueryKey, exact: Bool = false) async {
        await invalidate(id: nil, key: key, exact: exact)
    }

    /// Removes queries by exact or prefix key matching.
    public func removeQueries(_ key: AnyQueryKey, exact: Bool = false) async {
        let ids = cache
            .filter { _, entry in entry.matches(key, exact: exact) }
            .map(\.key)

        for id in ids {
            cache[id]?.cancelInFlight()
            cache[id]?.cancelStaleTimer()
            cache[id]?.cancelGCTimer()
            cache[id] = nil
        }
    }

    /// Returns cached data for a typed key, if present.
    public func getQueryData<Value: Sendable>(_ key: QueryKey<Value>) async -> Value? {
        existingEntry(for: key)?.result.data
    }

    /// Stores data for a typed key.
    public func setQueryData<Value: Sendable>(_ key: QueryKey<Value>, _ value: Value) async {
        let entry = entry(for: key)
        let now = Date()
        entry.requestID = issueRequestID()
        entry.inFlight = nil
        entry.staleTimer?.cancel()
        entry.staleTimer = nil
        entry.updatedAt = now
        entry.isInvalidated = false
        entry.result = QueryResult(
            status: .success(value),
            isStale: Self.isImmediatelyStale(cacheOptions: defaultCacheOptions),
            updatedAt: now
        )
        scheduleStaleTimer(for: entry, updatedAt: now)
        if entry.subscriberCount == 0 {
            scheduleGCTimer(for: entry)
        }
        deliver(entry.deliveries(for: entry.result))
    }

    /// Updates cached data for a typed key when data is already present.
    ///
    /// The updater receives and returns non-optional values. If the key has no
    /// cached data, this method does nothing and does not call `update`.
    /// Invalidation remains explicit through `invalidate(key:)` and
    /// `invalidateQueries(_:exact:)`.
    public func updateQueryData<Value: Sendable>(
        _ key: QueryKey<Value>,
        _ update: @Sendable (Value) -> Value
    ) async {
        guard let entry = existingEntry(for: key), let currentData = entry.result.data else {
            return
        }

        let now = Date()
        let updatedData = update(currentData)
        entry.requestID = issueRequestID()
        entry.inFlight = nil
        entry.staleTimer?.cancel()
        entry.staleTimer = nil
        entry.updatedAt = now
        entry.isInvalidated = false
        entry.result = QueryResult(
            status: .success(updatedData),
            isStale: Self.isImmediatelyStale(cacheOptions: defaultCacheOptions),
            updatedAt: now
        )
        scheduleStaleTimer(for: entry, updatedAt: now)
        if entry.subscriberCount == 0 {
            scheduleGCTimer(for: entry)
        }
        deliver(entry.deliveries(for: entry.result))
    }

    /// Executes a mutation and runs its lifecycle callbacks.
    ///
    /// Mutations do not invalidate queries automatically. Use callbacks such as
    /// `MutationOptions.onSuccess` or call cache APIs after this method returns
    /// to update or invalidate related query data explicitly.
    ///
    /// - Parameters:
    ///   - mutation: The mutation declaration to execute.
    ///   - input: The input passed to the mutation operation.
    /// - Returns: The mutation output.
    public func mutate<Input: Sendable, Output: Sendable>(
        _ mutation: Mutation<Input, Output>,
        input: Input
    ) async throws -> Output {
        do {
            let output = try await Self.run(mutation: mutation, input: input)
            await mutation.options.onSuccess?(output, input, self)
            await mutation.options.onSettled?(.success(output), input, self)
            return output
        } catch {
            await mutation.options.onFailure?(error, input, self)
            await mutation.options.onSettled?(.failure(error), input, self)
            throw error
        }
    }

    /// Executes a mutation and delivers its completion result.
    ///
    /// Mutations do not invalidate queries automatically. The completion is
    /// delivered on `queue` when one is provided; otherwise it is delivered from
    /// an unstructured task.
    ///
    /// - Parameters:
    ///   - mutation: The mutation declaration to execute.
    ///   - input: The input passed to the mutation operation.
    ///   - queue: The dispatch queue used for completion delivery.
    ///   - completion: A closure that receives the mutation result.
    public nonisolated func mutate<Input: Sendable, Output: Sendable>(
        _ mutation: Mutation<Input, Output>,
        input: Input,
        deliverOn queue: DispatchQueue? = nil,
        _ completion: @escaping @Sendable (Result<Output, Error>) -> Void
    ) {
        Task {
            let result: Result<Output, Error>
            do {
                result = .success(try await self.mutate(mutation, input: input))
            } catch {
                result = .failure(error)
            }

            if let queue {
                queue.async {
                    completion(result)
                }
            } else {
                completion(result)
            }
        }
    }

    /// Removes all cached queries and requests cancellation of in-flight fetches.
    ///
    /// Cancellation is cooperative. A fetcher may still finish if it does not
    /// observe task cancellation, but cleared results are not stored or
    /// published.
    public func clear() async {
        for entry in cache.values {
            entry.cancelInFlight()
            entry.cancelStaleTimer()
            entry.cancelGCTimer()
        }
        cache.removeAll()
    }

    private func invalidate(
        id: QueryCacheID?,
        key: AnyQueryKey,
        exact: Bool
    ) async {
        let matchingEntries: [any AnyQueryCacheEntry]
        if let id, let entry = cache[id] {
            matchingEntries = [entry]
        } else {
            matchingEntries = cache
                .filter { _, entry in entry.matches(key, exact: exact) }
                .map(\.value)
        }

        var deliveries: [QueryDelivery] = []
        var refetches: [Task<Void, Never>] = []

        for entry in matchingEntries {
            deliveries.append(contentsOf: entry.markInvalidated())
            if let refetch = entry.makeBackgroundRefetch(self) {
                refetches.append(refetch)
            }
        }

        deliver(deliveries)
        _ = refetches
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
    ) -> [QueryDelivery] {
        guard let entry = existingEntry(for: key), entry.requestID == requestID else {
            return []
        }

        entry.inFlight = nil
        entry.staleTimer?.cancel()
        entry.staleTimer = nil
        entry.result = result
        entry.updatedAt = result.updatedAt
        if result.isSuccess {
            entry.isInvalidated = false
        }
        if result.isSuccess, let updatedAt = result.updatedAt {
            scheduleStaleTimer(for: entry, updatedAt: updatedAt)
        }
        if entry.subscriberCount == 0 {
            scheduleGCTimer(for: entry)
        }

        return entry.deliveries(for: result)
    }

    private func markStaleIfCurrent<Value: Sendable>(
        key: QueryKey<Value>,
        updatedAt: Date
    ) {
        guard let entry = existingEntry(for: key), entry.updatedAt == updatedAt else {
            return
        }

        entry.staleTimer = nil

        guard !entry.result.isStale else {
            return
        }

        deliver(entry.markStale())
    }

    private func scheduleGCTimer<Value: Sendable>(for entry: QueryCacheEntry<Value>) {
        entry.cancelGCTimer()
        let gcTime = defaultCacheOptions.gcTime
        guard gcTime > 0 else {
            removeEntry(key: entry.typedKey)
            return
        }
        let key = entry.typedKey
        entry.gcTimer = Task { [weak self] in
            let nanoseconds = UInt64(gcTime * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else { return }
            await self?.removeEntry(key: key)
        }
    }

    private func removeEntry<Value: Sendable>(key: QueryKey<Value>) {
        let id = QueryCacheID(key)
        guard let entry = cache[id], entry.subscriberCount == 0 else { return }
        entry.cancelInFlight()
        entry.cancelStaleTimer()
        entry.cancelGCTimer()
        cache[id] = nil
    }

    private func scheduleStaleTimer<Value: Sendable>(
        for entry: QueryCacheEntry<Value>,
        updatedAt: Date
    ) {
        let staleTime = defaultCacheOptions.staleTime
        guard staleTime > 0, !entry.result.isStale else {
            return
        }

        let key = entry.typedKey
        entry.staleTimer = Task { [weak self] in
            let nanoseconds = UInt64(staleTime * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else {
                return
            }

            await self?.markStaleIfCurrent(key: key, updatedAt: updatedAt)
        }
    }

    private func issueRequestID() -> UInt64 {
        nextRequestID += 1
        return nextRequestID
    }

    private func cancelSubscription<Value: Sendable>(_ id: UUID, key: QueryKey<Value>) {
        guard let entry = existingEntry(for: key) else {
            return
        }

        entry.subscribers[id] = nil
        if entry.subscriberCount == 0 {
            scheduleGCTimer(for: entry)
        }
    }

    private nonisolated func deliver<S: Sequence>(_ deliveries: S) where S.Element == QueryDelivery {
        for delivery in deliveries {
            delivery.deliver()
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
                isStale: isImmediatelyStale(cacheOptions: cacheOptions),
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

    private nonisolated static func run<Input: Sendable, Output: Sendable>(
        mutation: Mutation<Input, Output>,
        input: Input
    ) async throws -> Output {
        let maximumRetries: Int
        switch mutation.options.retry {
        case .never:
            maximumRetries = 0
        case let .count(count):
            maximumRetries = max(0, count)
        }

        var attempt = 0
        while true {
            do {
                return try await mutation.run(input)
            } catch {
                guard attempt < maximumRetries else {
                    throw error
                }

                attempt += 1
                await sleep(for: mutation.options.retryDelay, attempt: attempt)
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

    private nonisolated static func isImmediatelyStale(cacheOptions: QueryCacheOptions) -> Bool {
        cacheOptions.staleTime == 0
    }
}

private enum QueryClientError: Error {
    case missingData
}

/// A handle for cancelling a Core query subscription.
///
/// Cancellation removes this subscriber from the query key's listener list.
/// It does **not** abort any in-flight fetch — fetches are shared across all
/// subscribers for the same key and outlive individual subscriptions.
///
/// `cancel()` is `async` because removing the subscriber requires hopping to
/// the `QueryClient` actor.
///
/// ## Completion-based fetchers
/// The cooperative cancellation policy for completion-based `Query` and
/// `Mutation` fetchers is not part of the v0.1 API surface and is deferred
/// to a future release.
public struct QuerySubscription: Sendable {
    private let cancelHandler: @Sendable () async -> Void

    internal init(cancel: @escaping @Sendable () async -> Void) {
        self.cancelHandler = cancel
    }

    /// Cancels the subscription so it no longer receives query publications.
    public func cancel() async {
        await cancelHandler()
    }
}
