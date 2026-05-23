import Foundation

/// Fetch execution options for a query.
///
/// `QueryOptions` belong to a query execution. During in-flight deduplication,
/// the options from the first request for a key are the options that apply to
/// the shared execution.
public struct QueryOptions: Sendable, Equatable {
    /// The default query execution options.
    public static let `default` = QueryOptions()

    /// The retry policy used after failed fetch attempts.
    public var retry: RetryPolicy

    /// The delay policy used between retry attempts.
    public var retryDelay: RetryDelay

    /// Creates query execution options.
    ///
    /// - Parameters:
    ///   - retry: The retry policy used after failed fetch attempts.
    ///   - retryDelay: The delay policy used between retry attempts.
    public init(
        retry: RetryPolicy = .count(3),
        retryDelay: RetryDelay = .exponential(maxDelay: 30)
    ) {
        self.retry = retry
        self.retryDelay = retryDelay
    }
}

/// A retry policy for failed query executions.
public enum RetryPolicy: Sendable, Equatable {
    /// Never retry a failed execution.
    case never

    /// Retry a failed execution up to `count` times.
    case count(Int)
}

/// A delay policy for retry attempts.
public enum RetryDelay: Sendable, Equatable {
    /// Retry immediately without waiting.
    case none

    /// Wait a fixed number of seconds between retry attempts.
    case fixed(TimeInterval)

    /// Use exponential backoff capped at `maxDelay` seconds.
    case exponential(maxDelay: TimeInterval)
}
