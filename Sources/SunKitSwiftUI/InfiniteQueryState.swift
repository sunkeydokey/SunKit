#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif
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

    /// Per-observer cache lifecycle options, or `nil` to use the executing client's defaults.
    ///
    /// When non-`nil`, `staleTime` controls this observer's stale calculation
    /// and `gcTime` is used if this observer is the last subscriber to leave.
    public let cacheOptions: QueryCacheOptions?

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
    @ObservationIgnored nonisolated(unsafe) private var localStaleTimer: Task<Void, Never>?
    @ObservationIgnored nonisolated(unsafe) private var triggerController: RefetchTriggerController?
    @ObservationIgnored private var isObserving = false
    @ObservationIgnored private var currentEnabled: Bool
    @ObservationIgnored nonisolated(unsafe) private var generation: UInt64 = 0
    @ObservationIgnored private var currentClient: QueryClient?
    @ObservationIgnored private let sceneActiveNotificationName: Notification.Name

    static var sceneActiveNotificationName: Notification.Name {
        #if canImport(UIKit)
        return UIApplication.didBecomeActiveNotification
        #elseif canImport(AppKit)
        return NSApplication.didBecomeActiveNotification
        #else
        return Notification.Name("_InfiniteQueryStateSceneActive")
        #endif
    }

    var isSceneActiveRefetchTriggerArmed: Bool {
        triggerController?.isSceneActiveArmed == true
    }

    var isNetworkReconnectRefetchTriggerArmed: Bool {
        triggerController?.isNetworkReconnectArmed == true
    }

    /// Creates observable infinite query state.
    ///
    /// - Parameters:
    ///   - query: The infinite query declaration to observe and fetch.
    ///   - cacheOptions: Per-observer cache lifecycle options, or `nil` to use
    ///     the executing client's defaults.
    ///   - options: Observer options that control initial fetch behavior.
    public convenience init(
        query: InfiniteQuery<PageParam, Page>,
        cacheOptions: QueryCacheOptions? = nil,
        options: QueryObserverOptions<InfiniteData<PageParam, Page>, SelectedValue>
    ) {
        self.init(
            query: query,
            cacheOptions: cacheOptions,
            options: options,
            sceneActiveNotificationName: Self.sceneActiveNotificationName
        )
    }

    internal init(
        query: InfiniteQuery<PageParam, Page>,
        cacheOptions: QueryCacheOptions? = nil,
        options: QueryObserverOptions<InfiniteData<PageParam, Page>, SelectedValue>,
        sceneActiveNotificationName: Notification.Name
    ) {
        self.query = query
        self.cacheOptions = cacheOptions
        self.options = options
        self.currentEnabled = options.enabled
        self.sceneActiveNotificationName = sceneActiveNotificationName
    }

    internal convenience init(
        cacheOptions: QueryCacheOptions? = nil,
        options: QueryObserverOptions<InfiniteData<PageParam, Page>, SelectedValue>
    ) {
        self.init(
            cacheOptions: cacheOptions,
            options: options,
            sceneActiveNotificationName: Self.sceneActiveNotificationName
        )
    }

    internal init(
        cacheOptions: QueryCacheOptions? = nil,
        options: QueryObserverOptions<InfiniteData<PageParam, Page>, SelectedValue>,
        sceneActiveNotificationName: Notification.Name
    ) {
        self.query = nil
        self.cacheOptions = cacheOptions
        self.options = options
        self.currentEnabled = options.enabled
        self.sceneActiveNotificationName = sceneActiveNotificationName
    }

    deinit {
        stopRefetchTriggers()
        localStaleTimer?.cancel()
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
        currentClient = client
        stop()
        currentClient = client
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
        currentClient = client
        let previousKey = self.query?.key
        self.query = query

        guard previousKey == query.key else {
            currentEnabled = enabled
            stop()
            currentClient = client
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
                    self.startRefetchTriggers(using: client)
                }
            } else {
                startCurrentKey(using: client)
            }
            return
        }

        if wasEnabled, !enabled {
            stopRefetchTriggers()
            return
        }

        if !isObserving {
            startCurrentKey(using: client)
        }
    }

    /// Stops observing query publications and cancels active state tasks.
    public func stop() {
        generation += 1
        stopRefetchTriggers()
        localStaleTimer?.cancel()
        localStaleTimer = nil
        isObserving = false
        currentClient = nil
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
    /// If the key already has cached pages, refetch starts from the first
    /// stored page parameter and reloads the same number of pages sequentially.
    /// With
    /// ``PlaceholderData/keepPreviousData``, previous pages remain visible as
    /// observer-local placeholder data while the refetch is pending.
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

    /// Refetches the infinite query with the client most recently supplied by
    /// ``start(using:)`` or ``update(query:using:enabled:)``.
    public func refetch() {
        guard let currentClient else {
            assertionFailure("InfiniteQueryState.refetch() requires start(using:) or update(query:using:enabled:) to supply a QueryClient first.")
            return
        }

        refetch(using: currentClient)
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

    /// Fetches the next page with the client most recently supplied by
    /// ``start(using:)`` or ``update(query:using:enabled:)``.
    public func fetchNextPage() {
        guard let currentClient else {
            assertionFailure("InfiniteQueryState.fetchNextPage() requires start(using:) or update(query:using:enabled:) to supply a QueryClient first.")
            return
        }

        fetchNextPage(using: currentClient)
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
                gcTime: cacheOptions?.gcTime,
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
            self.startRefetchTriggers(using: client)
        }
    }

    private func startRefetchTriggers(using client: QueryClient) {
        guard currentEnabled else { return }
        let gen = generation

        let controller = RefetchTriggerController(sceneActiveNotificationName: sceneActiveNotificationName)
        if options.refetchOnSceneActive != .never {
            controller.startSceneActive { [weak self] in
                guard let self, self.generation == gen else { return }
                await self.handleSceneActive(using: client)
            }
        }
        if options.refetchOnNetworkReconnect != .never {
            controller.startNetworkReconnect { [weak self] in
                guard let self, self.generation == gen else { return }
                await self.handleNetworkReconnect(using: client)
            }
        }

        triggerController = controller
    }

    @MainActor
    func handleSceneActive(using client: QueryClient) async {
        if await shouldFetch(options.refetchOnSceneActive, key: key, using: client) {
            refetch(using: client)
        }
    }

    @MainActor
    func handleNetworkReconnect(using client: QueryClient) async {
        if await shouldFetch(options.refetchOnNetworkReconnect, key: key, using: client) {
            refetch(using: client)
        }
    }

    private nonisolated func stopRefetchTriggers() {
        triggerController?.stop()
        triggerController = nil
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
            let rawDiffersOnlyByStaleFlag = rawResult.map {
                incoming.differsOnlyByStaleFlag(from: $0)
            } ?? false
            rawResult = incoming
            if !rawDiffersOnlyByStaleFlag {
                updateRawPageProjections(from: incoming)
            }
            if incoming.isSuccess, let data = incoming.data {
                lastSuccessfulRawData = data
            }
            if selected.isSuccess, let data = selected.data {
                lastSuccessfulData = data
            }
            return
        }

        let selectedIsStale = computeIsStale(for: selected)

        if options.placeholderData == .keepPreviousData,
           selected.isPending,
           let previous = lastSuccessfulData {
            if let previousRaw = lastSuccessfulRawData {
                let placeholderRawResult = QueryResult(
                    status: .pending(previous: previousRaw),
                    isFetching: incoming.isFetching,
                    isStale: computeIsStale(for: incoming),
                    isInvalidated: incoming.isInvalidated,
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
                isStale: selectedIsStale,
                isInvalidated: selected.isInvalidated,
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
            result = QueryResult(
                status: selected.status,
                isFetching: selected.isFetching,
                isStale: selectedIsStale,
                isInvalidated: selected.isInvalidated,
                isPlaceholderData: selected.isPlaceholderData,
                updatedAt: selected.updatedAt
            )
            if selected.isSuccess, let updatedAt = selected.updatedAt, cacheOptions != nil {
                scheduleLocalStaleTimer(updatedAt: updatedAt)
            }
        }
    }

    private func computeIsStale<Value>(for result: QueryResult<Value>) -> Bool {
        if result.isInvalidated {
            return true
        }

        guard let cacheOptions else {
            return result.isStale
        }

        guard let updatedAt = result.updatedAt else {
            return true
        }

        return Date().timeIntervalSince(updatedAt) >= cacheOptions.staleTime
    }

    private func scheduleLocalStaleTimer(updatedAt: Date) {
        localStaleTimer?.cancel()
        localStaleTimer = nil

        guard let cacheOptions, cacheOptions.staleTime > 0 else {
            return
        }

        let remaining = cacheOptions.staleTime - Date().timeIntervalSince(updatedAt)
        guard remaining > 0 else {
            markLocalResultStale()
            return
        }

        let gen = generation
        localStaleTimer = Task { [weak self] in
            let nanoseconds = UInt64(remaining * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.generation == gen else { return }
                self.markLocalResultStale()
            }
        }
    }

    private func markLocalResultStale() {
        guard let current = result, !current.isStale else {
            return
        }

        result = QueryResult(
            status: current.status,
            isFetching: current.isFetching,
            isStale: true,
            isInvalidated: current.isInvalidated,
            isPlaceholderData: current.isPlaceholderData,
            updatedAt: current.updatedAt
        )
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
            return await client.isQueryStale(key, cacheOptions: cacheOptions)
        }
    }
}

public extension InfiniteQueryState where SelectedValue == InfiniteData<PageParam, Page> {
    /// Creates observable infinite query state that exposes accumulated raw data.
    ///
    /// - Parameters:
    ///   - query: The infinite query declaration to observe and fetch.
    convenience init(
        query: InfiniteQuery<PageParam, Page>,
        cacheOptions: QueryCacheOptions? = nil
    ) {
        self.init(query: query, cacheOptions: cacheOptions, options: .default)
    }
}

private extension QueryResult {
    func differsOnlyByStaleFlag(from other: Self) -> Bool {
        isStale != other.isStale
            && isFetching == other.isFetching
            && isInvalidated == other.isInvalidated
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
