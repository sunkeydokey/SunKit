import Observation
import SwiftUI
import SunKit

// MARK: - InfiniteQueryObject

/// A SwiftUI property wrapper that owns an ``InfiniteQueryState`` engine.
@propertyWrapper
public struct InfiniteQueryObject<PageParam: Sendable, Page: Sendable, SelectedValue: Sendable>: DynamicProperty {
    @State private var state: InfiniteQueryState<PageParam, Page, SelectedValue>

    /// The underlying infinite query state.
    public var wrappedValue: InfiniteQueryState<PageParam, Page, SelectedValue> { state }

    /// A binding used by ``View/infiniteQuery(_:key:initialPageParam:enabled:getNextPageParam:fetchPage:)``.
    public var projectedValue: InfiniteQueryObjectBinding<PageParam, Page, SelectedValue> {
        InfiniteQueryObjectBinding(state: state)
    }

    /// Creates an infinite query object with static observer options.
    @MainActor
    public init(options: QueryObserverOptions<InfiniteData<PageParam, Page>, SelectedValue>) {
        _state = State(initialValue: InfiniteQueryState(options: options))
    }
}

public extension InfiniteQueryObject where SelectedValue == InfiniteData<PageParam, Page> {
    /// Creates an infinite query object that exposes accumulated raw data.
    @MainActor
    init() {
        self.init(options: .default)
    }
}

/// A binding between ``InfiniteQueryObject`` and the `.infiniteQuery` view modifier.
public struct InfiniteQueryObjectBinding<PageParam: Sendable, Page: Sendable, SelectedValue: Sendable> {
    private let state: InfiniteQueryState<PageParam, Page, SelectedValue>

    init(state: InfiniteQueryState<PageParam, Page, SelectedValue>) {
        self.state = state
    }

    @MainActor
    func apply(
        query: InfiniteQuery<PageParam, Page>,
        using client: QueryClient,
        enabled: Bool
    ) {
        state.update(query: query, using: client, enabled: enabled)
    }

    @MainActor
    func stop() {
        state.stop()
    }
}

private struct InfiniteQueryObjectModifier<PageParam: Sendable, Page: Sendable, SelectedValue: Sendable>: ViewModifier {
    let binding: InfiniteQueryObjectBinding<PageParam, Page, SelectedValue>
    let key: [AnyQueryKeyPart]
    let initialPageParam: PageParam
    let queryOptions: QueryOptions?
    let enabled: Bool
    let getNextPageParam: @Sendable (Page, [Page]) -> PageParam?
    let fetchPage: @Sendable (PageParam) async throws -> Page

    @Environment(\.queryClient) private var client

    private var token: InfiniteQueryObjectToken<PageParam, Page> {
        InfiniteQueryObjectToken(key: QueryKey(key), enabled: enabled)
    }

    func body(content: Content) -> some View {
        content
            .onAppear {
                apply()
            }
            .onDisappear {
                binding.stop()
            }
            .onChange(of: token) { _, _ in
                apply()
            }
    }

    private func apply() {
        let query = InfiniteQuery(
            key: key,
            initialPageParam: initialPageParam,
            options: queryOptions,
            getNextPageParam: getNextPageParam,
            fetchPage: fetchPage
        )
        binding.apply(query: query, using: client, enabled: enabled)
    }
}

private struct InfiniteQueryObjectToken<PageParam: Sendable, Page: Sendable>: Equatable {
    let key: QueryKey<InfiniteData<PageParam, Page>>
    let enabled: Bool
}

// MARK: - PaginatedQueryObject

/// A SwiftUI property wrapper that owns a ``PaginatedQueryState`` engine.
@propertyWrapper
public struct PaginatedQueryObject<Input: Hashable & Sendable, Page: Sendable, RawValue: Sendable, SelectedValue: Sendable>: DynamicProperty {
    @State private var state: PaginatedQueryState<Input, Page, RawValue, SelectedValue>

    /// The underlying paginated query state.
    public var wrappedValue: PaginatedQueryState<Input, Page, RawValue, SelectedValue> { state }

    /// A binding used by ``View/paginatedQuery(_:input:enabled:key:fetch:)``.
    public var projectedValue: PaginatedQueryObjectBinding<Input, Page, RawValue, SelectedValue> {
        PaginatedQueryObjectBinding(state: state)
    }

    /// Creates a paginated query object with static page navigation and observer options.
    @MainActor
    public init(
        initialInput: Input,
        initialPage: Page,
        queryOptions: QueryOptions? = nil,
        options: QueryObserverOptions<RawValue, SelectedValue>,
        nextPage: @escaping @Sendable (Page) -> Page,
        previousPage: @escaping @Sendable (Page) -> Page,
        canMoveToPreviousPage: @escaping @Sendable (Page) -> Bool
    ) {
        _state = State(
            initialValue: PaginatedQueryState(
                placeholderInput: initialInput,
                initialPage: initialPage,
                queryOptions: queryOptions,
                options: options,
                nextPage: nextPage,
                previousPage: previousPage,
                canMoveToPreviousPage: canMoveToPreviousPage
            )
        )
    }
}

public extension PaginatedQueryObject where RawValue == SelectedValue {
    /// Creates a paginated query object that exposes the raw cached value.
    @MainActor
    init(
        initialInput: Input,
        initialPage: Page,
        queryOptions: QueryOptions? = nil,
        nextPage: @escaping @Sendable (Page) -> Page,
        previousPage: @escaping @Sendable (Page) -> Page,
        canMoveToPreviousPage: @escaping @Sendable (Page) -> Bool
    ) {
        self.init(
            initialInput: initialInput,
            initialPage: initialPage,
            queryOptions: queryOptions,
            options: .default,
            nextPage: nextPage,
            previousPage: previousPage,
            canMoveToPreviousPage: canMoveToPreviousPage
        )
    }
}

/// A binding between ``PaginatedQueryObject`` and the `.paginatedQuery` view modifier.
public struct PaginatedQueryObjectBinding<Input: Hashable & Sendable, Page: Sendable, RawValue: Sendable, SelectedValue: Sendable> {
    private let state: PaginatedQueryState<Input, Page, RawValue, SelectedValue>

    init(state: PaginatedQueryState<Input, Page, RawValue, SelectedValue>) {
        self.state = state
    }

    @MainActor
    var page: Page {
        state.page
    }

    @MainActor
    func apply(
        input: Input,
        using client: QueryClient,
        key: @escaping @Sendable (Input, Page) -> [AnyQueryKeyPart],
        fetch: @escaping @Sendable (Input, Page) async throws -> RawValue,
        enabled: Bool
    ) {
        state.update(input: input, using: client, key: key, fetch: fetch, enabled: enabled)
    }

    @MainActor
    func stop() {
        state.stop()
    }
}

private struct PaginatedQueryObjectModifier<Input: Hashable & Sendable, Page: Sendable, RawValue: Sendable, SelectedValue: Sendable>: ViewModifier {
    let binding: PaginatedQueryObjectBinding<Input, Page, RawValue, SelectedValue>
    let input: Input
    let enabled: Bool
    let key: @Sendable (Input, Page) -> [AnyQueryKeyPart]
    let fetch: @Sendable (Input, Page) async throws -> RawValue

    @Environment(\.queryClient) private var client

    private var token: PaginatedQueryObjectToken<RawValue> {
        PaginatedQueryObjectToken(key: QueryKey(key(input, binding.page)), input: AnyQueryKeyPart(input), enabled: enabled)
    }

    func body(content: Content) -> some View {
        content
            .onAppear {
                apply()
            }
            .onDisappear {
                binding.stop()
            }
            .onChange(of: token) { _, _ in
                apply()
            }
    }

    private func apply() {
        binding.apply(input: input, using: client, key: key, fetch: fetch, enabled: enabled)
    }
}

private struct PaginatedQueryObjectToken<Value: Sendable>: Equatable {
    let key: QueryKey<Value>
    let input: AnyQueryKeyPart
    let enabled: Bool
}

// MARK: - ParallelQueriesObject

/// Observable state for one-shot parallel query batches.
@MainActor
@Observable
public final class ParallelQueriesState {
    /// The latest batch results, if any.
    public private(set) var result: ParallelQueryResults?

    /// A Boolean value indicating whether a batch is running.
    public private(set) var isFetching = false

    @ObservationIgnored nonisolated(unsafe) private var task: Task<Void, Never>?
    @ObservationIgnored nonisolated(unsafe) private var generation: UInt64 = 0

    /// Creates empty parallel query state.
    public init() {}

    deinit {
        task?.cancel()
    }

    /// Runs a parallel query batch with the provided client.
    public func run(_ queries: [AnyParallelQuery], using client: QueryClient) {
        generation += 1
        let gen = generation
        task?.cancel()
        isFetching = true
        task = Task {
            let result = await client.fetchQueries(queries)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard self.generation == gen else { return }
                self.result = result
                self.isFetching = false
            }
        }
    }

    /// Cancels the current batch owned by this state object.
    public func cancel() {
        generation += 1
        task?.cancel()
        task = nil
        isFetching = false
    }
}

/// A SwiftUI property wrapper that owns ``ParallelQueriesState``.
@propertyWrapper
public struct ParallelQueriesObject: DynamicProperty {
    @State private var state: ParallelQueriesState

    /// The underlying parallel queries state.
    public var wrappedValue: ParallelQueriesState { state }

    /// A binding used by ``View/parallelQueries(_:queries:token:enabled:)``.
    public var projectedValue: ParallelQueriesObjectBinding {
        ParallelQueriesObjectBinding(state: state)
    }

    /// Creates a parallel queries object.
    @MainActor
    public init() {
        _state = State(initialValue: ParallelQueriesState())
    }
}

/// A binding between ``ParallelQueriesObject`` and the `.parallelQueries` view modifier.
public struct ParallelQueriesObjectBinding {
    private let state: ParallelQueriesState

    init(state: ParallelQueriesState) {
        self.state = state
    }

    @MainActor
    func run(_ queries: [AnyParallelQuery], using client: QueryClient, enabled: Bool) {
        if enabled {
            state.run(queries, using: client)
        } else {
            state.cancel()
        }
    }

    @MainActor
    func cancel() {
        state.cancel()
    }
}

private struct ParallelQueriesObjectModifier<Token: Hashable & Sendable>: ViewModifier {
    let binding: ParallelQueriesObjectBinding
    let queries: [AnyParallelQuery]
    let token: Token
    let enabled: Bool

    @Environment(\.queryClient) private var client

    private var changeToken: ParallelQueriesObjectToken<Token> {
        ParallelQueriesObjectToken(token: token, enabled: enabled)
    }

    func body(content: Content) -> some View {
        content
            .onAppear {
                apply()
            }
            .onDisappear {
                binding.cancel()
            }
            .onChange(of: changeToken) { _, _ in
                apply()
            }
    }

    private func apply() {
        binding.run(queries, using: client, enabled: enabled)
    }
}

private struct ParallelQueriesObjectToken<Token: Hashable & Sendable>: Equatable {
    let token: Token
    let enabled: Bool
}

public extension View {
    /// Configures and starts an infinite query object from values available in `body`.
    func infiniteQuery<PageParam: Sendable, Page: Sendable, SelectedValue: Sendable>(
        _ query: InfiniteQueryObjectBinding<PageParam, Page, SelectedValue>,
        key: [AnyQueryKeyPart],
        initialPageParam: PageParam,
        queryOptions: QueryOptions? = nil,
        enabled: Bool = true,
        getNextPageParam: @escaping @Sendable (Page, [Page]) -> PageParam?,
        fetchPage: @escaping @Sendable (PageParam) async throws -> Page
    ) -> some View {
        modifier(
            InfiniteQueryObjectModifier(
                binding: query,
                key: key,
                initialPageParam: initialPageParam,
                queryOptions: queryOptions,
                enabled: enabled,
                getNextPageParam: getNextPageParam,
                fetchPage: fetchPage
            )
        )
    }

    /// Configures and starts a paginated query object from values available in `body`.
    func paginatedQuery<Input: Hashable & Sendable, Page: Sendable, RawValue: Sendable, SelectedValue: Sendable>(
        _ query: PaginatedQueryObjectBinding<Input, Page, RawValue, SelectedValue>,
        input: Input,
        enabled: Bool = true,
        key: @escaping @Sendable (Input, Page) -> [AnyQueryKeyPart],
        fetch: @escaping @Sendable (Input, Page) async throws -> RawValue
    ) -> some View {
        modifier(
            PaginatedQueryObjectModifier(
                binding: query,
                input: input,
                enabled: enabled,
                key: key,
                fetch: fetch
            )
        )
    }

    /// Configures and runs a one-shot parallel query batch.
    func parallelQueries<Token: Hashable & Sendable>(
        _ queriesState: ParallelQueriesObjectBinding,
        queries: [AnyParallelQuery],
        token: Token,
        enabled: Bool = true
    ) -> some View {
        modifier(
            ParallelQueriesObjectModifier(
                binding: queriesState,
                queries: queries,
                token: token,
                enabled: enabled
            )
        )
    }
}
