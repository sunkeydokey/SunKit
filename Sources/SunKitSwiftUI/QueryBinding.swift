import SwiftUI
import SunKit

private struct UnconfiguredQueryBindingError: Error {}

/// A SwiftUI property wrapper that owns a ``QueryState`` engine.
///
/// `QueryBinding` keeps query state stable across SwiftUI renders while a
/// ``View/query(_:key:enabled:fetch:)`` modifier supplies the dynamic key,
/// enabled flag, and fetcher from `body`.
@propertyWrapper
public struct QueryBinding<RawValue: Sendable, SelectedValue: Sendable>: DynamicProperty {
    @State private var state: QueryState<RawValue, SelectedValue>

    /// The underlying query state.
    public var wrappedValue: QueryState<RawValue, SelectedValue> { state }

    /// A binding used by ``View/query(_:key:enabled:fetch:)`` to configure the
    /// underlying query state from `body`.
    public var projectedValue: QueryBindingHandle<RawValue, SelectedValue> {
        QueryBindingHandle(state: state)
    }

    /// Creates a query binding with static query, cache, and observer options.
    ///
    /// `enabled` can still change dynamically through
    /// ``View/query(_:key:enabled:fetch:)``. Other observer options are fixed
    /// for the lifetime of the stored query state.
    ///
    /// - Parameters:
    ///   - queryOptions: Execution options for fetches, or `nil` to use the
    ///     executing client's defaults.
    ///   - cacheOptions: Per-observer cache lifecycle options, or `nil` to use
    ///     the executing client's defaults.
    ///   - options: Observer options used by the underlying state.
    @MainActor
    public init(
        queryOptions: QueryOptions? = nil,
        cacheOptions: QueryCacheOptions? = nil,
        options: QueryObserverOptions<RawValue, SelectedValue>
    ) {
        _state = State(
            initialValue: QueryState(
                key: [],
                queryOptions: queryOptions,
                cacheOptions: cacheOptions,
                options: options,
                fetch: { throw UnconfiguredQueryBindingError() }
            )
        )
    }
}

public extension QueryBinding where RawValue == SelectedValue {
    /// Creates a query binding that exposes the raw cached value.
    @MainActor
    init(
        queryOptions: QueryOptions? = nil,
        cacheOptions: QueryCacheOptions? = nil
    ) {
        self.init(queryOptions: queryOptions, cacheOptions: cacheOptions, options: .default)
    }
}

/// A binding between ``QueryBinding`` and the `.query` view modifier.
public struct QueryBindingHandle<RawValue: Sendable, SelectedValue: Sendable> {
    private let state: QueryState<RawValue, SelectedValue>

    init(state: QueryState<RawValue, SelectedValue>) {
        self.state = state
    }

    @MainActor
    func apply(
        key: [AnyQueryKeyPart],
        using client: QueryClient,
        fetch: @escaping @Sendable () async throws -> RawValue,
        enabled: Bool
    ) {
        state.update(key: key, using: client, fetch: fetch, enabled: enabled)
    }

    @MainActor
    func stop() {
        state.stop()
    }
}

private struct QueryBindingModifier<RawValue: Sendable, SelectedValue: Sendable>: ViewModifier {
    let binding: QueryBindingHandle<RawValue, SelectedValue>
    let key: [AnyQueryKeyPart]
    let enabled: Bool
    let fetch: @Sendable () async throws -> RawValue

    @Environment(\.queryClient) private var client

    private var token: QueryBindingToken<RawValue> {
        QueryBindingToken(key: QueryKey(key), enabled: enabled)
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
        binding.apply(key: key, using: client, fetch: fetch, enabled: enabled)
    }
}

private struct QueryBindingToken<Value: Sendable>: Equatable {
    let key: QueryKey<Value>
    let enabled: Bool
}

public extension View {
    /// Configures and starts a query binding from values available in `body`.
    ///
    /// Use this modifier when a query key or fetcher depends on state owned by
    /// the same view. The modifier reads `\.queryClient`, updates the stored
    /// ``QueryState`` on appearance and when the key or enabled flag changes,
    /// and stops the state on disappearance.
    ///
    /// ```swift
    /// @QueryBinding(options: QueryObserverOptions(refetchOnSubscribe: .always))
    /// private var followers: QueryState<[GitHubUser], [GitHubUser]>
    ///
    /// var body: some View {
    ///     List(followers.result?.data ?? []) { user in
    ///         FollowerRow(user: user)
    ///     }
    ///     .query($followers, key: ["followers", AnyQueryKeyPart(username)]) {
    ///         try await api.followers(username)
    ///     }
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - query: A projected ``QueryBinding`` value.
    ///   - key: Cache identity parts to observe and fetch.
    ///   - enabled: Whether automatic fetch triggers are enabled.
    ///   - fetch: Async operation that loads the raw query value.
    func query<RawValue: Sendable, SelectedValue: Sendable>(
        _ query: QueryBindingHandle<RawValue, SelectedValue>,
        key: [AnyQueryKeyPart],
        enabled: Bool = true,
        fetch: @escaping @Sendable () async throws -> RawValue
    ) -> some View {
        modifier(
            QueryBindingModifier(
                binding: query,
                key: key,
                enabled: enabled,
                fetch: fetch
            )
        )
    }
}
