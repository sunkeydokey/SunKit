/// The lifecycle status of a mutation result.
public enum MutationStatus<Output: Sendable>: Sendable {
    /// No mutation is currently running and no result is available.
    case idle

    /// A mutation is currently running.
    case pending

    /// The mutation completed successfully.
    case success(Output)

    /// The mutation failed after retries were exhausted.
    case failure(Error)
}

/// A snapshot of a mutation's observable state.
///
/// Core mutation execution returns values or throws through `QueryClient`.
/// `MutationResult` is provided for UI adapters and other state holders that
/// need a common representation of mutation lifecycle.
public struct MutationResult<Output: Sendable>: Sendable {
    /// The lifecycle status that produced this result.
    public let status: MutationStatus<Output>

    /// The mutation output when the result is successful.
    public let data: Output?

    /// The mutation error when the result is failed.
    public let error: Error?

    /// A Boolean value indicating whether the mutation is running.
    public let isPending: Bool

    /// A Boolean value indicating whether the mutation succeeded.
    public let isSuccess: Bool

    /// A Boolean value indicating whether the mutation failed.
    public let isError: Bool

    /// The consecutive failure count represented by this result.
    public let failureCount: Int

    /// Creates a mutation result from a status.
    ///
    /// - Parameters:
    ///   - status: The mutation lifecycle status.
    ///   - failureCount: The failure count for failed results.
    public init(status: MutationStatus<Output>, failureCount: Int = 0) {
        if case .failure = status {
            precondition(failureCount > 0, "failureCount must be greater than zero for failed mutation results.")
        } else {
            precondition(failureCount == 0, "failureCount must be zero unless the mutation result failed.")
        }

        self.status = status
        self.failureCount = failureCount

        switch status {
        case .idle:
            self.data = nil
            self.error = nil
            self.isPending = false
            self.isSuccess = false
            self.isError = false

        case .pending:
            self.data = nil
            self.error = nil
            self.isPending = true
            self.isSuccess = false
            self.isError = false

        case let .success(output):
            self.data = output
            self.error = nil
            self.isPending = false
            self.isSuccess = true
            self.isError = false

        case let .failure(error):
            self.data = nil
            self.error = error
            self.isPending = false
            self.isSuccess = false
            self.isError = true
        }
    }
}
