import Foundation

/// Subscriber and UI binding options for observing query state.
///
/// `QueryObserverOptions` stay independent per subscriber. Core subscriptions
/// only register listeners and deliver current values; UI adapters use these
/// options to decide when to request fetches and how to project cached values.
public struct QueryObserverOptions<RawValue: Sendable, SelectedValue: Sendable>: Sendable {
    /// A Boolean value that controls whether this observer automatically triggers fetches.
    ///
    /// When `false`, the observer still subscribes to cache publications — data
    /// pushed by other observers is received — but the following automatic fetch
    /// triggers are suppressed:
    /// - Initial fetch on subscribe (`refetchOnSubscribe`)
    /// - Scene-active refetch (`refetchOnSceneActive`)
    /// - Network-reconnect refetch (`refetchOnNetworkReconnect`)
    /// - Periodic polling (`refetchInterval`)
    ///
    /// Explicit calls to ``QueryState/refetch(using:)`` are not affected by this flag.
    ///
    /// To change `enabled` at runtime, pass the new value to
    /// ``QueryState/update(key:using:fetch:enabled:)``. A `false` to `true`
    /// transition triggers an initial fetch according to `refetchOnSubscribe`
    /// and re-arms all active refetch triggers. A `true` to `false` transition
    /// disarms interval, scene-active, and network-reconnect triggers immediately.
    public var enabled: Bool

    /// The placeholder data behavior used while fetching new data.
    public var placeholderData: PlaceholderData

    /// The refetch policy applied when an observer subscribes.
    public var refetchOnSubscribe: RefetchTrigger

    /// The refetch policy applied when the app scene becomes active.
    public var refetchOnSceneActive: RefetchTrigger

    /// The refetch policy applied when network connectivity returns.
    public var refetchOnNetworkReconnect: RefetchTrigger

    /// The interval, in seconds, for periodic refetches.
    public var refetchInterval: TimeInterval?

    /// Transforms cached raw data into the value exposed by this observer.
    ///
    /// The transform is observer-local. It does not change cache identity,
    /// in-flight deduplication, invalidation, or the raw value stored by
    /// `QueryClient`.
    public var select: @Sendable (RawValue) -> SelectedValue

    /// Creates query observer options.
    ///
    /// - Parameters:
    ///   - enabled: Whether the observer automatically triggers fetches. See ``enabled`` for full semantics.
    ///   - placeholderData: Placeholder behavior while fetching new data.
    ///   - refetchOnSubscribe: Refetch policy when an observer subscribes.
    ///   - refetchOnSceneActive: Refetch policy when the app scene becomes active.
    ///   - refetchOnNetworkReconnect: Refetch policy when network connectivity returns.
    ///   - refetchInterval: Interval, in seconds, for periodic refetches.
    ///   - select: Observer-local transform from raw cached data to exposed data.
    public init(
        enabled: Bool = true,
        placeholderData: PlaceholderData = .none,
        refetchOnSubscribe: RefetchTrigger = .ifStale,
        refetchOnSceneActive: RefetchTrigger = .ifStale,
        refetchOnNetworkReconnect: RefetchTrigger = .ifStale,
        refetchInterval: TimeInterval? = nil,
        select: @escaping @Sendable (RawValue) -> SelectedValue
    ) {
        self.enabled = enabled
        self.placeholderData = placeholderData
        self.refetchOnSubscribe = refetchOnSubscribe
        self.refetchOnSceneActive = refetchOnSceneActive
        self.refetchOnNetworkReconnect = refetchOnNetworkReconnect
        self.refetchInterval = refetchInterval
        self.select = select
    }
}

public extension QueryObserverOptions where RawValue == SelectedValue {
    /// The default query observer options.
    static var `default`: QueryObserverOptions<RawValue, SelectedValue> {
        QueryObserverOptions()
    }

    /// Creates identity query observer options.
    ///
    /// The observer exposes the same value type stored in the cache.
    ///
    /// - Parameters:
    ///   - enabled: Whether the observer automatically triggers fetches. See ``enabled`` for full semantics.
    ///   - placeholderData: Placeholder behavior while fetching new data.
    ///   - refetchOnSubscribe: Refetch policy when an observer subscribes.
    ///   - refetchOnSceneActive: Refetch policy when the app scene becomes active.
    ///   - refetchOnNetworkReconnect: Refetch policy when network connectivity returns.
    ///   - refetchInterval: Interval, in seconds, for periodic refetches.
    init(
        enabled: Bool = true,
        placeholderData: PlaceholderData = .none,
        refetchOnSubscribe: RefetchTrigger = .ifStale,
        refetchOnSceneActive: RefetchTrigger = .ifStale,
        refetchOnNetworkReconnect: RefetchTrigger = .ifStale,
        refetchInterval: TimeInterval? = nil
    ) {
        self.init(
            enabled: enabled,
            placeholderData: placeholderData,
            refetchOnSubscribe: refetchOnSubscribe,
            refetchOnSceneActive: refetchOnSceneActive,
            refetchOnNetworkReconnect: refetchOnNetworkReconnect,
            refetchInterval: refetchInterval,
            select: { $0 }
        )
    }
}

/// Placeholder data behavior for query observers.
public enum PlaceholderData: Sendable, Equatable {
    /// Do not expose placeholder data.
    case none

    /// Keep the previous data available as placeholder data while fetching.
    case keepPreviousData
}

/// A policy that determines whether an observer event should trigger refetch.
public enum RefetchTrigger: Sendable, Equatable {
    /// Never refetch for the observer event.
    case never

    /// Refetch for the observer event only when cached data is stale.
    case ifStale

    /// Always refetch for the observer event.
    case always
}
