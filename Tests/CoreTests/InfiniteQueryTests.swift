import Foundation
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

private func eventuallyOnMainActor(_ condition: @escaping @MainActor () -> Bool) async -> Bool {
    for _ in 0..<50 {
        if await MainActor.run(body: condition) {
            return true
        }

        try? await Task.sleep(nanoseconds: 20_000_000)
    }

    return false
}

private var immediateInfiniteOptions: QueryObserverOptions {
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
    let state = InfiniteQueryState(query: query, options: immediateInfiniteOptions)

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
    let state = InfiniteQueryState(query: query, options: immediateInfiniteOptions)

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
    let state = InfiniteQueryState(query: query, options: immediateInfiniteOptions)

    state.start(using: client)
    #expect(await eventuallyOnMainActor { state.pages == ["page-0"] })

    state.fetchNextPage(using: client)
    state.fetchNextPage(using: client)

    #expect(await eventuallyOnMainActor { state.pages == ["page-0", "page-1"] })
    #expect(await recorder.values() == [0, 1])
    state.stop()
}
