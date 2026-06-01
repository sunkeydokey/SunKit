#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif
import Observation
import SunKit

/// Observable SwiftUI state for a SunKit query.
///
/// Store `QueryState` in SwiftUI with `@State`, then call `start(using:)` from
/// the view lifecycle. The state subscribes to Core query publications for its
/// key and exposes the latest selected `QueryResult`.
@MainActor
@Observable
public final class QueryState<RawValue: Sendable, SelectedValue: Sendable> {
    /// The latest selected query result, if any.
    public private(set) var result: QueryResult<SelectedValue>?

    /// The latest selected query data, including stale data when a refetch fails.
    public var data: SelectedValue? { result?.data }

    /// The latest query error when the query is in an error state.
    public var error: Error? { result?.error }

    /// A Boolean value indicating whether the query is waiting for successful data.
    public var isPending: Bool { result?.isPending ?? currentEnabled }

    /// A Boolean value indicating whether the query currently has successful data.
    public var isSuccess: Bool { result?.isSuccess == true }

    /// A Boolean value indicating whether the query is in an error state.
    public var isError: Bool { result?.isError == true }

    /// A Boolean value indicating whether a fetch task is currently running.
    public var isFetching: Bool { result?.isFetching == true }

    /// The cache identity observed by this state object.
    public private(set) var key: QueryKey<RawValue>

    /// Query execution options, or `nil` to use the executing client's defaults.
    public let queryOptions: QueryOptions?

    /// Per-observer cache lifecycle options, or `nil` to use the executing client's defaults.
    ///
    /// When non-`nil`, `staleTime` controls this observer's stale calculation
    /// and `gcTime` is used if this observer is the last subscriber to leave.
    public let cacheOptions: QueryCacheOptions?

    /// Observer options used when the state starts.
    public let options: QueryObserverOptions<RawValue, SelectedValue>

    @ObservationIgnored nonisolated(unsafe) private var subscription: QuerySubscription?
    @ObservationIgnored nonisolated(unsafe) private var subscriptionTask: Task<Void, Never>?
    @ObservationIgnored nonisolated(unsafe) private var fetchTask: Task<Void, Never>?
    @ObservationIgnored private var lastSuccessfulData: SelectedValue?
    @ObservationIgnored nonisolated(unsafe) private var intervalTask: Task<Void, Never>?
    @ObservationIgnored nonisolated(unsafe) private var localStaleTimer: Task<Void, Never>?
    @ObservationIgnored nonisolated(unsafe) private var triggerController: RefetchTriggerController?
    @ObservationIgnored private var isObserving = false
    @ObservationIgnored private var currentEnabled: Bool
    @ObservationIgnored nonisolated(unsafe) private var generation: UInt64 = 0
    @ObservationIgnored private var fetch: @Sendable () async throws -> RawValue
    @ObservationIgnored private var currentClient: QueryClient?
    @ObservationIgnored private let sceneActiveNotificationName: Notification.Name

    static var sceneActiveNotificationName: Notification.Name {
        #if canImport(UIKit)
        return UIApplication.didBecomeActiveNotification
        #elseif canImport(AppKit)
        return NSApplication.didBecomeActiveNotification
        #else
        return Notification.Name("_QueryStateSceneActive")
        #endif
    }

    var isSceneActiveRefetchTriggerArmed: Bool {
        triggerController?.isSceneActiveArmed == true
    }

    var isNetworkReconnectRefetchTriggerArmed: Bool {
        triggerController?.isNetworkReconnectArmed == true
    }

    /// Creates observable query state from an async throwing raw-value fetcher.
    ///
    /// The raw fetched value is stored in `QueryClient`; `options.select`
    /// transforms it into the selected value exposed by ``result``.
    ///
    /// - Parameters:
    ///   - key: The cache identity parts to subscribe to and fetch.
    ///   - queryOptions: Execution options for fetches, or `nil` to use the
    ///     executing client's defaults.
    ///   - cacheOptions: Per-observer cache lifecycle options, or `nil` to use
    ///     the executing client's defaults.
    ///   - options: Observer options that control initial fetch behavior.
    ///   - fetch: The async operation that loads the query value.
    public convenience init(
        key: [AnyQueryKeyPart],
        queryOptions: QueryOptions? = nil,
        cacheOptions: QueryCacheOptions? = nil,
        options: QueryObserverOptions<RawValue, SelectedValue>,
        fetch: @escaping @Sendable () async throws -> RawValue
    ) {
        self.init(
            key: key,
            queryOptions: queryOptions,
            cacheOptions: cacheOptions,
            options: options,
            sceneActiveNotificationName: Self.sceneActiveNotificationName,
            fetch: fetch
        )
    }

    internal init(
        key: [AnyQueryKeyPart],
        queryOptions: QueryOptions? = nil,
        cacheOptions: QueryCacheOptions? = nil,
        options: QueryObserverOptions<RawValue, SelectedValue>,
        sceneActiveNotificationName: Notification.Name,
        fetch: @escaping @Sendable () async throws -> RawValue
    ) {
        self.key = QueryKey(key)
        self.queryOptions = queryOptions
        self.cacheOptions = cacheOptions
        self.options = options
        self.fetch = fetch
        self.currentEnabled = options.enabled
        self.sceneActiveNotificationName = sceneActiveNotificationName
    }

    deinit {
        stopIntervalTimer()
        localStaleTimer?.cancel()
        stopRefetchTriggers()
        subscriptionTask?.cancel()
        fetchTask?.cancel()

        if let subscription {
            Task {
                await subscription.cancel()
            }
        }
    }

    /// Starts observing the query with the provided client.
    ///
    /// Subscribes to the query key and, when `options.enabled` is `true`,
    /// performs an initial fetch according to `options.refetchOnSubscribe`.
    /// After the initial fetch, any enabled periodic, scene-active, or
    /// network-reconnect refetch triggers are armed and remain active until
    /// ``stop()`` is called.
    public func start(using client: QueryClient) {
        currentClient = client
        stop()
        currentClient = client
        startCurrentKey(using: client)
    }

    /// Updates the observed key, fetcher, and enabled state, then observes the updated query.
    ///
    /// When the new key matches the current key, the state keeps the existing
    /// subscription and only replaces the fetcher used by future refetches.
    /// When `enabled` transitions from `false` to `true` with the same key,
    /// the state starts fetching and arms all refetch triggers.
    /// When `enabled` transitions from `true` to `false` with the same key,
    /// the state stops the interval timer, scene-active observer, and network monitor.
    /// When the key changes, the state cancels its current subscription and
    /// refetch triggers, clears key-scoped placeholder data, and subscribes to
    /// the new key.
    ///
    /// - Parameters:
    ///   - key: The cache identity parts to observe and fetch.
    ///   - client: The query client used for subscription and fetches.
    ///   - fetch: The async operation that loads the updated query value.
    ///   - enabled: Whether the observer may trigger fetches. Defaults to `true`.
    public func update(
        key: [AnyQueryKeyPart],
        using client: QueryClient,
        fetch: @escaping @Sendable () async throws -> RawValue,
        enabled: Bool = true
    ) {
        currentClient = client
        let nextKey = QueryKey<RawValue>(key)
        self.fetch = fetch

        guard nextKey == self.key else {
            currentEnabled = enabled
            stop()
            currentClient = client
            self.key = nextKey
            result = nil
            lastSuccessfulData = nil
            startCurrentKey(using: client)
            return
        }

        let wasEnabled = currentEnabled
        currentEnabled = enabled

        if !wasEnabled, enabled {
            if isObserving {
                let observedKey = key
                let gen = generation
                fetchTask?.cancel()
                fetchTask = Task { [weak self] in
                    guard let self else { return }
                    if await self.shouldFetch(options.refetchOnSubscribe, key: QueryKey(observedKey), using: client) {
                        let result = await client.fetchQuery(makeQuery(for: QueryKey(observedKey)))
                        guard self.generation == gen else { return }
                        self.apply(result, for: QueryKey(observedKey))
                    }
                    guard self.generation == gen else { return }
                    self.startIntervalTimer(using: client)
                    self.startRefetchTriggers(using: client)
                }
            } else {
                startCurrentKey(using: client)
            }
            return
        }

        if wasEnabled, !enabled {
            stopIntervalTimer()
            stopRefetchTriggers()
            return
        }

        if !isObserving {
            startCurrentKey(using: client)
        }
    }

    private func startCurrentKey(using client: QueryClient) {
        let observedKey = key
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
                let result = await client.fetchQuery(makeQuery(for: observedKey))
                guard self.generation == gen else { return }
                self.apply(result, for: observedKey)
            }

            guard self.generation == gen else { return }
            self.startIntervalTimer(using: client)
            self.startRefetchTriggers(using: client)
        }
    }

    /// Fetches the query again with the provided client.
    public func refetch(using client: QueryClient) {
        fetchTask?.cancel()
        let observedKey = key
        let gen = generation
        fetchTask = Task {
            let result = await client.fetchQuery(makeQuery(for: observedKey))
            guard self.generation == gen else { return }
            self.apply(result, for: observedKey)
        }
    }

    /// Fetches the query again with the client most recently supplied by
    /// ``start(using:)`` or ``update(key:using:fetch:enabled:)``.
    public func refetch() {
        guard let currentClient else {
            assertionFailure("QueryState.refetch() requires start(using:) or update(key:using:fetch:enabled:) to supply a QueryClient first.")
            return
        }

        refetch(using: currentClient)
    }

    /// Stops observing query publications and cancels all active refetch triggers.
    ///
    /// Cancels the periodic interval timer, the scene-active observer, the
    /// network-reconnect monitor, and the current subscription. Safe to call
    /// multiple times.
    public func stop() {
        generation += 1
        stopIntervalTimer()
        localStaleTimer?.cancel()
        localStaleTimer = nil
        stopRefetchTriggers()
        currentClient = nil
        isObserving = false
        subscriptionTask?.cancel()
        subscriptionTask = nil
        fetchTask?.cancel()
        fetchTask = nil

        guard let subscription else {
            return
        }

        self.subscription = nil
        Task {
            await subscription.cancel()
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
    private func handleSceneActive(using client: QueryClient) async {
        if await shouldFetch(options.refetchOnSceneActive, key: key, using: client) {
            refetch(using: client)
        }
    }

    @MainActor
    private func handleNetworkReconnect(using client: QueryClient) async {
        if await shouldFetch(options.refetchOnNetworkReconnect, key: key, using: client) {
            refetch(using: client)
        }
    }

    private nonisolated func stopRefetchTriggers() {
        triggerController?.stop()
        triggerController = nil
    }

    private func startIntervalTimer(using client: QueryClient) {
        guard currentEnabled, let interval = options.refetchInterval, interval > 0 else { return }
        let gen = generation
        intervalTask = Task { [weak self] in
            while !Task.isCancelled {
                let nanoseconds = UInt64(interval * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanoseconds)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self, self.generation == gen else { return }
                    guard self.result?.isFetching != true else { return }
                    self.refetch(using: client)
                }
            }
        }
    }

    private nonisolated func stopIntervalTimer() {
        intervalTask?.cancel()
        intervalTask = nil
    }

    private func apply(_ incoming: QueryResult<RawValue>, for observedKey: QueryKey<RawValue>) {
        guard key == observedKey else {
            return
        }

        let selected = incoming.map(options.select)

        if let result, selected.differsOnlyByStaleFlag(from: result) {
            return
        }

        let selectedIsStale = computeIsStale(for: selected)

        if options.placeholderData == .keepPreviousData,
           selected.isPending,
           let previous = lastSuccessfulData {
            result = QueryResult(
                status: .pending(previous: previous),
                isFetching: selected.isFetching,
                isStale: selectedIsStale,
                isInvalidated: selected.isInvalidated,
                isPlaceholderData: true,
                updatedAt: selected.updatedAt
            )
        } else {
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

    private func computeIsStale(for result: QueryResult<SelectedValue>) -> Bool {
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

    private func makeQuery(for observedKey: QueryKey<RawValue>) -> Query<RawValue> {
        Query(key: observedKey, options: queryOptions, fetch: fetch)
    }

    private func shouldFetch(
        _ trigger: RefetchTrigger,
        key: QueryKey<RawValue>,
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

public extension QueryState where RawValue == SelectedValue {
    /// Creates observable query state that exposes the raw cached value.
    ///
    /// - Parameters:
    ///   - key: The cache identity parts to subscribe to and fetch.
    ///   - queryOptions: Execution options for fetches, or `nil` to use the
    ///     executing client's defaults.
    ///   - fetch: The async operation that loads the query value.
    convenience init(
        key: [AnyQueryKeyPart],
        queryOptions: QueryOptions? = nil,
        cacheOptions: QueryCacheOptions? = nil,
        fetch: @escaping @Sendable () async throws -> RawValue
    ) {
        self.init(key: key, queryOptions: queryOptions, cacheOptions: cacheOptions, options: .default, fetch: fetch)
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
