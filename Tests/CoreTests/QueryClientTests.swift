import Foundation
import Testing
@testable import SunKit

private enum QueryClientTestError: Error {
    case failed
}

private actor FetchCounter {
    private var count = 0

    func next() -> Int {
        count += 1
        return count
    }

    func value() -> Int {
        count
    }
}

private final class SyncCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func next() -> Int {
        lock.withLock {
            count += 1
            return count
        }
    }

    func value() -> Int {
        lock.withLock {
            count
        }
    }
}

private func eventually(_ condition: @escaping @Sendable () async -> Bool) async -> Bool {
    for _ in 0..<50 {
        if await condition() {
            return true
        }

        try? await Task.sleep(nanoseconds: 20_000_000)
    }

    return false
}

@Test func queryClientStoresDefaultOptions() {
    let queryOptions = QueryOptions(retry: .never, retryDelay: .none)
    let cacheOptions = QueryCacheOptions(staleTime: 10, gcTime: 20)
    let client = QueryClient(
        defaultQueryOptions: queryOptions,
        defaultCacheOptions: cacheOptions
    )

    #expect(client.defaultQueryOptions == queryOptions)
    #expect(client.defaultCacheOptions == cacheOptions)
}

@Test func setQueryDataThenGetQueryDataReturnsValue() async {
    let client = QueryClient()
    let key = QueryKey<Int>("value")

    await client.setQueryData(key, 42)

    let value = await client.getQueryData(key)
    #expect(value == 42)
}

@Test func differentTypedKeysDoNotCollide() async {
    let client = QueryClient()
    let intKey = QueryKey<Int>("value")
    let stringKey = QueryKey<String>("value")

    await client.setQueryData(intKey, 42)
    await client.setQueryData(stringKey, "forty-two")

    #expect(await client.getQueryData(intKey) == 42)
    #expect(await client.getQueryData(stringKey) == "forty-two")
}

@Test func updateQueryDataTransformsExistingValue() async {
    let client = QueryClient()
    let key = QueryKey<Int>("value")
    await client.setQueryData(key, 41)

    await client.updateQueryData(key) { current in
        current + 1
    }

    #expect(await client.getQueryData(key) == 42)
}

@Test func updateQueryDataWithoutExistingDataIsNoOp() async {
    let client = QueryClient()
    let key = QueryKey<Int>("value")
    let updates = SyncCounter()

    await client.updateQueryData(key) { current in
        _ = updates.next()
        return current + 1
    }

    #expect(updates.value() == 0)
    #expect(await client.getQueryData(key) == nil)
}

@Test func updateQueryDataDoesNotCollideAcrossValueTypes() async {
    let client = QueryClient()
    let intKey = QueryKey<Int>("value")
    let stringKey = QueryKey<String>("value")
    await client.setQueryData(intKey, 41)
    await client.setQueryData(stringKey, "forty")

    await client.updateQueryData(intKey) { current in
        current + 1
    }

    #expect(await client.getQueryData(intKey) == 42)
    #expect(await client.getQueryData(stringKey) == "forty")
}

@Test func updateQueryDataPublishesUpdatedResult() async {
    let client = QueryClient()
    let key = QueryKey<Int>("value")
    await client.setQueryData(key, 41)
    let (stream, continuation) = AsyncStream.makeStream(of: QueryResult<Int>.self)
    let subscription = await client.subscribe(to: key, receiveCurrentValue: false) { result in
        continuation.yield(result)
    }
    var iterator = stream.makeAsyncIterator()

    await client.updateQueryData(key) { current in
        current + 1
    }
    let result = await iterator.next()

    #expect(result?.data == 42)
    #expect(result?.isSuccess == true)
    await subscription.cancel()
    continuation.finish()
}

@Test func updateQueryDataClearsInvalidationAndRecomputesStaleState() async {
    let client = QueryClient(defaultCacheOptions: QueryCacheOptions(staleTime: 60))
    let key = QueryKey<Int>("value")
    await client.setQueryData(key, 41)
    await client.invalidate(key: key)

    await client.updateQueryData(key) { current in
        current + 1
    }
    let result = await currentResult(for: key, client: client)

    #expect(result?.data == 42)
    #expect(result?.isSuccess == true)
    #expect(result?.isStale == false)
}

@Test func clearRemovesData() async {
    let client = QueryClient()
    let key = QueryKey<Int>("value")

    await client.setQueryData(key, 42)
    await client.clear()

    #expect(await client.getQueryData(key) == nil)
}

@Test func fetchSuccessStoresData() async {
    let client = QueryClient()
    let key = QueryKey<Int>("value")
    let query = Query(key: key) { 42 }

    let result = await client.fetchQuery(query)

    #expect(result.data == 42)
    #expect(result.isSuccess)
    #expect(await client.getQueryData(key) == 42)
}

@Test func ensureQueryDataReturnsFreshCachedData() async throws {
    let client = QueryClient(defaultCacheOptions: QueryCacheOptions(staleTime: 60))
    let key = QueryKey<Int>("value")
    let counter = FetchCounter()
    await client.setQueryData(key, 42)
    let query = Query(key: key) {
        await counter.next()
    }

    let value = try await client.ensureQueryData(query)

    #expect(value == 42)
    #expect(await counter.value() == 0)
}

@Test func ensureQueryDataThrowsOnFetchFailure() async {
    let client = QueryClient()
    let query = Query<Int>(key: QueryKey<Int>("value"), options: QueryOptions(retry: .never)) {
        throw QueryClientTestError.failed
    }

    do {
        _ = try await client.ensureQueryData(query)
        Issue.record("Expected ensureQueryData to throw.")
    } catch {
        #expect(error is QueryClientTestError)
    }
}

@Test func lateResponseDoesNotOverwriteNewerCacheEntry() async {
    let client = QueryClient()
    let key = QueryKey<Int>("value")
    let slowQuery = Query(key: key) {
        try? await Task.sleep(nanoseconds: 100_000_000)
        return 1
    }

    async let slowResult = client.fetchQuery(slowQuery)
    try? await Task.sleep(nanoseconds: 20_000_000)
    await client.clear()
    await client.setQueryData(key, 99)
    _ = await slowResult

    #expect(await client.getQueryData(key) == 99)
}

@Test func fetchStartPublishesPendingResult() async {
    let client = QueryClient()
    let key = QueryKey<Int>("value")
    let (stream, continuation) = AsyncStream.makeStream(of: QueryResult<Int>.self)
    let subscription = await client.subscribe(to: key, receiveCurrentValue: false) { result in
        continuation.yield(result)
    }
    var iterator = stream.makeAsyncIterator()
    let query = Query(key: key) {
        try? await Task.sleep(nanoseconds: 100_000_000)
        return 42
    }

    async let fetchResult = client.fetchQuery(query)
    let pending = await iterator.next()
    let result = await fetchResult

    #expect(pending?.isPending == true)
    #expect(pending?.isFetching == true)
    #expect(result.data == 42)
    await subscription.cancel()
    continuation.finish()
}

@Test func sameKeyConcurrentFetchDedupes() async {
    let client = QueryClient()
    let counter = FetchCounter()
    let query = Query(key: QueryKey<Int>("value")) {
        let value = await counter.next()
        try? await Task.sleep(nanoseconds: 100_000_000)
        return value
    }

    async let first = client.fetchQuery(query)
    async let second = client.fetchQuery(query)
    let results = await (first, second)

    #expect(results.0.data == 1)
    #expect(results.1.data == 1)
    #expect(await counter.value() == 1)
}

@Test func competingSameKeyFetcherDoesNotRunWhileFirstIsInFlight() async {
    let client = QueryClient()
    let firstCounter = FetchCounter()
    let secondCounter = FetchCounter()
    let key = QueryKey<Int>("value")
    let firstQuery = Query(key: key) {
        let value = await firstCounter.next()
        try? await Task.sleep(nanoseconds: 150_000_000)
        return value
    }
    let secondQuery = Query(key: key) {
        await secondCounter.next()
    }

    async let first = client.fetchQuery(firstQuery)
    let firstStarted = await eventually {
        await firstCounter.value() == 1
    }
    let second = await client.fetchQuery(secondQuery)
    let firstResult = await first

    #expect(firstStarted)
    #expect(firstResult.data == 1)
    #expect(second.data == 1)
    #expect(await secondCounter.value() == 0)
}

@Test func initialFailureHasNoData() async {
    let client = QueryClient()
    let query = Query<Int>(key: QueryKey<Int>("value"), options: QueryOptions(retry: .never)) {
        throw QueryClientTestError.failed
    }

    let result = await client.fetchQuery(query)

    #expect(result.data == nil)
    #expect(result.error is QueryClientTestError)
    #expect(result.isError)
    #expect(result.failureCount == 1)
}

@Test func refetchFailureKeepsStaleData() async {
    let client = QueryClient()
    let key = QueryKey<Int>("value")
    let success = Query(key: key) { 42 }
    let failure = Query<Int>(key: key, options: QueryOptions(retry: .never)) {
        throw QueryClientTestError.failed
    }

    _ = await client.fetchQuery(success)
    let result = await client.fetchQuery(failure)

    #expect(result.data == 42)
    #expect(result.error is QueryClientTestError)
    #expect(result.isError)
    #expect(result.isStale)
}

@Test func consecutiveFailuresIncrementFailureCount() async {
    let client = QueryClient()
    let query = Query<Int>(key: QueryKey<Int>("value"), options: QueryOptions(retry: .never)) {
        throw QueryClientTestError.failed
    }

    let first = await client.fetchQuery(query)
    let second = await client.fetchQuery(query)

    #expect(first.failureCount == 1)
    #expect(second.failureCount == 2)
}

@Test func successResetsFailureCount() async {
    let client = QueryClient()
    let key = QueryKey<Int>("value")
    let failure = Query<Int>(key: key, options: QueryOptions(retry: .never)) {
        throw QueryClientTestError.failed
    }
    let success = Query(key: key) { 42 }

    _ = await client.fetchQuery(failure)
    let result = await client.fetchQuery(success)

    #expect(result.isSuccess)
    #expect(result.failureCount == 0)
}

@Test func successResultFreshnessFollowsStaleTime() async {
    let freshClient = QueryClient(defaultCacheOptions: QueryCacheOptions(staleTime: 60))
    let staleClient = QueryClient(defaultCacheOptions: QueryCacheOptions(staleTime: 0))
    let key = QueryKey<Int>("value")

    let fresh = await freshClient.fetchQuery(Query(key: key) { 1 })
    let stale = await staleClient.fetchQuery(Query(key: key) { 1 })

    #expect(!fresh.isStale)
    #expect(stale.isStale)
}

@Test func successfulQueryPublishesStaleWhenStaleTimeElapses() async {
    let client = QueryClient(defaultCacheOptions: QueryCacheOptions(staleTime: 0.02))
    let key = QueryKey<Int>("value")
    let query = Query(key: key) { 42 }
    let (stream, continuation) = AsyncStream.makeStream(of: QueryResult<Int>.self)
    let subscription = await client.subscribe(to: key, receiveCurrentValue: false) { result in
        continuation.yield(result)
    }
    var iterator = stream.makeAsyncIterator()

    _ = await client.fetchQuery(query)
    _ = await iterator.next()
    let success = await iterator.next()
    let stale = await iterator.next()

    #expect(success?.data == 42)
    #expect(success?.isStale == false)
    #expect(stale?.data == 42)
    #expect(stale?.isStale == true)
    await subscription.cancel()
    continuation.finish()
}

@Test func subscriberReceivesCurrentValueWhenRequested() async {
    let client = QueryClient(defaultCacheOptions: QueryCacheOptions(staleTime: 60))
    let key = QueryKey<Int>("value")
    await client.setQueryData(key, 42)
    let (stream, continuation) = AsyncStream.makeStream(of: QueryResult<Int>.self)
    let subscription = await client.subscribe(to: key) { result in
        continuation.yield(result)
    }
    var iterator = stream.makeAsyncIterator()

    let current = await iterator.next()

    #expect(current?.data == 42)
    #expect(current?.isSuccess == true)
    await subscription.cancel()
    continuation.finish()
}

@Test func subscribeDoesNotAutoFetch() async {
    let client = QueryClient()
    let key = QueryKey<Int>("value")
    let counter = FetchCounter()
    let subscription = await client.subscribe(to: key, receiveCurrentValue: false) { _ in }

    try? await Task.sleep(nanoseconds: 50_000_000)

    #expect(await counter.value() == 0)
    #expect(await client.getQueryData(key) == nil)
    await subscription.cancel()
}

@Test func unsubscribeStopsDelivery() async {
    let client = QueryClient()
    let key = QueryKey<Int>("value")
    let deliveries = FetchCounter()
    let subscription = await client.subscribe(to: key, receiveCurrentValue: false) { _ in
        Task {
            _ = await deliveries.next()
        }
    }
    await subscription.cancel()

    await client.setQueryData(key, 42)
    try? await Task.sleep(nanoseconds: 50_000_000)

    #expect(await deliveries.value() == 0)
}

@Test func invalidateKeyMarksExactTypedKeyStale() async {
    let client = QueryClient(defaultCacheOptions: QueryCacheOptions(staleTime: 60))
    let key = QueryKey<Int>("value")
    await client.setQueryData(key, 42)

    await client.invalidate(key: key)
    let result = await currentResult(for: key, client: client)

    #expect(result?.data == 42)
    #expect(result?.isStale == true)
}

@Test func invalidateKeyOnActiveQueryTriggersBackgroundRefetch() async {
    let client = QueryClient(defaultCacheOptions: QueryCacheOptions(staleTime: 60))
    let counter = FetchCounter()
    let key = QueryKey<Int>("value")
    let query = Query(key: key) {
        await counter.next()
    }

    _ = await client.fetchQuery(query)
    let subscription = await client.subscribe(to: key, receiveCurrentValue: false) { _ in }
    await client.invalidate(key: key)

    let refetched = await eventually {
        await client.getQueryData(key) == 2
    }

    #expect(refetched)
    #expect(await counter.value() == 2)
    await subscription.cancel()
}

@Test func invalidateKeyOnInactiveQueryDoesNotImmediatelyRefetch() async {
    let client = QueryClient(defaultCacheOptions: QueryCacheOptions(staleTime: 60))
    let counter = FetchCounter()
    let key = QueryKey<Int>("value")
    let query = Query(key: key) {
        await counter.next()
    }

    _ = await client.fetchQuery(query)
    await client.invalidate(key: key)
    try? await Task.sleep(nanoseconds: 50_000_000)

    #expect(await counter.value() == 1)
    #expect(await client.getQueryData(key) == 1)
}

@Test func prefixInvalidationMatchesMultipleKeys() async {
    let client = QueryClient(defaultCacheOptions: QueryCacheOptions(staleTime: 60))
    let first = QueryKey<Int>("items", 1)
    let second = QueryKey<Int>("items", 2)
    await client.setQueryData(first, 1)
    await client.setQueryData(second, 2)

    await client.invalidateQueries(AnyQueryKey("items"), exact: false)

    let firstResult = await currentResult(for: first, client: client)
    let secondResult = await currentResult(for: second, client: client)
    #expect(firstResult?.isStale == true)
    #expect(secondResult?.isStale == true)
}

@Test func exactErasedInvalidationMatchesOneKey() async {
    let client = QueryClient(defaultCacheOptions: QueryCacheOptions(staleTime: 60))
    let root = QueryKey<Int>("items")
    let child = QueryKey<Int>("items", 1)
    await client.setQueryData(root, 1)
    await client.setQueryData(child, 2)

    await client.invalidateQueries(AnyQueryKey("items"), exact: true)

    let rootResult = await currentResult(for: root, client: client)
    let childResult = await currentResult(for: child, client: client)
    #expect(rootResult?.isStale == true)
    #expect(childResult?.isStale == false)
}

@Test func activePrefixInvalidationRefetchesActiveMatchingQueriesOnly() async {
    let client = QueryClient(defaultCacheOptions: QueryCacheOptions(staleTime: 60))
    let activeCounter = FetchCounter()
    let inactiveCounter = FetchCounter()
    let activeKey = QueryKey<Int>("items", "active")
    let inactiveKey = QueryKey<Int>("items", "inactive")
    let activeQuery = Query(key: activeKey) {
        await activeCounter.next()
    }
    let inactiveQuery = Query(key: inactiveKey) {
        await inactiveCounter.next()
    }

    _ = await client.fetchQuery(activeQuery)
    _ = await client.fetchQuery(inactiveQuery)
    let subscription = await client.subscribe(to: activeKey, receiveCurrentValue: false) { _ in }

    await client.invalidateQueries(AnyQueryKey("items"), exact: false)

    let refetched = await eventually {
        await client.getQueryData(activeKey) == 2
    }

    #expect(refetched)
    #expect(await client.getQueryData(inactiveKey) == 1)
    #expect(await activeCounter.value() == 2)
    #expect(await inactiveCounter.value() == 1)
    await subscription.cancel()
}

@Test func setQueryDataMidFlightAllowsSubsequentFetchToRunFresh() async {
    let client = QueryClient()
    let key = QueryKey<Int>("value")
    let slowQuery = Query(key: key) {
        try? await Task.sleep(nanoseconds: 100_000_000)
        return 1
    }
    let freshQuery = Query(key: key) { 200 }

    async let _ = client.fetchQuery(slowQuery)
    try? await Task.sleep(nanoseconds: 20_000_000)
    await client.setQueryData(key, 99)

    let second = await client.fetchQuery(freshQuery)

    #expect(second.data == 200)
    #expect(await client.getQueryData(key) == 200)
}

@Test func updateQueryDataMidFlightAllowsSubsequentFetchToRunFresh() async {
    let client = QueryClient()
    let key = QueryKey<Int>("value")
    await client.setQueryData(key, 10)
    let slowQuery = Query(key: key) {
        try? await Task.sleep(nanoseconds: 100_000_000)
        return 1
    }
    let freshQuery = Query(key: key) { 200 }

    async let _ = client.fetchQuery(slowQuery)
    try? await Task.sleep(nanoseconds: 20_000_000)
    await client.updateQueryData(key) { $0 + 5 }

    let second = await client.fetchQuery(freshQuery)

    #expect(second.data == 200)
    #expect(await client.getQueryData(key) == 200)
}

@Test func setQueryDataWhileInFlightDoesNotGetOverwritten() async {
    let client = QueryClient()
    let key = QueryKey<Int>("value")
    let slowQuery = Query(key: key) {
        try? await Task.sleep(nanoseconds: 100_000_000)
        return 1
    }

    async let slowResult = client.fetchQuery(slowQuery)
    try? await Task.sleep(nanoseconds: 20_000_000)
    await client.setQueryData(key, 99)
    _ = await slowResult

    #expect(await client.getQueryData(key) == 99)
}

@Test func updateQueryDataWhileInFlightDoesNotGetOverwritten() async {
    let client = QueryClient()
    let key = QueryKey<Int>("value")
    await client.setQueryData(key, 10)
    let slowQuery = Query(key: key) {
        try? await Task.sleep(nanoseconds: 100_000_000)
        return 1
    }

    async let slowResult = client.fetchQuery(slowQuery)
    try? await Task.sleep(nanoseconds: 20_000_000)
    await client.updateQueryData(key) { $0 + 5 }
    _ = await slowResult

    #expect(await client.getQueryData(key) == 15)
}

@Test func removedQueryDataIsNotReturned() async {
    let client = QueryClient()
    let key = QueryKey<Int>("value")
    await client.setQueryData(key, 42)

    await client.removeQueries(AnyQueryKey("value"), exact: true)

    #expect(await client.getQueryData(key) == nil)
}

@Test func entryRemovedFromCacheAfterGCTimeWithNoSubscribers() async {
    let client = QueryClient(defaultCacheOptions: QueryCacheOptions(staleTime: 0, gcTime: 0.05))
    let key = QueryKey<Int>("gc-test")
    await client.setQueryData(key, 42)

    try? await Task.sleep(nanoseconds: 100_000_000) // wait > gcTime

    #expect(await client.getQueryData(key) == nil)
}

@Test func gcTimerCancelledWhenNewSubscriberArrives() async {
    let client = QueryClient(defaultCacheOptions: QueryCacheOptions(staleTime: 0, gcTime: 0.1))
    let key = QueryKey<Int>("gc-cancel-test")
    await client.setQueryData(key, 42)

    // Subscribe immediately — should cancel any GC timer
    let subscription = await client.subscribe(to: key, receiveCurrentValue: false) { _ in }

    try? await Task.sleep(nanoseconds: 150_000_000) // wait > gcTime

    // Data must still be present because subscriber was active
    #expect(await client.getQueryData(key) == 42)
    await subscription.cancel()
}

@Test func entryRemovedImmediatelyWhenGCTimeIsZero() async {
    let client = QueryClient(defaultCacheOptions: QueryCacheOptions(staleTime: 0, gcTime: 0))
    let key = QueryKey<Int>("gc-zero-test")
    await client.setQueryData(key, 7)

    // No subscribers, gcTime == 0: entry should be removed on next event loop turn
    try? await Task.sleep(nanoseconds: 20_000_000)

    #expect(await client.getQueryData(key) == nil)
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
