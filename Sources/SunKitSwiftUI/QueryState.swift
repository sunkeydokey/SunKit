#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif
import Network
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

    /// The cache identity observed by this state object.
    public private(set) var key: QueryKey<RawValue>

    /// Query execution options, or `nil` to use the executing client's defaults.
    public let queryOptions: QueryOptions?

    /// Observer options used when the state starts.
    public let options: QueryObserverOptions<RawValue, SelectedValue>

    @ObservationIgnored nonisolated(unsafe) private var subscription: QuerySubscription?
    @ObservationIgnored nonisolated(unsafe) private var subscriptionTask: Task<Void, Never>?
    @ObservationIgnored nonisolated(unsafe) private var fetchTask: Task<Void, Never>?
    @ObservationIgnored private var lastSuccessfulData: SelectedValue?
    @ObservationIgnored nonisolated(unsafe) private var intervalTask: Task<Void, Never>?
    @ObservationIgnored nonisolated(unsafe) private var sceneActiveObserver: NSObjectProtocol?
    @ObservationIgnored nonisolated(unsafe) private var pathMonitor: NWPathMonitor?
    @ObservationIgnored nonisolated(unsafe) private var pathMonitorQueue: DispatchQueue?
    @ObservationIgnored private var isObserving = false
    @ObservationIgnored private var currentEnabled: Bool
    @ObservationIgnored nonisolated(unsafe) private var generation: UInt64 = 0
    @ObservationIgnored private var fetch: @Sendable () async throws -> RawValue

    static var sceneActiveNotificationName: Notification.Name {
        #if canImport(UIKit)
        return UIApplication.didBecomeActiveNotification
        #elseif canImport(AppKit)
        return NSApplication.didBecomeActiveNotification
        #else
        return Notification.Name("_QueryStateSceneActive")
        #endif
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
    ///   - options: Observer options that control initial fetch behavior.
    ///   - fetch: The async operation that loads the query value.
    public init(
        key: [AnyQueryKeyPart],
        queryOptions: QueryOptions? = nil,
        options: QueryObserverOptions<RawValue, SelectedValue>,
        fetch: @escaping @Sendable () async throws -> RawValue
    ) {
        self.key = QueryKey(key)
        self.queryOptions = queryOptions
        self.options = options
        self.fetch = fetch
        self.currentEnabled = options.enabled
    }

    deinit {
        stopIntervalTimer()
        stopSceneActiveObserver()
        stopNetworkMonitor()
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
        stop()
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
        let nextKey = QueryKey<RawValue>(key)
        self.fetch = fetch

        guard nextKey == self.key else {
            currentEnabled = enabled
            stop()
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
                    self.startSceneActiveObserver(using: client)
                    self.startNetworkMonitor(using: client)
                }
            } else {
                startCurrentKey(using: client)
            }
            return
        }

        if wasEnabled, !enabled {
            stopIntervalTimer()
            stopSceneActiveObserver()
            stopNetworkMonitor()
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
            self.startSceneActiveObserver(using: client)
            self.startNetworkMonitor(using: client)
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

    /// Stops observing query publications and cancels all active refetch triggers.
    ///
    /// Cancels the periodic interval timer, the scene-active observer, the
    /// network-reconnect monitor, and the current subscription. Safe to call
    /// multiple times.
    public func stop() {
        generation += 1
        stopIntervalTimer()
        stopSceneActiveObserver()
        stopNetworkMonitor()
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
    private func handleSceneActive(using client: QueryClient) async {
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
        let queue = DispatchQueue(label: "sunkit.network-monitor", qos: .utility)
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
    private func handleNetworkReconnect(using client: QueryClient) async {
        if await shouldFetch(options.refetchOnNetworkReconnect, key: key, using: client) {
            refetch(using: client)
        }
    }

    private nonisolated func stopNetworkMonitor() {
        pathMonitor?.cancel()
        pathMonitor = nil
        pathMonitorQueue = nil
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

        if options.placeholderData == .keepPreviousData,
           selected.isPending,
           let previous = lastSuccessfulData {
            result = QueryResult(
                status: .pending(previous: previous),
                isFetching: selected.isFetching,
                isStale: selected.isStale,
                isPlaceholderData: true,
                updatedAt: selected.updatedAt
            )
        } else {
            if selected.isSuccess, let data = selected.data {
                lastSuccessfulData = data
            }
            result = selected
        }
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
            return await client.isQueryStale(key)
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
        fetch: @escaping @Sendable () async throws -> RawValue
    ) {
        self.init(key: key, queryOptions: queryOptions, options: .default, fetch: fetch)
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
