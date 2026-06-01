import Foundation
import Testing
@testable import SunKit
@testable import SunKitSwiftUI

private enum MutationStateTestError: Error, Equatable {
    case failed
}

private actor MutationStateAttemptCounter {
    private var count = 0

    func next() -> Int {
        count += 1
        return count
    }

    func value() -> Int {
        count
    }
}

private func eventuallyOnMainActor(_ condition: @escaping @MainActor () -> Bool) async -> Bool {
    for _ in 0..<50 {
        if await MainActor.run(body: condition) {
            return true
        }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return false
}

@Test
@MainActor
func mutationStateInitialResultIsIdle() {
    let state = MutationState(mutation: Mutation<Int, String> { input in
        "result-\(input)"
    })

    #expect(state.result.isIdle)
    #expect(state.result.data == nil)
    #expect(state.result.error == nil)
    #expect(!state.result.isPending)
    #expect(!state.result.isSuccess)
    #expect(!state.result.isError)
}

@Test
@MainActor
func mutationStateTransitionsToPendingThenSuccess() async {
    let client = QueryClient()
    let state = MutationState(mutation: Mutation<Int, String> { input in
        "result-\(input)"
    })

    state.mutate(1, using: client)
    #expect(state.result.isPending)

    #expect(await eventuallyOnMainActor { state.result.isSuccess })
    #expect(state.result.data == "result-1")
    #expect(!state.result.isPending)
    #expect(!state.result.isError)
}

@Test
@MainActor
func mutationStateTransitionsToPendingThenFailure() async {
    let client = QueryClient()
    let state = MutationState(mutation: Mutation<Int, String> { _ in
        throw MutationStateTestError.failed
    })

    state.mutate(1, using: client)
    #expect(state.result.isPending)

    #expect(await eventuallyOnMainActor { state.result.isError })
    #expect(state.result.error is MutationStateTestError)
    #expect(state.result.failureCount == 1)
    #expect(state.result.data == nil)
    #expect(!state.result.isPending)
    #expect(!state.result.isSuccess)
}

@Test
@MainActor
func mutationStateFailureCountDoesNotReportRetryAttempts() async {
    let client = QueryClient()
    let counter = MutationStateAttemptCounter()
    let state = MutationState(
        mutation: Mutation<Int, String>(
            options: MutationOptions(retry: .count(2), retryDelay: .none)
        ) { _ in
            _ = await counter.next()
            throw MutationStateTestError.failed
        }
    )

    state.mutate(1, using: client)

    #expect(await eventuallyOnMainActor { state.result.isError })
    #expect(state.result.error is MutationStateTestError)
    #expect(state.result.failureCount == 1)
    #expect(await counter.value() == 3)
}

@Test
@MainActor
func mutationStateResetClearsResult() async {
    let client = QueryClient()
    let state = MutationState(mutation: Mutation<Int, String> { input in
        "result-\(input)"
    })

    state.mutate(1, using: client)
    #expect(await eventuallyOnMainActor { state.result.isSuccess })

    state.reset()
    #expect(state.result.isIdle)
    #expect(state.result.data == nil)
}

@Test
@MainActor
func mutationStateSecondCallCancelsPreviousAndReturnsNewResult() async {
    let client = QueryClient()
    let state = MutationState(mutation: Mutation<Int, String> { input in
        if input == 1 {
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        return "result-\(input)"
    })

    state.mutate(1, using: client)
    state.mutate(2, using: client)

    #expect(await eventuallyOnMainActor { state.result.isSuccess })
    #expect(state.result.data == "result-2")
}

@Test
@MainActor
func mutationBindingCreatesIdleMutationState() {
    let binding = MutationBinding(mutation: Mutation<Int, String> { input in
        "result-\(input)"
    })

    #expect(binding.wrappedValue.result.isIdle)
    #expect(binding.wrappedValue.result.data == nil)
    #expect(binding.wrappedValue.result.error == nil)
}

@Test
@MainActor
func mutationBindingStateMutatesUsingInjectedClient() async {
    let client = QueryClient()
    let binding = MutationBinding(mutation: Mutation<Int, String> { input in
        "result-\(input)"
    })
    let state = binding.wrappedValue

    state.setClient(client)
    state.mutate(1)
    #expect(state.result.isPending)

    #expect(await eventuallyOnMainActor { state.result.isSuccess })
    #expect(state.result.data == "result-1")
}

@Test
@MainActor
func mutationBindingStatePreservesFailureState() async {
    let client = QueryClient()
    let binding = MutationBinding(mutation: Mutation<Int, String> { _ in
        throw MutationStateTestError.failed
    })
    let state = binding.wrappedValue

    state.setClient(client)
    state.mutate(1)

    #expect(await eventuallyOnMainActor { state.result.isError })
    #expect(state.result.error is MutationStateTestError)
    #expect(state.result.failureCount == 1)
    #expect(state.result.data == nil)
}

@Test
@MainActor
func mutationBindingStateResetClearsResult() async {
    let client = QueryClient()
    let binding = MutationBinding(mutation: Mutation<Int, String> { input in
        "result-\(input)"
    })
    let state = binding.wrappedValue

    state.setClient(client)
    state.mutate(1)
    #expect(await eventuallyOnMainActor { state.result.isSuccess })

    state.reset()
    #expect(state.result.isIdle)
    #expect(state.result.data == nil)
}

@Test
@MainActor
func mutationBindingStateSecondCallPreventsStaleResult() async {
    let client = QueryClient()
    let binding = MutationBinding(mutation: Mutation<Int, String> { input in
        if input == 1 {
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        return "result-\(input)"
    })
    let state = binding.wrappedValue

    state.setClient(client)
    state.mutate(1)
    state.mutate(2)

    #expect(await eventuallyOnMainActor { state.result.isSuccess })
    #expect(state.result.data == "result-2")
}
