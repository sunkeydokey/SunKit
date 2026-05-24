import Observation
import SunKit

/// Observable SwiftUI state for a next-page-only infinite query.
///
/// Store `InfiniteQueryState` in SwiftUI with `@State`, then call
/// ``start(using:)`` from the view lifecycle. The state subscribes to the
/// accumulated infinite-query cache value and exposes page arrays for rendering
/// infinite-scroll or "load more" interfaces.
@MainActor
@Observable
public final class InfiniteQueryState<PageParam: Sendable, Page: Sendable> {
    /// The latest accumulated query result delivered by Core, if any.
    public private(set) var result: QueryResult<InfiniteData<PageParam, Page>>?

    /// A Boolean value indicating whether `fetchNextPage(using:)` is running.
    public private(set) var isFetchingNextPage = false

    /// The latest accumulated infinite data.
    public var data: InfiniteData<PageParam, Page>? {
        result?.data
    }

    /// The fetched pages in append order.
    public var pages: [Page] {
        data?.pages ?? []
    }

    /// The page parameters used to fetch `pages`.
    public var pageParams: [PageParam] {
        data?.pageParams ?? []
    }

    /// The latest query error when the infinite query is in an error state.
    public var error: Error? {
        result?.error
    }

    /// A Boolean value indicating whether another next page is available.
    public var hasNextPage: Bool {
        guard let data, let lastPage = data.pages.last else {
            return false
        }

        return query.getNextPageParam(lastPage, data.pages) != nil
    }

    /// The cache identity observed by this state object.
    public var key: QueryKey<InfiniteData<PageParam, Page>> {
        query.key
    }

    /// Observer options used when the state starts.
    public let options: QueryObserverOptions

    @ObservationIgnored private let query: InfiniteQuery<PageParam, Page>
    @ObservationIgnored nonisolated(unsafe) private var subscription: QuerySubscription?
    @ObservationIgnored nonisolated(unsafe) private var subscriptionTask: Task<Void, Never>?
    @ObservationIgnored nonisolated(unsafe) private var fetchTask: Task<Void, Never>?
    @ObservationIgnored nonisolated(unsafe) private var nextPageTask: Task<Void, Never>?
    @ObservationIgnored private var isObserving = false
    @ObservationIgnored nonisolated(unsafe) private var generation: UInt64 = 0

    /// Creates observable infinite query state.
    ///
    /// - Parameters:
    ///   - query: The infinite query declaration to observe and fetch.
    ///   - options: Observer options that control initial fetch behavior.
    public init(
        query: InfiniteQuery<PageParam, Page>,
        options: QueryObserverOptions = .default
    ) {
        self.query = query
        self.options = options
    }

    deinit {
        subscriptionTask?.cancel()
        fetchTask?.cancel()
        nextPageTask?.cancel()

        if let subscription {
            Task {
                await subscription.cancel()
            }
        }
    }

    /// Starts observing the infinite query with the provided client.
    ///
    /// Subscribes to the accumulated cache key and, when `options.enabled` is
    /// `true`, performs an initial fetch according to
    /// `options.refetchOnSubscribe`.
    public func start(using client: QueryClient) {
        stop()
        startCurrentKey(using: client)
    }

    /// Stops observing query publications and cancels active state tasks.
    public func stop() {
        generation += 1
        isObserving = false
        subscriptionTask?.cancel()
        subscriptionTask = nil
        fetchTask?.cancel()
        fetchTask = nil
        nextPageTask?.cancel()
        nextPageTask = nil
        isFetchingNextPage = false

        guard let subscription else {
            return
        }

        self.subscription = nil
        Task {
            await subscription.cancel()
        }
    }

    /// Refetches the infinite query from its initial page.
    ///
    /// MVP refetch replaces accumulated pages with the first page loaded from
    /// `initialPageParam`.
    public func refetch(using client: QueryClient) {
        fetchTask?.cancel()
        let observedKey = query.key
        let gen = generation
        let query = query
        fetchTask = Task {
            let result = await client.fetchInfiniteQuery(query)
            guard self.generation == gen else { return }
            self.apply(result, for: observedKey)
        }
    }

    /// Fetches the next page and appends it when `hasNextPage` is `true`.
    ///
    /// Calls made while a next-page fetch is running are ignored by this state
    /// object. Core also deduplicates in-flight work for the same typed key.
    public func fetchNextPage(using client: QueryClient) {
        guard !isFetchingNextPage, hasNextPage || result?.data == nil else {
            return
        }

        nextPageTask?.cancel()
        isFetchingNextPage = true
        let observedKey = query.key
        let gen = generation
        let query = query
        nextPageTask = Task {
            let result = await client.fetchNextPage(query)
            guard self.generation == gen else { return }
            self.apply(result, for: observedKey)
            self.isFetchingNextPage = false
        }
    }

    private func startCurrentKey(using client: QueryClient) {
        let observedKey = query.key
        let gen = generation
        isObserving = true

        subscriptionTask = Task { [weak self] in
            guard let self else { return }

            let subscription = await client.subscribe(
                to: observedKey,
                deliverOn: .main
            ) { [weak state = self] result in
                Task { @MainActor in
                    guard let state, state.generation == gen else { return }
                    state.apply(result, for: observedKey)
                }
            }

            guard !Task.isCancelled else {
                await subscription.cancel()
                return
            }

            self.subscription = subscription

            if options.enabled,
               await self.shouldFetch(options.refetchOnSubscribe, key: observedKey, using: client) {
                let result = await client.fetchInfiniteQuery(query)
                guard self.generation == gen else { return }
                self.apply(result, for: observedKey)
            }
        }
    }

    private func apply(
        _ incoming: QueryResult<InfiniteData<PageParam, Page>>,
        for observedKey: QueryKey<InfiniteData<PageParam, Page>>
    ) {
        guard key == observedKey else {
            return
        }

        result = incoming
    }

    private func shouldFetch(
        _ trigger: RefetchTrigger,
        key: QueryKey<InfiniteData<PageParam, Page>>,
        using client: QueryClient
    ) async -> Bool {
        guard options.enabled else {
            return false
        }

        switch trigger {
        case .never:
            return false
        case .always:
            return true
        case .ifStale:
            return await client.isQueryStale(key)
        }
    }
}
