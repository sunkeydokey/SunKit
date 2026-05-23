/// Execution options and lifecycle callbacks for a mutation.
///
/// Mutation options belong to a single mutation declaration. Unlike query
/// execution, mutation retry is disabled by default.
public struct MutationOptions<Input: Sendable, Output: Sendable>: Sendable {
    /// The default mutation options.
    public static var `default`: Self {
        Self()
    }

    /// The retry policy used after failed mutation attempts.
    public var retry: RetryPolicy

    /// The delay policy used between retry attempts.
    public var retryDelay: RetryDelay

    /// A callback that runs after the mutation operation succeeds.
    public var onSuccess: (@Sendable (Output, Input, QueryClient) async -> Void)?

    /// A callback that runs after the mutation operation fails after retries.
    public var onFailure: (@Sendable (Error, Input, QueryClient) async -> Void)?

    /// A callback that runs after either mutation success or failure.
    public var onSettled: (@Sendable (Result<Output, Error>, Input, QueryClient) async -> Void)?

    /// Creates mutation execution options.
    ///
    /// - Parameters:
    ///   - retry: The retry policy used after failed mutation attempts.
    ///   - retryDelay: The delay policy used between retry attempts.
    ///   - onSuccess: A callback that runs after the mutation succeeds.
    ///   - onFailure: A callback that runs after the mutation fails after retries.
    ///   - onSettled: A callback that runs after success or failure.
    public init(
        retry: RetryPolicy = .never,
        retryDelay: RetryDelay = .none,
        onSuccess: (@Sendable (Output, Input, QueryClient) async -> Void)? = nil,
        onFailure: (@Sendable (Error, Input, QueryClient) async -> Void)? = nil,
        onSettled: (@Sendable (Result<Output, Error>, Input, QueryClient) async -> Void)? = nil
    ) {
        self.retry = retry
        self.retryDelay = retryDelay
        self.onSuccess = onSuccess
        self.onFailure = onFailure
        self.onSettled = onSettled
    }
}
