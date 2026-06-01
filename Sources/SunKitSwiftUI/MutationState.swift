import Observation
import SwiftUI
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
    @ObservationIgnored nonisolated(unsafe) private var currentClient: QueryClient?

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
        currentClient = client
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

    /// Executes the mutation with the client most recently supplied by
    /// ``MutationBinding`` or ``mutate(_:using:)``.
    ///
    /// Use this overload when the state is owned by ``MutationBinding`` and
    /// the `QueryClient` comes from the SwiftUI environment.
    ///
    /// - Parameter input: The input to pass to the mutation.
    public func mutate(_ input: Input) {
        guard let currentClient else {
            assertionFailure("MutationState.mutate(_:) requires @MutationBinding or mutate(_:using:) to supply a QueryClient first.")
            return
        }

        mutate(input, using: currentClient)
    }

    /// Resets the mutation state back to idle.
    public func reset() {
        task?.cancel()
        task = nil
        result = MutationResult(status: .idle)
    }

    nonisolated func setClient(_ client: QueryClient) {
        currentClient = client
    }
}

/// A SwiftUI property wrapper that owns a ``MutationState`` engine.
///
/// `MutationBinding` keeps mutation state stable across SwiftUI renders and
/// reads the current ``QueryClient`` from the SwiftUI environment so user
/// actions can call ``MutationState/mutate(_:)`` without passing a client
/// explicitly.
@propertyWrapper
public struct MutationBinding<Input: Sendable, Output: Sendable>: DynamicProperty {
    @State private var state: MutationState<Input, Output>
    @Environment(\.queryClient) private var client

    /// The underlying mutation state.
    public var wrappedValue: MutationState<Input, Output> { state }

    /// Updates the underlying mutation state with the current environment client.
    public func update() {
        state.setClient(client)
    }

    /// Creates a mutation binding for the given mutation declaration.
    ///
    /// - Parameter mutation: The mutation declaration to execute.
    @MainActor
    public init(mutation: Mutation<Input, Output>) {
        _state = State(initialValue: MutationState(mutation: mutation))
    }

    /// Creates a mutation binding from an async throwing operation.
    ///
    /// - Parameters:
    ///   - options: Execution options and lifecycle callbacks for the mutation.
    ///   - run: The async operation that performs the mutation.
    @MainActor
    public init(
        options: MutationOptions<Input, Output> = .default,
        run: @escaping @Sendable (Input) async throws -> Output
    ) {
        self.init(mutation: Mutation(options: options, run: run))
    }
}
