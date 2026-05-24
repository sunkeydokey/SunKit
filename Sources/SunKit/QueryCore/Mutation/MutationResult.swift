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

    /// A Boolean value indicating whether no mutation has run yet.
    public let isIdle: Bool

    /// A Boolean value indicating whether the mutation is running.
    public let isPending: Bool

    /// A Boolean value indicating whether the mutation succeeded.
    public let isSuccess: Bool

    /// A Boolean value indicating whether the mutation failed.
    public let isError: Bool

    /// The failure count represented by this result.
    ///
    /// `MutationState` uses this value only to mark a failed execution and
    /// does not expose retry-attempt counts. Check `isError` and `error` when
    /// rendering mutation failures.
    public let failureCount: Int

    /// Creates a mutation result from a status.
    ///
    /// - Parameters:
    ///   - status: The mutation lifecycle status.
    ///   - failureCount: The failure count for failed results. UI adapters may
    ///     use `1` as the minimum failed-execution marker instead of reporting
    ///     retry-attempt counts.
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
            self.isIdle = true
            self.isPending = false
            self.isSuccess = false
            self.isError = false

        case .pending:
            self.data = nil
            self.error = nil
            self.isIdle = false
            self.isPending = true
            self.isSuccess = false
            self.isError = false

        case let .success(output):
            self.data = output
            self.error = nil
            self.isIdle = false
            self.isPending = false
            self.isSuccess = true
            self.isError = false

        case let .failure(error):
            self.data = nil
            self.error = error
            self.isIdle = false
            self.isPending = false
            self.isSuccess = false
            self.isError = true
        }
    }
}
