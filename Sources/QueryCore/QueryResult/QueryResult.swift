import Foundation

internal enum QueryStatus<Value: Sendable>: Sendable {
    case idle
    case pending(previous: Value?)
    case success(Value)
    case failure(Error, stale: Value?, failureCount: Int)
}

/// A read-only snapshot of a query's observable state.
///
/// `QueryResult` values are created by SunKit Core and exposed through APIs
/// such as query fetching and subscriptions. Package users read the public
/// projection properties, but cannot construct arbitrary query results.
public struct QueryResult<Value: Sendable>: Sendable {
    internal let status: QueryStatus<Value>

    /// The latest available data, including stale data when a refetch fails.
    public let data: Value?

    /// The latest error when the query is in an error state.
    public let error: Error?

    /// A Boolean value indicating whether the query is waiting for data.
    public let isPending: Bool

    /// A Boolean value indicating whether the query currently has successful data.
    public let isSuccess: Bool

    /// A Boolean value indicating whether the query is in an error state.
    public let isError: Bool

    /// A Boolean value indicating whether a fetch is currently running.
    public let isFetching: Bool

    /// A Boolean value indicating whether the data should be treated as stale.
    public let isStale: Bool

    /// A Boolean value indicating whether `data` is placeholder data.
    public let isPlaceholderData: Bool

    /// The time when this query result last received data.
    public let updatedAt: Date?

    /// The consecutive failure count for the current failed execution.
    public let failureCount: Int

    internal init(
        status: QueryStatus<Value>,
        isFetching: Bool = false,
        isStale: Bool = false,
        isPlaceholderData: Bool = false,
        updatedAt: Date? = nil
    ) {
        if case let .failure(_, _, failureCount) = status {
            precondition(failureCount > 0, "failureCount must be greater than zero for failed query results.")
        }

        self.status = status
        self.isFetching = isFetching
        self.isStale = isStale
        self.isPlaceholderData = isPlaceholderData
        self.updatedAt = updatedAt

        switch status {
        case .idle:
            self.data = nil
            self.error = nil
            self.isPending = false
            self.isSuccess = false
            self.isError = false
            self.failureCount = 0

        case let .pending(previous):
            self.data = previous
            self.error = nil
            self.isPending = true
            self.isSuccess = false
            self.isError = false
            self.failureCount = 0

        case let .success(data):
            self.data = data
            self.error = nil
            self.isPending = false
            self.isSuccess = true
            self.isError = false
            self.failureCount = 0

        case let .failure(error, stale, failureCount):
            self.data = stale
            self.error = error
            self.isPending = false
            self.isSuccess = false
            self.isError = true
            self.failureCount = failureCount
        }
    }
}
