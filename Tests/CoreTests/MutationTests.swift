import Foundation
import Testing
@testable import SunKit

private enum MutationTestError: Error {
    case failed
}

private actor MutationCounter {
    private var count = 0

    func next() -> Int {
        count += 1
        return count
    }

    func value() -> Int {
        count
    }
}

private final class EventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []

    func append(_ event: String) {
        lock.withLock {
            events.append(event)
        }
    }

    func values() -> [String] {
        lock.withLock {
            events
        }
    }
}

@Test func mutationResultProjectionsExposeSuccessData() {
    let result = MutationResult(status: MutationStatus.success("created"))

    #expect(result.data == "created")
    #expect(result.error == nil)
    #expect(!result.isIdle)
    #expect(result.isSuccess)
    #expect(!result.isPending)
    #expect(!result.isError)
    #expect(result.failureCount == 0)
}

@Test func mutationResultProjectionsExposeFailure() {
    let result = MutationResult<String>(
        status: .failure(MutationTestError.failed),
        failureCount: 1
    )

    #expect(result.data == nil)
    #expect(result.error is MutationTestError)
    #expect(!result.isIdle)
    #expect(result.isError)
    #expect(!result.isPending)
    #expect(!result.isSuccess)
    #expect(result.failureCount == 1)
}

@Test func asyncMutationSuccessReturnsOutput() async throws {
    let client = QueryClient()
    let mutation = Mutation<Int, String> { input in
        "created-\(input)"
    }

    let output = try await client.mutate(mutation, input: 42)

    #expect(output == "created-42")
}

@Test func asyncMutationFailureThrowsOriginalError() async {
    let client = QueryClient()
    let mutation = Mutation<Int, String> { _ in
        throw MutationTestError.failed
    }

    do {
        _ = try await client.mutate(mutation, input: 42)
        Issue.record("Expected mutation to throw.")
    } catch {
        #expect(error is MutationTestError)
    }
}

@Test func completionMutationFetcherReturnsSuccess() async throws {
    let client = QueryClient()
    let mutation = Mutation<Int, String> { input, completion in
        completion(.success("created-\(input)"))
    }

    let output = try await client.mutate(mutation, input: 42)

    #expect(output == "created-42")
}

@Test func completionMutationFetcherReturnsFailure() async {
    let client = QueryClient()
    let mutation = Mutation<Int, String> { _, completion in
        completion(.failure(MutationTestError.failed))
    }

    do {
        _ = try await client.mutate(mutation, input: 42)
        Issue.record("Expected completion mutation to throw.")
    } catch {
        #expect(error is MutationTestError)
    }
}

@Test func completionMutateDeliversResult() async {
    let client = QueryClient()
    let mutation = Mutation<Int, String> { input in
        "created-\(input)"
    }
    let (stream, continuation) = AsyncStream.makeStream(of: Result<String, Error>.self)

    client.mutate(mutation, input: 42) { result in
        continuation.yield(result)
    }

    var iterator = stream.makeAsyncIterator()
    let result = await iterator.next()
    continuation.finish()

    #expect((try? result?.get()) == "created-42")
}

@Test func defaultMutationRetryDoesNotRetryFailure() async {
    let client = QueryClient()
    let counter = MutationCounter()
    let mutation = Mutation<Int, String> { _ in
        _ = await counter.next()
        throw MutationTestError.failed
    }

    do {
        _ = try await client.mutate(mutation, input: 42)
        Issue.record("Expected mutation to throw.")
    } catch {
        #expect(error is MutationTestError)
    }

    #expect(await counter.value() == 1)
}

@Test func mutationRetryCanSucceedAfterFailure() async throws {
    let client = QueryClient()
    let counter = MutationCounter()
    let mutation = Mutation<Int, String>(
        options: MutationOptions(retry: .count(1), retryDelay: .none)
    ) { input in
        let attempt = await counter.next()
        if attempt == 1 {
            throw MutationTestError.failed
        }

        return "created-\(input)"
    }

    let output = try await client.mutate(mutation, input: 42)

    #expect(output == "created-42")
    #expect(await counter.value() == 2)
}

@Test func successCallbacksRunInOrder() async throws {
    let client = QueryClient()
    let events = EventRecorder()
    let mutation = Mutation<Int, String>(
        options: MutationOptions(
            onSuccess: { output, input, _ in
                events.append("success:\(input):\(output)")
            },
            onSettled: { result, input, _ in
                if case let .success(output) = result {
                    events.append("settled:\(input):\(output)")
                }
            }
        )
    ) { input in
        "created-\(input)"
    }

    _ = try await client.mutate(mutation, input: 42)

    #expect(events.values() == ["success:42:created-42", "settled:42:created-42"])
}

@Test func failureCallbacksRunInOrder() async {
    let client = QueryClient()
    let events = EventRecorder()
    let mutation = Mutation<Int, String>(
        options: MutationOptions(
            onFailure: { error, input, _ in
                events.append("failure:\(input):\(error is MutationTestError)")
            },
            onSettled: { result, input, _ in
                if case .failure = result {
                    events.append("settled:\(input):failure")
                }
            }
        )
    ) { _ in
        throw MutationTestError.failed
    }

    do {
        _ = try await client.mutate(mutation, input: 42)
        Issue.record("Expected mutation to throw.")
    } catch {
        #expect(error is MutationTestError)
    }

    #expect(events.values() == ["failure:42:true", "settled:42:failure"])
}

@Test func mutationSuccessDoesNotAutomaticallyInvalidateQueries() async throws {
    let client = QueryClient(defaultCacheOptions: QueryCacheOptions(staleTime: 60))
    let key = QueryKey<Int>("projects")
    await client.setQueryData(key, 1)
    let mutation = Mutation<Int, String> { input in
        "created-\(input)"
    }

    _ = try await client.mutate(mutation, input: 42)
    let result = await currentResult(for: key, client: client)

    #expect(result?.data == 1)
    #expect(result?.isStale == false)
}

@Test func onSuccessCanExplicitlyInvalidateQueries() async throws {
    let client = QueryClient(defaultCacheOptions: QueryCacheOptions(staleTime: 60))
    let key = QueryKey<Int>("projects")
    await client.setQueryData(key, 1)
    let mutation = Mutation<Int, String>(
        options: MutationOptions(
            onSuccess: { _, _, client in
                await client.invalidateQueries(AnyQueryKey("projects"), exact: false)
            }
        )
    ) { input in
        "created-\(input)"
    }

    _ = try await client.mutate(mutation, input: 42)
    let result = await currentResult(for: key, client: client)

    #expect(result?.data == 1)
    #expect(result?.isStale == true)
}

private func currentResult<Value: Sendable>(
    for key: QueryKey<Value>,
    client: QueryClient
) async -> QueryResult<Value>? {
    let (stream, continuation) = AsyncStream.makeStream(of: QueryResult<Value>.self)
    let subscription = await client.subscribe(to: key) { result in
        continuation.yield(result)
    }
    var iterator = stream.makeAsyncIterator()
    let result = await iterator.next()
    await subscription.cancel()
    continuation.finish()
    return result
}
