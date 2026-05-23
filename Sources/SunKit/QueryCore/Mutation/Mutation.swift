/// A typed mutation declaration.
///
/// `Mutation` describes work that changes remote state, such as creating or
/// updating a server resource. It does not invalidate queries automatically;
/// call `QueryClient` cache APIs explicitly from callbacks or after mutation
/// success.
public struct Mutation<Input: Sendable, Output: Sendable>: Sendable {
    /// Options that control mutation execution and lifecycle callbacks.
    public let options: MutationOptions<Input, Output>

    internal let run: @Sendable (Input) async throws -> Output

    /// Creates a mutation from an async throwing operation.
    ///
    /// - Parameters:
    ///   - options: Execution options and lifecycle callbacks for the mutation.
    ///   - run: The async operation that performs the mutation.
    public init(
        options: MutationOptions<Input, Output> = .default,
        run: @escaping @Sendable (Input) async throws -> Output
    ) {
        self.options = options
        self.run = run
    }

    /// Creates a mutation from a completion-based operation.
    ///
    /// The completion must be called exactly once. Cancellation of the
    /// underlying completion operation is intentionally not defined by Core.
    ///
    /// - Parameters:
    ///   - options: Execution options and lifecycle callbacks for the mutation.
    ///   - run: A completion-based operation that performs the mutation.
    public init(
        options: MutationOptions<Input, Output> = .default,
        run: @escaping @Sendable (
            Input,
            @escaping @Sendable (Result<Output, Error>) -> Void
        ) -> Void
    ) {
        self.options = options
        self.run = { input in
            try await withCheckedThrowingContinuation { continuation in
                run(input) { result in
                    continuation.resume(with: result)
                }
            }
        }
    }
}
