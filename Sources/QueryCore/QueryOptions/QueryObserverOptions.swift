import Foundation

/// Subscriber and UI binding options for observing query state.
///
/// `QueryObserverOptions` stay independent per subscriber. Core subscriptions
/// only register listeners and deliver current values; UI adapters use these
/// options to decide when to request fetches.
public struct QueryObserverOptions: Sendable, Equatable {
    /// The default query observer options.
    public static let `default` = QueryObserverOptions()

    /// A Boolean value indicating whether the observer may trigger fetches.
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

    /// Creates query observer options.
    ///
    /// - Parameters:
    ///   - enabled: Whether the observer may trigger fetches.
    ///   - placeholderData: Placeholder behavior while fetching new data.
    ///   - refetchOnSubscribe: Refetch policy when an observer subscribes.
    ///   - refetchOnSceneActive: Refetch policy when the app scene becomes active.
    ///   - refetchOnNetworkReconnect: Refetch policy when network connectivity returns.
    ///   - refetchInterval: Interval, in seconds, for periodic refetches.
    public init(
        enabled: Bool = true,
        placeholderData: PlaceholderData = .none,
        refetchOnSubscribe: RefetchTrigger = .ifStale,
        refetchOnSceneActive: RefetchTrigger = .ifStale,
        refetchOnNetworkReconnect: RefetchTrigger = .ifStale,
        refetchInterval: TimeInterval? = nil
    ) {
        self.enabled = enabled
        self.placeholderData = placeholderData
        self.refetchOnSubscribe = refetchOnSubscribe
        self.refetchOnSceneActive = refetchOnSceneActive
        self.refetchOnNetworkReconnect = refetchOnNetworkReconnect
        self.refetchInterval = refetchInterval
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
