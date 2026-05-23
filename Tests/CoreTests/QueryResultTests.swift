import Testing
import SunKit

private enum TestError: Error {
    case failed
}

@Test func idleQueryResultComesFromSubscriptionOnly() async {
    let client = QueryClient()
    let key = QueryKey<String>("value")

    let result = await currentResult(for: key, client: client)

    #expect(result?.data == nil)
    #expect(result?.error == nil)
    #expect(result?.isPending == false)
    #expect(result?.isSuccess == false)
    #expect(result?.isError == false)
    #expect(result?.isFetching == false)
    #expect(result?.isStale == false)
    #expect(result?.isPlaceholderData == false)
    #expect(result?.updatedAt == nil)
    #expect(result?.failureCount == 0)
}

@Test func pendingQueryResultComesFromFetchPublication() async {
    let client = QueryClient()
    let key = QueryKey<String>("value")
    let (stream, continuation) = AsyncStream.makeStream(of: QueryResult<String>.self)
    let subscription = await client.subscribe(to: key, receiveCurrentValue: false) { result in
        continuation.yield(result)
    }
    var iterator = stream.makeAsyncIterator()
    let query = Query(key: key) {
        try? await Task.sleep(nanoseconds: 100_000_000)
        return "fresh"
    }

    async let fetchResult = client.fetchQuery(query)
    let pending = await iterator.next()
    _ = await fetchResult

    #expect(pending?.data == nil)
    #expect(pending?.error == nil)
    #expect(pending?.isPending == true)
    #expect(pending?.isSuccess == false)
    #expect(pending?.isError == false)
    #expect(pending?.isFetching == true)
    #expect(pending?.failureCount == 0)
    await subscription.cancel()
    continuation.finish()
}

@Test func pendingQueryResultKeepsPreviousDataDuringRefetch() async {
    let client = QueryClient(defaultCacheOptions: QueryCacheOptions(staleTime: 60))
    let key = QueryKey<String>("value")
    _ = await client.fetchQuery(Query(key: key) { "cached" })
    let (stream, continuation) = AsyncStream.makeStream(of: QueryResult<String>.self)
    let subscription = await client.subscribe(to: key, receiveCurrentValue: false) { result in
        continuation.yield(result)
    }
    var iterator = stream.makeAsyncIterator()
    let query = Query(key: key) {
        try? await Task.sleep(nanoseconds: 100_000_000)
        return "fresh"
    }

    async let fetchResult = client.fetchQuery(query)
    let pending = await iterator.next()
    _ = await fetchResult

    #expect(pending?.data == "cached")
    #expect(pending?.error == nil)
    #expect(pending?.isPending == true)
    #expect(pending?.isSuccess == false)
    #expect(pending?.isError == false)
    #expect(pending?.failureCount == 0)
    await subscription.cancel()
    continuation.finish()
}

@Test func successfulQueryResultExposesData() async {
    let client = QueryClient(defaultCacheOptions: QueryCacheOptions(staleTime: 60))
    let result = await client.fetchQuery(Query(key: QueryKey<String>("value")) { "fresh" })

    #expect(result.data == "fresh")
    #expect(result.error == nil)
    #expect(!result.isPending)
    #expect(result.isSuccess)
    #expect(!result.isError)
    #expect(!result.isFetching)
    #expect(!result.isStale)
    #expect(result.updatedAt != nil)
    #expect(result.failureCount == 0)
}

@Test func failedQueryResultWithoutStaleDataExposesErrorOnly() async {
    let client = QueryClient()
    let result = await client.fetchQuery(Query<String>(key: QueryKey<String>("value"), options: QueryOptions(retry: .never)) {
        throw TestError.failed
    })

    #expect(result.data == nil)
    #expect(result.error is TestError)
    #expect(!result.isPending)
    #expect(!result.isSuccess)
    #expect(result.isError)
    #expect(result.failureCount == 1)
}

@Test func failedQueryResultWithStaleDataKeepsDataAvailable() async {
    let client = QueryClient()
    let key = QueryKey<String>("value")
    _ = await client.fetchQuery(Query(key: key) { "stale" })

    let result = await client.fetchQuery(Query<String>(key: key, options: QueryOptions(retry: .never)) {
        throw TestError.failed
    })

    #expect(result.data == "stale")
    #expect(result.error is TestError)
    #expect(!result.isPending)
    #expect(!result.isSuccess)
    #expect(result.isError)
    #expect(result.failureCount == 1)
}

@Test func cachedQueryResultPreservesFetchAndCacheFlags() async {
    let client = QueryClient(defaultCacheOptions: QueryCacheOptions(staleTime: 60))
    let key = QueryKey<String>("value")

    await client.setQueryData(key, "cached")
    let result = await currentResult(for: key, client: client)

    #expect(result?.data == "cached")
    #expect(result?.isSuccess == true)
    #expect(result?.isFetching == false)
    #expect(result?.isStale == false)
    #expect(result?.isPlaceholderData == false)
    #expect(result?.updatedAt != nil)
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
