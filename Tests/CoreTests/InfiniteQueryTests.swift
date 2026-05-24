import Foundation
import Observation
import Testing
@testable import SunKit
@testable import SunKitSwiftUI

private actor InfiniteFetchRecorder {
    private var calls: [Int] = []

    func fetch(_ page: Int) async -> String {
        calls.append(page)
        if page == 1 {
            try? await Task.sleep(nanoseconds: 80_000_000)
        }
        return "page-\(page)"
    }

    func values() -> [Int] {
        calls
    }
}

private actor InfiniteValueCounter {
    private var count = 0

    func nextPage() -> String {
        count += 1
        return "page-\(count)"
    }

    func value() -> Int {
        count
    }
}

@MainActor
private final class ObservationFlag {
    var didChange = false
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

private func eventually(_ condition: @escaping @Sendable () async -> Bool) async -> Bool {
    for _ in 0..<50 {
        if await condition() {
            return true
        }

        try? await Task.sleep(nanoseconds: 20_000_000)
    }

    return false
}

private func immediateInfiniteOptions<PageParam: Sendable, Page: Sendable>() -> QueryObserverOptions<InfiniteData<PageParam, Page>, InfiniteData<PageParam, Page>> {
    QueryObserverOptions(
        refetchOnSubscribe: .always,
        refetchOnSceneActive: .never,
        refetchOnNetworkReconnect: .never
    )
}

@Test
func fetchInfiniteQueryLoadsInitialPage() async {
    let client = QueryClient()
    let recorder = InfiniteFetchRecorder()
    let query = InfiniteQuery<Int, String>(
        key: ["infinite", "initial"],
        initialPageParam: 0,
        getNextPageParam: { _, pages in pages.count < 2 ? pages.count : nil }
    ) { page in
        await recorder.fetch(page)
    }

    let result = await client.fetchInfiniteQuery(query)

    #expect(result.data?.pages == ["page-0"])
    #expect(result.data?.pageParams == [0])
    #expect(await recorder.values() == [0])
}

@Test
func fetchNextPageAppendsPage() async {
    let client = QueryClient()
    let recorder = InfiniteFetchRecorder()
    let query = InfiniteQuery<Int, String>(
        key: ["infinite", "append"],
        initialPageParam: 0,
        getNextPageParam: { _, pages in pages.count < 2 ? pages.count : nil }
    ) { page in
        await recorder.fetch(page)
    }

    _ = await client.fetchInfiniteQuery(query)
    let result = await client.fetchNextPage(query)

    #expect(result.data?.pages == ["page-0", "page-1"])
    #expect(result.data?.pageParams == [0, 1])
    #expect(await recorder.values() == [0, 1])
}

@Test
func fetchNextPageDoesNotFetchWhenNoNextPageExists() async {
    let client = QueryClient()
    let recorder = InfiniteFetchRecorder()
    let query = InfiniteQuery<Int, String>(
        key: ["infinite", "complete"],
        initialPageParam: 0,
        getNextPageParam: { _, _ in nil }
    ) { page in
        await recorder.fetch(page)
    }

    _ = await client.fetchInfiniteQuery(query)
    let result = await client.fetchNextPage(query)

    #expect(result.data?.pages == ["page-0"])
    #expect(result.data?.pageParams == [0])
    #expect(await recorder.values() == [0])
}

@Test
func concurrentFetchNextPageDoesNotDuplicateAppend() async {
    let client = QueryClient()
    let recorder = InfiniteFetchRecorder()
    let query = InfiniteQuery<Int, String>(
        key: ["infinite", "dedupe"],
        initialPageParam: 0,
        getNextPageParam: { _, pages in pages.count < 2 ? pages.count : nil }
    ) { page in
        await recorder.fetch(page)
    }

    _ = await client.fetchInfiniteQuery(query)

    async let first = client.fetchNextPage(query)
    async let second = client.fetchNextPage(query)
    let results = await [first, second]

    #expect(results[0].data?.pages == ["page-0", "page-1"])
    #expect(results[1].data?.pages == ["page-0", "page-1"])
    #expect(await recorder.values() == [0, 1])
}

@Test
func refetchInfiniteQueryReplacesPagesWithInitialPage() async {
    let client = QueryClient()
    let recorder = InfiniteFetchRecorder()
    let query = InfiniteQuery<Int, String>(
        key: ["infinite", "refetch"],
        initialPageParam: 0,
        getNextPageParam: { _, pages in pages.count < 2 ? pages.count : nil }
    ) { page in
        await recorder.fetch(page)
    }

    _ = await client.fetchInfiniteQuery(query)
    _ = await client.fetchNextPage(query)
    let result = await client.fetchInfiniteQuery(query)

    #expect(result.data?.pages == ["page-0"])
    #expect(result.data?.pageParams == [0])
    #expect(await recorder.values() == [0, 1, 0])
}

@Test
@MainActor
func infiniteQueryStateSelectAppliesToCurrentCachedValue() async {
    let client = QueryClient()
    let key = QueryKey<InfiniteData<Int, [String]>>("swiftui", "infinite", "select", "cached")
    await client.setQueryData(
        key,
        InfiniteData(pages: [["cached-a"], ["cached-b"]], pageParams: [0, 1])
    )
    let query = InfiniteQuery<Int, [String]>(
        key: key,
        initialPageParam: 0,
        getNextPageParam: { _, _ in nil }
    ) { _ in
        ["fresh"]
    }
    let state = InfiniteQueryState<Int, [String], [String]>(
        query: query,
        options: QueryObserverOptions(
            refetchOnSubscribe: .never,
            refetchOnSceneActive: .never,
            refetchOnNetworkReconnect: .never,
            select: { $0.pages.flatMap { $0 } }
        )
    )

    state.start(using: client)

    #expect(await eventuallyOnMainActor { state.data == ["cached-a", "cached-b"] })
    #expect(state.pages == [["cached-a"], ["cached-b"]])
    state.stop()
}

@Test
@MainActor
func infiniteQueryStateSelectsAccumulatedDataAfterNextPage() async {
    let client = QueryClient()
    let query = InfiniteQuery<Int, [String]>(
        key: ["swiftui", "infinite", "select", "next-page"],
        initialPageParam: 0,
        getNextPageParam: { _, pages in pages.count < 2 ? pages.count : nil }
    ) { page in
        ["page-\(page)"]
    }
    let state = InfiniteQueryState<Int, [String], [String]>(
        query: query,
        options: QueryObserverOptions(
            refetchOnSubscribe: .always,
            refetchOnSceneActive: .never,
            refetchOnNetworkReconnect: .never,
            select: { $0.pages.flatMap { $0 } }
        )
    )

    state.start(using: client)
    #expect(await eventuallyOnMainActor { state.data == ["page-0"] })
    #expect(state.hasNextPage)

    state.fetchNextPage(using: client)

    #expect(await eventuallyOnMainActor { state.data == ["page-0", "page-1"] })
    #expect(state.pages == [["page-0"], ["page-1"]])
    #expect(state.hasNextPage == false)
    state.stop()
}

@Test
@MainActor
func infiniteQueryStateSelectUsesSelectedPreviousDataAsPlaceholder() async {
    let client = QueryClient()
    let query = InfiniteQuery<Int, [String]>(
        key: ["swiftui", "infinite", "select", "placeholder"],
        initialPageParam: 0,
        getNextPageParam: { _, _ in nil }
    ) { _ in
        ["first"]
    }
    let state = InfiniteQueryState<Int, [String], [String]>(
        query: query,
        options: QueryObserverOptions(
            placeholderData: .keepPreviousData,
            refetchOnSubscribe: .always,
            refetchOnSceneActive: .never,
            refetchOnNetworkReconnect: .never,
            select: { $0.pages.flatMap { $0 } }
        )
    )

    state.start(using: client)
    #expect(await eventuallyOnMainActor { state.data == ["first"] })

    let slowQuery = InfiniteQuery<Int, [String]>(
        key: ["swiftui", "infinite", "select", "placeholder", "next"],
        initialPageParam: 0,
        getNextPageParam: { _, _ in nil }
    ) { _ in
        try? await Task.sleep(nanoseconds: 200_000_000)
        return ["second"]
    }
    state.update(query: slowQuery, using: client)

    #expect(await eventuallyOnMainActor {
        state.result?.isPending == true
            && state.result?.isPlaceholderData == false
            && state.data == nil
    })
    #expect(state.pages.isEmpty)
    #expect(await eventuallyOnMainActor { state.data == ["second"] })
    state.stop()
}

@Test
@MainActor
func infiniteQueryStateFetchNextPageCanLoadInitialPageWhenSelectReturnsEmptyValue() async {
    let client = QueryClient()
    let query = InfiniteQuery<Int, [String]>(
        key: ["swiftui", "infinite", "select", "empty-initial"],
        initialPageParam: 0,
        getNextPageParam: { _, _ in nil }
    ) { _ in
        []
    }
    let state = InfiniteQueryState<Int, [String], [String]>(
        query: query,
        options: QueryObserverOptions(
            refetchOnSubscribe: .never,
            refetchOnSceneActive: .never,
            refetchOnNetworkReconnect: .never,
            select: { $0.pages.flatMap { $0 } }
        )
    )

    state.start(using: client)
    #expect(await eventuallyOnMainActor { state.result?.isPending == true })

    state.fetchNextPage(using: client)

    #expect(await eventuallyOnMainActor {
        state.result?.isSuccess == true && state.data == [] && state.pages == [[]]
    })
    state.stop()
}

@Test
@MainActor
func infiniteQueryStatePagesObservationTracksRawPageUpdates() async {
    let client = QueryClient()
    let counter = InfiniteValueCounter()
    let query = InfiniteQuery<Int, String>(
        key: ["swiftui", "infinite", "observation", "raw-pages"],
        initialPageParam: 0,
        getNextPageParam: { _, _ in nil }
    ) { _ in
        await counter.nextPage()
    }
    let state = InfiniteQueryState(
        query: query,
        options: QueryObserverOptions(
            refetchOnSubscribe: .always,
            refetchOnSceneActive: .never,
            refetchOnNetworkReconnect: .never
        )
    )

    state.start(using: client)
    #expect(await eventuallyOnMainActor { state.pages == ["page-1"] })

    let flag = ObservationFlag()
    withObservationTracking {
        _ = state.pages
        _ = state.pageParams
        _ = state.hasNextPage
    } onChange: {
        Task { @MainActor in
            flag.didChange = true
        }
    }

    state.refetch(using: client)

    #expect(await eventuallyOnMainActor {
        flag.didChange && state.pages == ["page-2"]
    })
    state.stop()
}

@Test
@MainActor
func infiniteQueryStateReceivesCurrentCachedValue() async {
    let client = QueryClient()
    let key = QueryKey<InfiniteData<Int, String>>("swiftui", "infinite", "cached")
    await client.setQueryData(
        key,
        InfiniteData(pages: ["cached"], pageParams: [0])
    )
    let query = InfiniteQuery<Int, String>(
        key: key,
        initialPageParam: 0,
        getNextPageParam: { _, _ in nil }
    ) { _ in
        "fresh"
    }
    let state = InfiniteQueryState(
        query: query,
        options: QueryObserverOptions(
            refetchOnSubscribe: .never,
            refetchOnSceneActive: .never,
            refetchOnNetworkReconnect: .never
        )
    )

    state.start(using: client)

    #expect(await eventuallyOnMainActor { state.pages == ["cached"] })
    state.stop()
}

@Test
@MainActor
func infiniteQueryStateFetchNextPageAppendsAndTogglesFetching() async {
    let client = QueryClient()
    let recorder = InfiniteFetchRecorder()
    let query = InfiniteQuery<Int, String>(
        key: ["swiftui", "infinite", "append"],
        initialPageParam: 0,
        getNextPageParam: { _, pages in pages.count < 2 ? pages.count : nil }
    ) { page in
        await recorder.fetch(page)
    }
    let state = InfiniteQueryState(query: query, options: immediateInfiniteOptions())

    state.start(using: client)
    #expect(await eventuallyOnMainActor { state.pages == ["page-0"] })
    #expect(state.hasNextPage)

    state.fetchNextPage(using: client)
    #expect(await eventuallyOnMainActor { state.isFetchingNextPage })
    #expect(await eventuallyOnMainActor { state.pages == ["page-0", "page-1"] })
    #expect(state.isFetchingNextPage == false)
    #expect(state.hasNextPage == false)
    state.stop()
}

@Test
@MainActor
func infiniteQueryStateHasNextPageBecomesFalseWhenNextParamIsNil() async {
    let client = QueryClient()
    let query = InfiniteQuery<Int, String>(
        key: ["swiftui", "infinite", "complete"],
        initialPageParam: 0,
        getNextPageParam: { _, _ in nil }
    ) { page in
        "page-\(page)"
    }
    let state = InfiniteQueryState(query: query, options: immediateInfiniteOptions())

    state.start(using: client)

    #expect(await eventuallyOnMainActor { state.pages == ["page-0"] })
    #expect(state.hasNextPage == false)
    state.stop()
}

@Test
@MainActor
func infiniteQueryStateConcurrentFetchNextPageDoesNotDuplicateAppend() async {
    let client = QueryClient()
    let recorder = InfiniteFetchRecorder()
    let query = InfiniteQuery<Int, String>(
        key: ["swiftui", "infinite", "dedupe"],
        initialPageParam: 0,
        getNextPageParam: { _, pages in pages.count < 2 ? pages.count : nil }
    ) { page in
        await recorder.fetch(page)
    }
    let state = InfiniteQueryState(query: query, options: immediateInfiniteOptions())

    state.start(using: client)
    #expect(await eventuallyOnMainActor { state.pages == ["page-0"] })

    state.fetchNextPage(using: client)
    state.fetchNextPage(using: client)

    #expect(await eventuallyOnMainActor { state.pages == ["page-0", "page-1"] })
    #expect(await recorder.values() == [0, 1])
    state.stop()
}

@Test
@MainActor
func infiniteQueryStateRefetchesOnSceneActiveNotification() async {
    let client = QueryClient(defaultCacheOptions: QueryCacheOptions(staleTime: 60))
    let counter = InfiniteValueCounter()
    let query = InfiniteQuery<Int, String>(
        key: ["swiftui", "infinite", "scene-active"],
        initialPageParam: 0,
        getNextPageParam: { _, _ in nil }
    ) { _ in
        await counter.nextPage()
    }
    let state = InfiniteQueryState(
        query: query,
        options: QueryObserverOptions(
            refetchOnSubscribe: .always,
            refetchOnSceneActive: .always,
            refetchOnNetworkReconnect: .never
        )
    )

    state.start(using: client)
    #expect(await eventuallyOnMainActor { state.pages == ["page-1"] })
    try? await Task.sleep(nanoseconds: 20_000_000)

    NotificationCenter.default.post(
        name: InfiniteQueryState<Int, String, InfiniteData<Int, String>>.sceneActiveNotificationName,
        object: nil
    )

    #expect(await eventuallyOnMainActor { state.pages == ["page-2"] })
    state.stop()
}

@Test
@MainActor
func infiniteQueryStateNetworkReconnectAlwaysRefetches() async {
    let client = QueryClient(defaultCacheOptions: QueryCacheOptions(staleTime: 60))
    let counter = InfiniteValueCounter()
    let query = InfiniteQuery<Int, String>(
        key: ["swiftui", "infinite", "network-always"],
        initialPageParam: 0,
        getNextPageParam: { _, _ in nil }
    ) { _ in
        await counter.nextPage()
    }
    let state = InfiniteQueryState(
        query: query,
        options: QueryObserverOptions(
            refetchOnSubscribe: .always,
            refetchOnSceneActive: .never,
            refetchOnNetworkReconnect: .always
        )
    )

    state.start(using: client)
    #expect(await eventuallyOnMainActor { state.pages == ["page-1"] })

    await state.handleNetworkReconnect(using: client)

    #expect(await eventuallyOnMainActor { state.pages == ["page-2"] })
    state.stop()
}

@Test
@MainActor
func infiniteQueryStateNetworkReconnectIfStaleRefetchesStaleData() async {
    let client = QueryClient(defaultCacheOptions: QueryCacheOptions(staleTime: 0))
    let counter = InfiniteValueCounter()
    let query = InfiniteQuery<Int, String>(
        key: ["swiftui", "infinite", "network-if-stale"],
        initialPageParam: 0,
        getNextPageParam: { _, _ in nil }
    ) { _ in
        await counter.nextPage()
    }
    let state = InfiniteQueryState(
        query: query,
        options: QueryObserverOptions(
            refetchOnSubscribe: .always,
            refetchOnSceneActive: .never,
            refetchOnNetworkReconnect: .ifStale
        )
    )

    state.start(using: client)
    #expect(await eventuallyOnMainActor { state.pages == ["page-1"] })

    await state.handleNetworkReconnect(using: client)

    #expect(await eventuallyOnMainActor { state.pages == ["page-2"] })
    state.stop()
}

@Test
@MainActor
func infiniteQueryStateIgnoresStaleOnlyPublication() async {
    let client = QueryClient(defaultCacheOptions: QueryCacheOptions(staleTime: 0.02))
    let counter = InfiniteValueCounter()
    let key = QueryKey<InfiniteData<Int, String>>("swiftui", "infinite", "stale-only")
    let query = InfiniteQuery<Int, String>(
        key: key,
        initialPageParam: 0,
        getNextPageParam: { _, _ in nil }
    ) { _ in
        await counter.nextPage()
    }
    let state = InfiniteQueryState(
        query: query,
        options: QueryObserverOptions(
            refetchOnSubscribe: .always,
            refetchOnSceneActive: .ifStale,
            refetchOnNetworkReconnect: .never
        )
    )

    state.start(using: client)

    #expect(await eventuallyOnMainActor { state.pages == ["page-1"] && state.result?.isStale == false })
    let becameStale = await eventually {
        await client.isQueryStale(key)
    }
    #expect(becameStale)
    #expect(state.result?.isStale == false)
    #expect(await counter.value() == 1)
    state.stop()
}

@Test
@MainActor
func infiniteQueryStateSameKeyUpdateUsesNewQueryForRefetch() async {
    let client = QueryClient()
    let key = QueryKey<InfiniteData<Int, String>>("swiftui", "infinite", "same-key-update")
    let oldQuery = InfiniteQuery<Int, String>(
        key: key,
        initialPageParam: 0,
        getNextPageParam: { _, _ in nil }
    ) { _ in
        "old"
    }
    let newQuery = InfiniteQuery<Int, String>(
        key: key,
        initialPageParam: 0,
        getNextPageParam: { _, _ in nil }
    ) { _ in
        "new"
    }
    let state = InfiniteQueryState(query: oldQuery, options: immediateInfiniteOptions())

    state.start(using: client)
    #expect(await eventuallyOnMainActor { state.pages == ["old"] })

    state.update(query: newQuery, using: client)
    state.refetch(using: client)

    #expect(await eventuallyOnMainActor { state.pages == ["new"] })
    state.stop()
}

@Test
@MainActor
func infiniteQueryStateKeepPreviousDataExposesPreviousPagesWhileRefetching() async {
    let client = QueryClient()
    let counter = InfiniteValueCounter()
    let query = InfiniteQuery<Int, String>(
        key: ["swiftui", "infinite", "refetch-placeholder"],
        initialPageParam: 0,
        getNextPageParam: { _, _ in nil }
    ) { _ in
        let page = await counter.nextPage()
        if page == "page-2" {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return page
    }
    let state = InfiniteQueryState(
        query: query,
        options: QueryObserverOptions(
            placeholderData: .keepPreviousData,
            refetchOnSubscribe: .always,
            refetchOnSceneActive: .never,
            refetchOnNetworkReconnect: .never
        )
    )

    state.start(using: client)
    #expect(await eventuallyOnMainActor { state.pages == ["page-1"] })

    state.refetch(using: client)

    #expect(await eventuallyOnMainActor {
        state.result?.isPending == true
            && state.result?.isPlaceholderData == true
            && state.pages == ["page-1"]
    })
    #expect(await eventuallyOnMainActor { state.pages == ["page-2"] })
    #expect(state.result?.isPlaceholderData == false)
    state.stop()
}

@Test
@MainActor
func infiniteQueryStateKeyUpdateDoesNotUsePreviousPagesAsPlaceholder() async {
    let client = QueryClient()
    let oldQuery = InfiniteQuery<Int, String>(
        key: ["swiftui", "infinite", "placeholder", "old"],
        initialPageParam: 0,
        getNextPageParam: { _, _ in nil }
    ) { _ in
        "old"
    }
    let newQuery = InfiniteQuery<Int, String>(
        key: ["swiftui", "infinite", "placeholder", "new"],
        initialPageParam: 0,
        getNextPageParam: { _, _ in nil }
    ) { _ in
        try? await Task.sleep(nanoseconds: 200_000_000)
        return "new"
    }
    let state = InfiniteQueryState(
        query: oldQuery,
        options: QueryObserverOptions(
            placeholderData: .keepPreviousData,
            refetchOnSubscribe: .always,
            refetchOnSceneActive: .never,
            refetchOnNetworkReconnect: .never
        )
    )

    state.start(using: client)
    #expect(await eventuallyOnMainActor { state.pages == ["old"] })

    state.update(query: newQuery, using: client)

    #expect(await eventuallyOnMainActor {
        state.result?.isPending == true
            && state.result?.isPlaceholderData == false
            && state.pages.isEmpty
    })
    #expect(await eventuallyOnMainActor { state.pages == ["new"] })
    #expect(state.result?.isPlaceholderData == false)
    state.stop()
}
