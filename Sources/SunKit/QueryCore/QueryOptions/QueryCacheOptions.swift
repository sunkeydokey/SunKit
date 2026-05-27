import Foundation

/// Cache lifecycle options for a query.
///
/// `QueryCacheOptions` describe when cached data becomes stale and how long
/// inactive query data remains eligible to stay in memory.
public struct QueryCacheOptions: Sendable, Equatable {
    /// The default query cache options.
    public static let `default` = QueryCacheOptions()

    /// The number of seconds data remains fresh after a successful fetch.
    public var staleTime: TimeInterval

    /// The number of seconds inactive query data remains in cache before
    /// garbage collection removes it.
    ///
    /// The timer starts when the last subscriber unsubscribes. If a new
    /// subscriber arrives before the timer fires, the timer is cancelled and
    /// the entry remains cached. A value of `0` removes the entry immediately
    /// after the last subscriber leaves.
    ///
    /// When observers provide per-observer cache options, the last subscriber's
    /// `gcTime` is used when the entry becomes inactive.
    public var gcTime: TimeInterval

    /// Creates query cache lifecycle options.
    ///
    /// - Parameters:
    ///   - staleTime: The number of seconds data remains fresh.
    ///   - gcTime: The number of seconds inactive data remains cached.
    public init(staleTime: TimeInterval = 0, gcTime: TimeInterval = 300) {
        self.staleTime = staleTime
        self.gcTime = gcTime
    }
}
