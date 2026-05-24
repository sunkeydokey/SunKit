#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif
import Network
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

    @ObservationIgnored private var query: InfiniteQuery<PageParam, Page>
    @ObservationIgnored nonisolated(unsafe) private var subscription: QuerySubscription?
    @ObservationIgnored nonisolated(unsafe) private var subscriptionTask: Task<Void, Never>?
    @ObservationIgnored nonisolated(unsafe) private var fetchTask: Task<Void, Never>?
    @ObservationIgnored nonisolated(unsafe) private var nextPageTask: Task<Void, Never>?
    @ObservationIgnored private var lastSuccessfulData: InfiniteData<PageParam, Page>?
    @ObservationIgnored nonisolated(unsafe) private var sceneActiveObserver: NSObjectProtocol?
    @ObservationIgnored nonisolated(unsafe) private var pathMonitor: NWPathMonitor?
    @ObservationIgnored nonisolated(unsafe) private var pathMonitorQueue: DispatchQueue?
    @ObservationIgnored private var isObserving = false
    @ObservationIgnored nonisolated(unsafe) private var generation: UInt64 = 0

    static var sceneActiveNotificationName: Notification.Name {
        #if canImport(UIKit)
        return UIApplication.didBecomeActiveNotification
        #elseif canImport(AppKit)
        return NSApplication.didBecomeActiveNotification
        #else
        return Notification.Name("_InfiniteQueryStateSceneActive")
        #endif
    }

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
        stopSceneActiveObserver()
        stopNetworkMonitor()
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
    /// `options.refetchOnSubscribe`. After the initial fetch, any enabled
    /// scene-active or network-reconnect refetch triggers are armed and remain
    /// active until ``stop()`` is called.
    public func start(using client: QueryClient) {
        stop()
        startCurrentKey(using: client)
    }

    /// Updates the observed infinite query, then observes the updated cache key.
    ///
    /// When the new query uses the same key, the state keeps the existing
    /// subscription and uses the new query declaration for later refetches and
    /// next-page fetches. When the key changes, the state cancels the current
    /// subscription and refetch triggers, subscribes to the new key, and then
    /// follows the observer options for fetching.
    ///
    /// With ``PlaceholderData/keepPreviousData``, the previous accumulated
    /// pages remain visible as placeholder data while the updated query is
    /// pending. Placeholder data is scoped to this observer and is not written
    /// to the client cache.
    ///
    /// - Parameters:
    ///   - query: The updated infinite query declaration.
    ///   - client: The query client used for subscription and fetches.
    public func update(
        query: InfiniteQuery<PageParam, Page>,
        using client: QueryClient
    ) {
        let previousKey = self.query.key
        self.query = query

        guard query.key != previousKey else {
            if !isObserving {
                startCurrentKey(using: client)
            }
            return
        }

        stop()
        result = nil
        startCurrentKey(using: client)
    }

    /// Stops observing query publications and cancels active state tasks.
    public func stop() {
        generation += 1
        stopSceneActiveObserver()
        stopNetworkMonitor()
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
    /// `initialPageParam`. With ``PlaceholderData/keepPreviousData``, previous
    /// pages remain visible as observer-local placeholder data while the
    /// refetch is pending.
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

            guard self.generation == gen else { return }
            self.startSceneActiveObserver(using: client)
            self.startNetworkMonitor(using: client)
        }
    }

    private func startSceneActiveObserver(using client: QueryClient) {
        guard options.refetchOnSceneActive != .never else { return }
        let gen = generation
        sceneActiveObserver = NotificationCenter.default.addObserver(
            forName: Self.sceneActiveNotificationName,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                guard self.generation == gen else { return }
                await self.handleSceneActive(using: client)
            }
        }
    }

    @MainActor
    func handleSceneActive(using client: QueryClient) async {
        if await shouldFetch(options.refetchOnSceneActive, key: key, using: client) {
            refetch(using: client)
        }
    }

    private nonisolated func stopSceneActiveObserver() {
        if let observer = sceneActiveObserver {
            NotificationCenter.default.removeObserver(observer)
            sceneActiveObserver = nil
        }
    }

    private func startNetworkMonitor(using client: QueryClient) {
        guard options.refetchOnNetworkReconnect != .never else { return }
        let gen = generation
        let monitor = NWPathMonitor()
        let queue = DispatchQueue(label: "sunkit.infinite-network-monitor", qos: .utility)
        nonisolated(unsafe) var isFirstUpdate = true
        nonisolated(unsafe) var previouslySatisfied = false
        monitor.pathUpdateHandler = { [weak self] path in
            let nowSatisfied = path.status == .satisfied
            if isFirstUpdate {
                isFirstUpdate = false
                previouslySatisfied = nowSatisfied
                return
            }
            guard nowSatisfied, !previouslySatisfied else {
                previouslySatisfied = nowSatisfied
                return
            }
            previouslySatisfied = true
            Task { @MainActor [weak self] in
                guard let self, self.generation == gen else { return }
                await self.handleNetworkReconnect(using: client)
            }
        }
        monitor.start(queue: queue)
        pathMonitor = monitor
        pathMonitorQueue = queue
    }

    @MainActor
    func handleNetworkReconnect(using client: QueryClient) async {
        if await shouldFetch(options.refetchOnNetworkReconnect, key: key, using: client) {
            refetch(using: client)
        }
    }

    private nonisolated func stopNetworkMonitor() {
        pathMonitor?.cancel()
        pathMonitor = nil
        pathMonitorQueue = nil
    }

    private func apply(
        _ incoming: QueryResult<InfiniteData<PageParam, Page>>,
        for observedKey: QueryKey<InfiniteData<PageParam, Page>>
    ) {
        guard key == observedKey else {
            return
        }

        if let result, incoming.differsOnlyByStaleFlag(from: result) {
            return
        }

        if options.placeholderData == .keepPreviousData,
           incoming.isPending,
           let previous = lastSuccessfulData {
            result = QueryResult(
                status: .pending(previous: previous),
                isFetching: incoming.isFetching,
                isStale: incoming.isStale,
                isPlaceholderData: true,
                updatedAt: incoming.updatedAt
            )
        } else {
            if incoming.isSuccess, let data = incoming.data {
                lastSuccessfulData = data
            }
            result = incoming
        }
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

private extension QueryResult {
    func differsOnlyByStaleFlag(from other: Self) -> Bool {
        isStale != other.isStale
            && isFetching == other.isFetching
            && isPending == other.isPending
            && isSuccess == other.isSuccess
            && isError == other.isError
            && isPlaceholderData == other.isPlaceholderData
            && updatedAt == other.updatedAt
            && failureCount == other.failureCount
            && (data != nil) == (other.data != nil)
            && (error != nil) == (other.error != nil)
    }
}
