import Foundation
import Testing
@testable import SunKit
@testable import SunKitSwiftUI

private actor SwiftUIFetchCounter {
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
func queryStateReceivesCurrentCachedValue() async {
    let client = QueryClient()
    let key = QueryKey<String>("swiftui", "cached")
    await client.setQueryData(key, "cached")

    let state = QueryState(
        key: ["swiftui", "cached"],
        options: QueryObserverOptions(refetchOnSubscribe: .never)
    ) {
        "fresh"
    }

    state.start(using: client)

    #expect(await eventuallyOnMainActor { state.result?.data == "cached" })
    state.stop()
}

@Test
@MainActor
func disabledQueryStateDoesNotFetchOnStart() async {
    let client = QueryClient()
    let counter = SwiftUIFetchCounter()
    let state = QueryState(
        key: ["swiftui", "disabled"],
        options: QueryObserverOptions(enabled: false)
    ) {
        await counter.next()
    }

    state.start(using: client)

    try? await Task.sleep(nanoseconds: 100_000_000)

    #expect(await counter.value() == 0)
    state.stop()
}

@Test
@MainActor
func queryStateManualRefetchFetchesQuery() async {
    let client = QueryClient()
    let counter = SwiftUIFetchCounter()
    let state = QueryState(
        key: ["swiftui", "manual-refetch"],
        options: QueryObserverOptions(enabled: false)
    ) {
        await counter.next()
    }

    state.start(using: client)
    state.refetch(using: client)

    #expect(await eventuallyOnMainActor { state.result?.data == 1 })
    #expect(await counter.value() == 1)
    state.stop()
}

@Test
@MainActor
func queryStateReflectsStaleTimePublication() async {
    let client = QueryClient(defaultCacheOptions: QueryCacheOptions(staleTime: 0.02))
    let state = QueryState(key: ["swiftui", "stale-time"]) {
        1
    }

    state.start(using: client)

    #expect(await eventuallyOnMainActor { state.result?.isStale == false })
    #expect(await eventuallyOnMainActor { state.result?.isStale == true })
    state.stop()
}

@Test
@MainActor
func keepPreviousDataExposesPreviousValueWhileFetching() async {
    let client = QueryClient()
    let key = QueryKey<Int>("swiftui", "keep-previous")
    await client.setQueryData(key, 1)

    let state = QueryState(
        key: ["swiftui", "keep-previous"],
        options: QueryObserverOptions(
            placeholderData: .keepPreviousData,
            refetchOnSubscribe: .never
        )
    ) {
        try? await Task.sleep(nanoseconds: 200_000_000)
        return 2
    }

    state.start(using: client)
    #expect(await eventuallyOnMainActor { state.result?.data == 1 })

    state.refetch(using: client)
    #expect(await eventuallyOnMainActor { state.result?.isPlaceholderData == true })

    #expect(state.result?.data == 1)
    #expect(state.result?.isFetching == true)

    #expect(await eventuallyOnMainActor { state.result?.data == 2 })
    #expect(state.result?.isPlaceholderData == false)
    state.stop()
}
