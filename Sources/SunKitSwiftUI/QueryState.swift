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
/// key and exposes the latest `QueryResult`.
@MainActor
@Observable
public final class QueryState<Value: Sendable> {
    /// The latest query result delivered by Core, if any.
    public private(set) var result: QueryResult<Value>?

    /// The cache identity observed by this state object.
    public private(set) var key: QueryKey<Value>

    /// Query execution options, or `nil` to use the executing client's defaults.
    public let queryOptions: QueryOptions?

    /// Observer options used when the state starts.
    public let options: QueryObserverOptions

    @ObservationIgnored private var subscription: QuerySubscription?
    @ObservationIgnored private var subscriptionTask: Task<Void, Never>?
    @ObservationIgnored private var fetchTask: Task<Void, Never>?
    @ObservationIgnored private var lastSuccessfulData: Value?
    @ObservationIgnored private var intervalTask: Task<Void, Never>?
    @ObservationIgnored private var sceneActiveObserver: NSObjectProtocol?
    @ObservationIgnored private var pathMonitor: NWPathMonitor?
    @ObservationIgnored private var pathMonitorQueue: DispatchQueue?
    @ObservationIgnored private var isObserving = false
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var fetch: @Sendable () async throws -> Value

    static var sceneActiveNotificationName: Notification.Name {
        #if canImport(UIKit)
        return UIApplication.didBecomeActiveNotification
        #elseif canImport(AppKit)
        return NSApplication.didBecomeActiveNotification
        #else
        return Notification.Name("_QueryStateSceneActive")
        #endif
    }

    /// Creates observable query state from an async throwing fetcher.
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
        options: QueryObserverOptions = .default,
        fetch: @escaping @Sendable () async throws -> Value
    ) {
        self.key = QueryKey(key)
        self.queryOptions = queryOptions
        self.options = options
        self.fetch = fetch
    }

    deinit {
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
    /// Subscribes to the query key and, when `options.enabled` is `true` and
    /// `options.refetchOnSubscribe` is not `.never`, performs an initial fetch.
    /// After the initial fetch, any enabled periodic, scene-active, or
    /// network-reconnect refetch triggers are armed and remain active until
    /// ``stop()`` is called.
    public func start(using client: QueryClient) {
        stop()
        startCurrentKey(using: client)
    }

    /// Updates the observed key and fetcher, then observes the updated query.
    ///
    /// When the new key matches the current key, the state keeps the existing
    /// subscription and only replaces the fetcher used by future refetches.
    /// When the key changes, the state cancels its current subscription and
    /// refetch triggers, clears key-scoped placeholder data, and subscribes to
    /// the new key.
    ///
    /// `QueryState` compares the newly built key with the current key. It does
    /// not observe mutation inside reference-typed key parts; key parts should
    /// be stable value snapshots.
    ///
    /// - Parameters:
    ///   - key: The cache identity parts to observe and fetch.
    ///   - client: The query client used for subscription and fetches.
    ///   - fetch: The async operation that loads the updated query value.
    public func update(
        key: [AnyQueryKeyPart],
        using client: QueryClient,
        fetch: @escaping @Sendable () async throws -> Value
    ) {
        let nextKey = QueryKey<Value>(key)
        self.fetch = fetch

        guard nextKey != self.key else {
            if !isObserving {
                startCurrentKey(using: client)
            }
            return
        }

        stop()
        self.key = nextKey
        result = nil
        lastSuccessfulData = nil
        startCurrentKey(using: client)
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

            if options.enabled, options.refetchOnSubscribe != .never {
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
                self.handleSceneActive(using: client)
            }
        }
    }

    @MainActor
    private func handleSceneActive(using client: QueryClient) {
        switch options.refetchOnSceneActive {
        case .never:
            return
        case .always:
            refetch(using: client)
        case .ifStale:
            if result?.isStale ?? true {
                refetch(using: client)
            }
        }
    }

    private func stopSceneActiveObserver() {
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
                self.handleNetworkReconnect(using: client)
            }
        }
        monitor.start(queue: queue)
        pathMonitor = monitor
        pathMonitorQueue = queue
    }

    @MainActor
    private func handleNetworkReconnect(using client: QueryClient) {
        switch options.refetchOnNetworkReconnect {
        case .never:
            return
        case .always:
            refetch(using: client)
        case .ifStale:
            if result?.isStale ?? true {
                refetch(using: client)
            }
        }
    }

    private func stopNetworkMonitor() {
        pathMonitor?.cancel()
        pathMonitor = nil
        pathMonitorQueue = nil
    }

    private func startIntervalTimer(using client: QueryClient) {
        guard let interval = options.refetchInterval, interval > 0 else { return }
        intervalTask = Task { [weak self] in
            while !Task.isCancelled {
                let nanoseconds = UInt64(interval * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanoseconds)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard self?.result?.isFetching != true else { return }
                    self?.refetch(using: client)
                }
            }
        }
    }

    private func stopIntervalTimer() {
        intervalTask?.cancel()
        intervalTask = nil
    }

    private func apply(_ incoming: QueryResult<Value>, for observedKey: QueryKey<Value>) {
        guard key == observedKey else {
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

    private func makeQuery(for observedKey: QueryKey<Value>) -> Query<Value> {
        Query(key: observedKey, options: queryOptions, fetch: fetch)
    }
}
