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
    /// garbage collection may remove it.
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
