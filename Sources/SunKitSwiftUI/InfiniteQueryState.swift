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
/// accumulated infinite-query cache value and exposes selected data for
/// rendering infinite-scroll or "load more" interfaces.
@MainActor
@Observable
public final class InfiniteQueryState<PageParam: Sendable, Page: Sendable, SelectedValue: Sendable> {
    /// The latest selected accumulated query result, if any.
    public private(set) var result: QueryResult<SelectedValue>?

    /// A Boolean value indicating whether `fetchNextPage(using:)` is running.
    public private(set) var isFetchingNextPage = false

    /// The latest selected infinite data.
    public var data: SelectedValue? {
        result?.data
    }

    /// The fetched pages in append order.
    public private(set) var pages: [Page] = []

    /// The page parameters used to fetch `pages`.
    public private(set) var pageParams: [PageParam] = []

    /// The latest query error when the infinite query is in an error state.
    public var error: Error? {
        result?.error
    }

    /// A Boolean value indicating whether another next page is available.
    public var hasNextPage: Bool {
        guard let lastPage = pages.last else {
            return false
        }

        guard let query else {
            return false
        }

        return query.getNextPageParam(lastPage, pages) != nil
    }

    /// The cache identity observed by this state object.
    public var key: QueryKey<InfiniteData<PageParam, Page>> {
        query?.key ?? QueryKey([])
    }

    /// Observer options used when the state starts.
    ///
    /// The raw accumulated `InfiniteData` value is stored in `QueryClient`;
    /// `options.select` transforms it into the selected value exposed by
    /// ``result`` and ``data``.
    public let options: QueryObserverOptions<InfiniteData<PageParam, Page>, SelectedValue>

    @ObservationIgnored private var query: InfiniteQuery<PageParam, Page>?
    @ObservationIgnored private var rawResult: QueryResult<InfiniteData<PageParam, Page>>?
    @ObservationIgnored nonisolated(unsafe) private var subscription: QuerySubscription?
    @ObservationIgnored nonisolated(unsafe) private var subscriptionTask: Task<Void, Never>?
    @ObservationIgnored nonisolated(unsafe) private var fetchTask: Task<Void, Never>?
    @ObservationIgnored nonisolated(unsafe) private var nextPageTask: Task<Void, Never>?
    @ObservationIgnored private var lastSuccessfulData: SelectedValue?
    @ObservationIgnored private var lastSuccessfulRawData: InfiniteData<PageParam, Page>?
    @ObservationIgnored nonisolated(unsafe) private var sceneActiveObserver: NSObjectProtocol?
    @ObservationIgnored nonisolated(unsafe) private var pathMonitor: NWPathMonitor?
    @ObservationIgnored nonisolated(unsafe) private var pathMonitorQueue: DispatchQueue?
    @ObservationIgnored private var isObserving = false
    @ObservationIgnored private var currentEnabled: Bool
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
        options: QueryObserverOptions<InfiniteData<PageParam, Page>, SelectedValue>
    ) {
        self.query = query
        self.options = options
        self.currentEnabled = options.enabled
    }

    internal init(
        options: QueryObserverOptions<InfiniteData<PageParam, Page>, SelectedValue>
    ) {
        self.query = nil
        self.options = options
        self.currentEnabled = options.enabled
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

    /// Updates the observed infinite query and enabled state.
    ///
    /// When the new key matches the current key, the state keeps the existing
    /// subscription and only replaces the query used by future fetches.
    /// When `enabled` transitions from `false` to `true` with the same key,
    /// the state starts fetching and arms all refetch triggers.
    /// When `enabled` transitions from `true` to `false` with the same key,
    /// the state stops the scene-active observer and network monitor.
    /// When the key changes, the state cancels its current subscription and
    /// refetch triggers, clears accumulated pages, and subscribes to the new key.
    ///
    /// - Parameters:
    ///   - query: The updated infinite query declaration.
    ///   - client: The query client used for subscription and fetches.
    ///   - enabled: Whether the observer may trigger fetches. Defaults to `true`.
    public func update(
        query: InfiniteQuery<PageParam, Page>,
        using client: QueryClient,
        enabled: Bool = true
    ) {
        let previousKey = self.query?.key
        self.query = query

        guard previousKey == query.key else {
            currentEnabled = enabled
            stop()
            result = nil
            rawResult = nil
            pages = []
            pageParams = []
            lastSuccessfulData = nil
            lastSuccessfulRawData = nil
            startCurrentKey(using: client)
            return
        }

        let wasEnabled = currentEnabled
        currentEnabled = enabled

        if !wasEnabled, enabled {
            if isObserving {
                let observedKey = self.key
                let gen = generation
                fetchTask?.cancel()
                fetchTask = Task { [weak self] in
                    guard let self else { return }
                    if await self.shouldFetch(options.refetchOnSubscribe, key: observedKey, using: client) {
                        let result = await client.fetchInfiniteQuery(query)
                        guard self.generation == gen else { return }
                        self.apply(result, for: observedKey)
                    }
                    guard self.generation == gen else { return }
                    self.startSceneActiveObserver(using: client)
                    self.startNetworkMonitor(using: client)
                }
            } else {
                startCurrentKey(using: client)
            }
            return
        }

        if wasEnabled, !enabled {
            stopSceneActiveObserver()
            stopNetworkMonitor()
            return
        }

        if !isObserving {
            startCurrentKey(using: client)
        }
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
        guard let query else {
            return
        }

        fetchTask?.cancel()
        let observedKey = query.key
        let gen = generation
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
        guard let query else {
            return
        }

        guard !isFetchingNextPage, hasNextPage || pages.isEmpty else {
            return
        }

        nextPageTask?.cancel()
        isFetchingNextPage = true
        let observedKey = query.key
        let gen = generation
        nextPageTask = Task {
            let result = await client.fetchNextPage(query)
            guard self.generation == gen else { return }
            self.apply(result, for: observedKey)
            self.isFetchingNextPage = false
        }
    }

    private func startCurrentKey(using client: QueryClient) {
        guard let query else {
            return
        }

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

            if currentEnabled,
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

        let selected = incoming.map(options.select)

        if let result, selected.differsOnlyByStaleFlag(from: result) {
            rawResult = incoming
            updateRawPageProjections(from: incoming)
            if incoming.isSuccess, let data = incoming.data {
                lastSuccessfulRawData = data
            }
            if selected.isSuccess, let data = selected.data {
                lastSuccessfulData = data
            }
            return
        }

        if options.placeholderData == .keepPreviousData,
           selected.isPending,
           let previous = lastSuccessfulData {
            if let previousRaw = lastSuccessfulRawData {
                let placeholderRawResult = QueryResult(
                    status: .pending(previous: previousRaw),
                    isFetching: incoming.isFetching,
                    isStale: incoming.isStale,
                    isPlaceholderData: true,
                    updatedAt: incoming.updatedAt
                )
                rawResult = placeholderRawResult
                updateRawPageProjections(from: placeholderRawResult)
            } else {
                rawResult = incoming
                updateRawPageProjections(from: incoming)
            }
            result = QueryResult(
                status: .pending(previous: previous),
                isFetching: selected.isFetching,
                isStale: selected.isStale,
                isPlaceholderData: true,
                updatedAt: selected.updatedAt
            )
        } else {
            rawResult = incoming
            updateRawPageProjections(from: incoming)
            if incoming.isSuccess, let data = incoming.data {
                lastSuccessfulRawData = data
            }
            if selected.isSuccess, let data = selected.data {
                lastSuccessfulData = data
            }
            result = selected
        }
    }

    private func updateRawPageProjections(from rawResult: QueryResult<InfiniteData<PageParam, Page>>) {
        pages = rawResult.data?.pages ?? []
        pageParams = rawResult.data?.pageParams ?? []
    }

    private func shouldFetch(
        _ trigger: RefetchTrigger,
        key: QueryKey<InfiniteData<PageParam, Page>>,
        using client: QueryClient
    ) async -> Bool {
        guard currentEnabled else {
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

public extension InfiniteQueryState where SelectedValue == InfiniteData<PageParam, Page> {
    /// Creates observable infinite query state that exposes accumulated raw data.
    ///
    /// - Parameters:
    ///   - query: The infinite query declaration to observe and fetch.
    convenience init(
        query: InfiniteQuery<PageParam, Page>
    ) {
        self.init(query: query, options: .default)
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
