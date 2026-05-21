import Testing
@testable import SunKit

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

@Test func clearRemovesData() async {
    let client = QueryClient()
    let key = QueryKey<Int>("value")

    await client.setQueryData(key, 42)
    await client.clear()

    #expect(await client.getQueryData(key) == nil)
}
