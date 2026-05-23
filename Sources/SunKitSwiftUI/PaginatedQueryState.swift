import Observation
import SunKit

/// Observable SwiftUI state for page-param based queries.
///
/// `PaginatedQueryState` keeps one state identity while changing the observed
/// query key as input or page changes. It delegates cache storage,
/// subscription, and fetching to an internal ``QueryState``.
@MainActor
@Observable
public final class PaginatedQueryState<Input: Sendable, Page: Sendable, Value: Sendable> {
    /// The current input used to build the query key and fetch value.
    public private(set) var input: Input

    /// The current page parameter used to build the query key and fetch value.
    public private(set) var page: Page

    /// The latest query result for the current input and page.
    public var result: QueryResult<Value>? {
        queryState.result
    }

    /// The cache identity currently observed by this state object.
    public var key: QueryKey<Value> {
        queryState.key
    }

    /// Query execution options, or `nil` to use the executing client's defaults.
    public let queryOptions: QueryOptions?

    /// Observer options used when the state starts or changes key.
    public let options: QueryObserverOptions

    @ObservationIgnored private let initialPage: Page
    @ObservationIgnored private let keyBuilder: @Sendable (Input, Page) -> [AnyQueryKeyPart]
    @ObservationIgnored private let fetch: @Sendable (Input, Page) async throws -> Value
    @ObservationIgnored private let nextPageValue: @Sendable (Page) -> Page
    @ObservationIgnored private let previousPageValue: @Sendable (Page) -> Page
    @ObservationIgnored private let canMoveToPreviousPage: @Sendable (Page) -> Bool
    @ObservationIgnored private let queryState: QueryState<Value>

    /// Creates observable paginated query state from an async throwing fetcher.
    ///
    /// - Parameters:
    ///   - input: The initial input, such as a search term or filter value.
    ///   - initialPage: The page used initially and after input changes.
    ///   - queryOptions: Execution options for fetches, or `nil` to use the
    ///     executing client's defaults.
    ///   - options: Observer options that control fetch behavior.
    ///   - key: Builds the cache identity for the current input and page.
    ///   - nextPage: Returns the next page parameter.
    ///   - previousPage: Returns the previous page parameter.
    ///   - canMoveToPreviousPage: Returns whether `previousPage(using:)` may
    ///     move from the current page. Use this to enforce lower bounds.
    ///   - fetch: Loads the value for the current input and page.
    public init(
        input: Input,
        initialPage: Page,
        queryOptions: QueryOptions? = nil,
        options: QueryObserverOptions = .default,
        key: @escaping @Sendable (Input, Page) -> [AnyQueryKeyPart],
        nextPage: @escaping @Sendable (Page) -> Page,
        previousPage: @escaping @Sendable (Page) -> Page,
        canMoveToPreviousPage: @escaping @Sendable (Page) -> Bool,
        fetch: @escaping @Sendable (Input, Page) async throws -> Value
    ) {
        self.input = input
        self.page = initialPage
        self.initialPage = initialPage
        self.queryOptions = queryOptions
        self.options = options
        self.keyBuilder = key
        self.nextPageValue = nextPage
        self.previousPageValue = previousPage
        self.canMoveToPreviousPage = canMoveToPreviousPage
        self.fetch = fetch

        let initialInput = input
        let initialPageValue = initialPage
        self.queryState = QueryState(
            key: key(initialInput, initialPageValue),
            queryOptions: queryOptions,
            options: options
        ) {
            try await fetch(initialInput, initialPageValue)
        }
    }

    /// Starts observing the current input and page with the provided client.
    public func start(using client: QueryClient) {
        queryState.start(using: client)
    }

    /// Stops observing query publications and cancels active refetch triggers.
    public func stop() {
        queryState.stop()
    }

    /// Fetches the current input and page again with the provided client.
    public func refetch(using client: QueryClient) {
        queryState.refetch(using: client)
    }

    /// Sets a new input and resets the page to `initialPage`.
    public func setInput(_ input: Input, using client: QueryClient) {
        self.input = input
        page = initialPage
        updateQuery(using: client)
    }

    /// Sets the current page parameter.
    public func setPage(_ page: Page, using client: QueryClient) {
        self.page = page
        updateQuery(using: client)
    }

    /// Advances to the next page parameter.
    public func nextPage(using client: QueryClient) {
        setPage(nextPageValue(page), using: client)
    }

    /// Moves to the previous page parameter.
    public func previousPage(using client: QueryClient) {
        guard canMoveToPreviousPage(page) else {
            return
        }

        setPage(previousPageValue(page), using: client)
    }

    private func updateQuery(using client: QueryClient) {
        let currentInput = input
        let currentPage = page
        let fetch = fetch
        queryState.update(key: keyBuilder(currentInput, currentPage), using: client) {
            try await fetch(currentInput, currentPage)
        }
    }
}
