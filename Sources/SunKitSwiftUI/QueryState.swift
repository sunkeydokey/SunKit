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
    public let key: QueryKey<Value>

    /// Query execution options, or `nil` to use the executing client's defaults.
    public let queryOptions: QueryOptions?

    /// Observer options used when the state starts.
    public let options: QueryObserverOptions

    @ObservationIgnored private var subscription: QuerySubscription?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let fetch: @Sendable () async throws -> Value

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
        task?.cancel()

        if let subscription {
            Task {
                await subscription.cancel()
            }
        }
    }

    /// Starts observing the query with the provided client.
    ///
    /// This method subscribes to the query key and starts an initial fetch when
    /// `options.enabled` is `true` and `options.refetchOnSubscribe` is not
    /// `.never`.
    public func start(using client: QueryClient) {
        stop()

        task = Task { [weak self] in
            guard let self else {
                return
            }

            let subscription = await client.subscribe(
                to: key,
                deliverOn: .main
            ) { [weak state = self] result in
                Task { @MainActor in
                    state?.result = result
                }
            }

            guard !Task.isCancelled else {
                await subscription.cancel()
                return
            }

            self.subscription = subscription

            if options.enabled, options.refetchOnSubscribe != .never {
                let result = await client.fetchQuery(makeQuery())
                self.result = result
            }
        }
    }

    /// Fetches the query again with the provided client.
    public func refetch(using client: QueryClient) {
        task?.cancel()
        task = Task {
            let result = await client.fetchQuery(makeQuery())
            self.result = result
        }
    }

    /// Stops observing query publications.
    public func stop() {
        task?.cancel()
        task = nil

        guard let subscription else {
            return
        }

        self.subscription = nil
        Task {
            await subscription.cancel()
        }
    }

    private func makeQuery() -> Query<Value> {
        Query(key: key, options: queryOptions, fetch: fetch)
    }
}
