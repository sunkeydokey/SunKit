import Observation
import SunKit

/// Observable SwiftUI state for a SunKit mutation.
///
/// Store `MutationState` in SwiftUI with `@State`, then call
/// ``mutate(_:using:)`` to execute the mutation. State transitions from idle
/// to pending, then to success or failure, and publishes each change on the
/// main actor.
@MainActor
@Observable
public final class MutationState<Input: Sendable, Output: Sendable> {
    /// The latest mutation result.
    public private(set) var result: MutationResult<Output> = MutationResult(status: .idle)

    /// The mutation output when the last mutation succeeded.
    public var data: Output? { result.data }

    /// The mutation error when the last mutation failed.
    public var error: Error? { result.error }

    /// A Boolean value indicating whether a mutation is running.
    public var isPending: Bool { result.isPending }

    /// A Boolean value indicating whether the last mutation succeeded.
    public var isSuccess: Bool { result.isSuccess }

    /// A Boolean value indicating whether the last mutation failed.
    public var isError: Bool { result.isError }

    /// The mutation declaration to execute.
    private let mutation: Mutation<Input, Output>

    @ObservationIgnored private var task: Task<Void, Never>?

    /// Creates observable mutation state for the given mutation.
    ///
    /// - Parameter mutation: The mutation declaration to execute.
    public init(mutation: Mutation<Input, Output>) {
        self.mutation = mutation
    }

    deinit {
        task?.cancel()
    }

    /// Executes the mutation with the provided input and client.
    ///
    /// Cancels any in-flight mutation before starting a new one. State
    /// transitions from idle to pending, then to success or failure.
    ///
    /// - Parameters:
    ///   - input: The input to pass to the mutation.
    ///   - client: The `QueryClient` used to run the mutation.
    public func mutate(_ input: Input, using client: QueryClient) {
        task?.cancel()
        result = MutationResult(status: .pending)
        task = Task { [weak self] in
            guard let self else { return }

            do {
                let output = try await client.mutate(mutation, input: input)
                guard !Task.isCancelled else { return }
                result = MutationResult(status: .success(output))
            } catch {
                guard !Task.isCancelled else { return }
                result = MutationResult(status: .failure(error), failureCount: 1)
            }
        }
    }

    /// Resets the mutation state back to idle.
    public func reset() {
        task?.cancel()
        task = nil
        result = MutationResult(status: .idle)
    }
}
