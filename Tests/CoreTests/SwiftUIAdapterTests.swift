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

private actor PageFetchRecorder {
    private var calls: [String] = []

    func record(input: String, page: Int) -> String {
        calls.append("\(input)-\(page)")
        return "\(input)-\(page)"
    }

    func values() -> [String] {
        calls
    }
}

private enum SelectTestError: Error {
    case failed
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

private func immediateFetchOptions<Value: Sendable>() -> QueryObserverOptions<Value, Value> {
    QueryObserverOptions(
        refetchOnSubscribe: .always,
        refetchOnSceneActive: .never,
        refetchOnNetworkReconnect: .never
    )
}

@Test
@MainActor
func queryStateSelectExposesSelectedDataAndKeepsRawCache() async {
    let client = QueryClient()
    let rawKey = QueryKey<[Int]>("swiftui", "select", "raw-cache")
    let state = QueryState<[Int], String>(
        key: ["swiftui", "select", "raw-cache"],
        options: QueryObserverOptions(
            refetchOnSubscribe: .always,
            refetchOnSceneActive: .never,
            refetchOnNetworkReconnect: .never,
            select: { $0.map(String.init).joined(separator: ",") }
        )
    ) {
        [1, 2, 3]
    }

    state.start(using: client)

    #expect(await eventuallyOnMainActor { state.result?.data == "1,2,3" })
    #expect(await client.getQueryData(rawKey) == [1, 2, 3])
    state.stop()
}

@Test
@MainActor
func queryStateSelectAppliesToCurrentCachedValue() async {
    let client = QueryClient()
    let key = QueryKey<[String]>("swiftui", "select", "cached")
    await client.setQueryData(key, ["cached", "value"])
    let state = QueryState<[String], Int>(
        key: ["swiftui", "select", "cached"],
        options: QueryObserverOptions(
            refetchOnSubscribe: .never,
            refetchOnSceneActive: .never,
            refetchOnNetworkReconnect: .never,
            select: { $0.count }
        )
    ) {
        ["fresh"]
    }

    state.start(using: client)

    #expect(await eventuallyOnMainActor { state.result?.data == 2 })
    state.stop()
}

@Test
@MainActor
func queryStateSelectAppliesToStaleDataAfterRefetchFailure() async {
    let client = QueryClient()
    let key = QueryKey<[Int]>("swiftui", "select", "failure-stale")
    await client.setQueryData(key, [4, 5])
    let state = QueryState<[Int], Int>(
        key: ["swiftui", "select", "failure-stale"],
        queryOptions: QueryOptions(retry: .never),
        options: QueryObserverOptions(
            refetchOnSubscribe: .always,
            refetchOnSceneActive: .never,
            refetchOnNetworkReconnect: .never,
            select: { $0.reduce(0, +) }
        )
    ) {
        throw SelectTestError.failed
    }

    state.start(using: client)

    #expect(await eventuallyOnMainActor {
        state.result?.isError == true && state.result?.data == 9
    })
    state.stop()
}

@Test
@MainActor
func queryStateSelectUsesSelectedPreviousDataAsPlaceholder() async {
    let client = QueryClient()
    let key = QueryKey<[Int]>("swiftui", "select", "placeholder")
    await client.setQueryData(key, [1, 2])
    let state = QueryState<[Int], String>(
        key: ["swiftui", "select", "placeholder"],
        options: QueryObserverOptions(
            placeholderData: .keepPreviousData,
            refetchOnSubscribe: .never,
            refetchOnSceneActive: .never,
            refetchOnNetworkReconnect: .never,
            select: { $0.map(String.init).joined(separator: "-") }
        )
    ) {
        try? await Task.sleep(nanoseconds: 200_000_000)
        return [3, 4]
    }

    state.start(using: client)
    #expect(await eventuallyOnMainActor { state.result?.data == "1-2" })

    state.refetch(using: client)

    #expect(await eventuallyOnMainActor {
        state.result?.isPlaceholderData == true && state.result?.data == "1-2"
    })
    #expect(await eventuallyOnMainActor { state.result?.data == "3-4" })
    state.stop()
}

@Test
@MainActor
func paginatedQueryStateSelectsUpdatedPageData() async {
    let client = QueryClient()
    let state = PaginatedQueryState<String, Int, String, Int>(
        input: "ios",
        initialPage: 1,
        options: QueryObserverOptions(
            refetchOnSubscribe: .always,
            refetchOnSceneActive: .never,
            refetchOnNetworkReconnect: .never,
            select: { $0.count }
        ),
        key: { input, page in ["select-page", AnyQueryKeyPart(input), AnyQueryKeyPart(page)] },
        nextPage: { $0 + 1 },
        previousPage: { $0 - 1 },
        canMoveToPreviousPage: { $0 > 1 }
    ) { input, page in
        "\(input)-\(page)"
    }

    state.start(using: client)
    #expect(await eventuallyOnMainActor { state.result?.data == 5 })

    state.nextPage(using: client)

    #expect(await eventuallyOnMainActor { state.page == 2 && state.result?.data == 5 })
    state.stop()
}

@Test
@MainActor
func queryStateReceivesCurrentCachedValue() async {
    let client = QueryClient()
    let key = QueryKey<String>("swiftui", "cached")
    await client.setQueryData(key, "cached")

    let state = QueryState(
        key: ["swiftui", "cached"],
        options: QueryObserverOptions(
            refetchOnSubscribe: .never,
            refetchOnSceneActive: .never,
            refetchOnNetworkReconnect: .never
        )
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
func queryStateIfStaleSubscribeDoesNotFetchFreshCachedData() async {
    let client = QueryClient(defaultCacheOptions: QueryCacheOptions(staleTime: 60))
    let key = QueryKey<Int>("swiftui", "if-stale", "fresh")
    let counter = SwiftUIFetchCounter()
    await client.setQueryData(key, 42)

    let state = QueryState(
        key: ["swiftui", "if-stale", "fresh"],
        options: QueryObserverOptions(
            refetchOnSubscribe: .ifStale,
            refetchOnSceneActive: .never,
            refetchOnNetworkReconnect: .never
        )
    ) {
        await counter.next()
    }

    state.start(using: client)

    #expect(await eventuallyOnMainActor { state.result?.data == 42 })
    try? await Task.sleep(nanoseconds: 100_000_000)
    #expect(await counter.value() == 0)
    state.stop()
}

@Test
@MainActor
func queryStateIfStaleSubscribeFetchesStaleCachedData() async {
    let client = QueryClient(defaultCacheOptions: QueryCacheOptions(staleTime: 0))
    let key = QueryKey<Int>("swiftui", "if-stale", "stale")
    let counter = SwiftUIFetchCounter()
    await client.setQueryData(key, 42)

    let state = QueryState(
        key: ["swiftui", "if-stale", "stale"],
        options: QueryObserverOptions(
            refetchOnSubscribe: .ifStale,
            refetchOnSceneActive: .never,
            refetchOnNetworkReconnect: .never
        )
    ) {
        await counter.next()
    }

    state.start(using: client)

    #expect(await eventuallyOnMainActor { state.result?.data == 1 })
    #expect(await counter.value() == 1)
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
    // Wait for cached value to arrive
    #expect(await eventuallyOnMainActor { state.result?.data == 1 })

    // Trigger a refetch — state should show previous data as placeholder
    state.refetch(using: client)
    #expect(await eventuallyOnMainActor { state.result?.isPlaceholderData == true })

    #expect(state.result?.data == 1)
    #expect(state.result?.isFetching == true)

    // Wait for fetch to complete
    #expect(await eventuallyOnMainActor { state.result?.data == 2 })
    #expect(state.result?.isPlaceholderData == false)
    state.stop()
}

@Test
@MainActor
func refetchIntervalTriggersPeriodicRefetch() async {
    let client = QueryClient()
    let counter = SwiftUIFetchCounter()
    let state = QueryState(
        key: ["swiftui", "interval"],
        options: QueryObserverOptions(
            refetchInterval: 0.05
        )
    ) {
        await counter.next()
    }

    state.start(using: client)

    // After ~150ms we expect at least 2 fetches (initial + ≥1 interval refetch)
    try? await Task.sleep(nanoseconds: 150_000_000)

    let fetchCount = await counter.value()
    #expect(fetchCount >= 2)
    state.stop()

    // After stop, no more fetches
    let countAfterStop = await counter.value()
    try? await Task.sleep(nanoseconds: 100_000_000)
    #expect(await counter.value() == countAfterStop)
}

@Test
@MainActor
func refetchIntervalDoesNotPreventSlowFetchCompletion() async {
    let client = QueryClient()
    let counter = SwiftUIFetchCounter()
    let state = QueryState(
        key: ["swiftui", "slow-interval"],
        options: QueryObserverOptions(
            refetchOnSceneActive: .never,
            refetchOnNetworkReconnect: .never,
            refetchInterval: 0.05
        )
    ) {
        let value = await counter.next()
        try? await Task.sleep(nanoseconds: 180_000_000)
        return value
    }

    state.start(using: client)

    #expect(await eventuallyOnMainActor { state.result?.data == 1 })
    state.stop()
}

@Test
@MainActor
func refetchOnSceneActiveAlwaysRefetchesOnNotification() async {
    let client = QueryClient(defaultCacheOptions: QueryCacheOptions(staleTime: 60))
    let counter = SwiftUIFetchCounter()
    let state = QueryState(
        key: ["swiftui", "scene-active"],
        options: QueryObserverOptions(
            refetchOnSubscribe: .always,
            refetchOnSceneActive: .always
        )
    ) {
        await counter.next()
    }

    state.start(using: client)
    #expect(await eventuallyOnMainActor { state.result?.data == 1 })
    try? await Task.sleep(nanoseconds: 20_000_000)

    // Simulate scene becoming active
    NotificationCenter.default.post(name: QueryState<Int, Int>.sceneActiveNotificationName, object: nil)

    #expect(await eventuallyOnMainActor { state.result?.data == 2 })
    state.stop()
}

@Test
@MainActor
func networkReconnectNeverPolicyDoesNotRefetch() async {
    let client = QueryClient()
    let counter = SwiftUIFetchCounter()
    let state = QueryState(
        key: ["swiftui", "network-never"],
        options: QueryObserverOptions(
            refetchOnSubscribe: .always,
            refetchOnSceneActive: .never,
            refetchOnNetworkReconnect: .never
        )
    ) {
        await counter.next()
    }

    state.start(using: client)
    #expect(await eventuallyOnMainActor { state.result?.data == 1 })

    // Even if path monitor fires, no extra fetches should occur with .never
    try? await Task.sleep(nanoseconds: 100_000_000)
    #expect(await counter.value() == 1)
    state.stop()
}

@Test
@MainActor
func queryStateIgnoresStaleOnlyPublication() async {
    let client = QueryClient(defaultCacheOptions: QueryCacheOptions(staleTime: 0.02))
    let counter = SwiftUIFetchCounter()
    let state = QueryState(
        key: ["swiftui", "stale-time"],
        options: QueryObserverOptions(
            refetchOnSubscribe: .always,
            refetchOnSceneActive: .ifStale,
            refetchOnNetworkReconnect: .never
        )
    ) {
        await counter.next()
    }

    state.start(using: client)

    #expect(await eventuallyOnMainActor { state.result?.data == 1 && state.result?.isStale == false })
    let becameStale = await eventually {
        await client.isQueryStale(QueryKey<Int>("swiftui", "stale-time"))
    }
    #expect(becameStale)
    #expect(state.result?.isStale == false)

    NotificationCenter.default.post(
        name: QueryState<Int, Int>.sceneActiveNotificationName,
        object: nil
    )

    #expect(await eventuallyOnMainActor { state.result?.data == 2 })
    #expect(await counter.value() == 2)
    state.stop()
}

@Test
@MainActor
func queryStateKeyUpdateSwitchesSubscriptionToNewKey() async {
    let client = QueryClient()
    let oldKey = QueryKey<String>("swiftui", "dynamic", "old")
    let newKey = QueryKey<String>("swiftui", "dynamic", "new")
    await client.setQueryData(oldKey, "old")
    await client.setQueryData(newKey, "new")

    let state = QueryState(
        key: ["swiftui", "dynamic", "old"],
        options: QueryObserverOptions(
            refetchOnSubscribe: .never,
            refetchOnSceneActive: .never,
            refetchOnNetworkReconnect: .never
        )
    ) {
        "unused-old"
    }

    state.start(using: client)
    #expect(await eventuallyOnMainActor { state.result?.data == "old" })

    state.update(key: ["swiftui", "dynamic", "new"], using: client) {
        "unused-new"
    }

    #expect(await eventuallyOnMainActor { state.result?.data == "new" })

    await client.setQueryData(oldKey, "old-update")
    try? await Task.sleep(nanoseconds: 100_000_000)
    #expect(state.result?.data == "new")

    await client.setQueryData(newKey, "new-update")
    #expect(await eventuallyOnMainActor { state.result?.data == "new-update" })
    state.stop()
}

@Test
@MainActor
func queryStateKeyUpdateDoesNotUsePreviousKeyDataAsPlaceholder() async {
    let client = QueryClient()
    let state = QueryState(
        key: ["swiftui", "placeholder-scope", "old"],
        options: QueryObserverOptions(
            placeholderData: .keepPreviousData,
            refetchOnSubscribe: .always,
            refetchOnSceneActive: .never,
            refetchOnNetworkReconnect: .never
        )
    ) {
        "old"
    }

    state.start(using: client)
    #expect(await eventuallyOnMainActor { state.result?.data == "old" })

    state.update(key: ["swiftui", "placeholder-scope", "new"], using: client) {
        try? await Task.sleep(nanoseconds: 200_000_000)
        return "new"
    }

    #expect(await eventuallyOnMainActor { state.result?.isPending == true })
    #expect(state.result?.data == nil)
    #expect(state.result?.isPlaceholderData == false)

    #expect(await eventuallyOnMainActor { state.result?.data == "new" })
    state.stop()
}

@Test
@MainActor
func queryStateSameKeyUpdateKeepsSubscriptionAndUsesNewFetcher() async {
    let client = QueryClient()
    let key = QueryKey<String>("swiftui", "same-key-update")
    await client.setQueryData(key, "cached")

    let state = QueryState(
        key: ["swiftui", "same-key-update"],
        options: QueryObserverOptions(
            refetchOnSubscribe: .never,
            refetchOnSceneActive: .never,
            refetchOnNetworkReconnect: .never
        )
    ) {
        "old-fetch"
    }

    state.start(using: client)
    #expect(await eventuallyOnMainActor { state.result?.data == "cached" })

    state.update(key: ["swiftui", "same-key-update"], using: client) {
        "new-fetch"
    }
    state.refetch(using: client)

    #expect(await eventuallyOnMainActor { state.result?.data == "new-fetch" })

    await client.setQueryData(key, "subscription-still-active")
    #expect(await eventuallyOnMainActor { state.result?.data == "subscription-still-active" })
    state.stop()
}

@Test
@MainActor
func queryStateLateOldKeyResponseDoesNotOverwriteCurrentKey() async {
    let client = QueryClient()
    let state = QueryState<String, String>(
        key: ["swiftui", "late-response", "slow"],
        options: immediateFetchOptions()
    ) {
        try? await Task.sleep(nanoseconds: 200_000_000)
        return "slow"
    }

    state.start(using: client)
    #expect(await eventuallyOnMainActor { state.result?.isPending == true })

    state.update(key: ["swiftui", "late-response", "fast"], using: client) {
        "fast"
    }

    #expect(await eventuallyOnMainActor { state.result?.data == "fast" })
    try? await Task.sleep(nanoseconds: 250_000_000)
    #expect(state.result?.data == "fast")
    state.stop()
}

@Test
@MainActor
func paginatedQueryStateFetchesWhenPageChanges() async {
    let client = QueryClient()
    let recorder = PageFetchRecorder()
    let state = PaginatedQueryState<String, Int, String, String>(
        input: "ios",
        initialPage: 1,
        options: immediateFetchOptions(),
        key: { input, page in ["search", AnyQueryKeyPart(input), AnyQueryKeyPart(page)] },
        nextPage: { $0 + 1 },
        previousPage: { $0 - 1 },
        canMoveToPreviousPage: { $0 > 1 }
    ) { input, page in
        await recorder.record(input: input, page: page)
    }

    state.start(using: client)
    #expect(await eventuallyOnMainActor { state.result?.data == "ios-1" })

    state.nextPage(using: client)

    #expect(await eventuallyOnMainActor { state.page == 2 && state.result?.data == "ios-2" })
    #expect(await recorder.values() == ["ios-1", "ios-2"])
    state.stop()
}

@Test
@MainActor
func paginatedQueryStateInputChangeResetsToInitialPage() async {
    let client = QueryClient()
    let recorder = PageFetchRecorder()
    let state = PaginatedQueryState<String, Int, String, String>(
        input: "ios",
        initialPage: 1,
        options: immediateFetchOptions(),
        key: { input, page in ["search-reset", AnyQueryKeyPart(input), AnyQueryKeyPart(page)] },
        nextPage: { $0 + 1 },
        previousPage: { $0 - 1 },
        canMoveToPreviousPage: { $0 > 1 }
    ) { input, page in
        await recorder.record(input: input, page: page)
    }

    state.start(using: client)
    #expect(await eventuallyOnMainActor { state.result?.data == "ios-1" })
    state.nextPage(using: client)
    #expect(await eventuallyOnMainActor { state.result?.data == "ios-2" })

    state.setInput("swift", using: client)

    #expect(await eventuallyOnMainActor { state.input == "swift" && state.page == 1 && state.result?.data == "swift-1" })
    #expect(await recorder.values() == ["ios-1", "ios-2", "swift-1"])
    state.stop()
}

@Test
@MainActor
func paginatedQueryStateRevisitingPageUsesClientCache() async {
    let client = QueryClient()
    let recorder = PageFetchRecorder()
    let cachedKey = QueryKey<String>("search-cache", "ios", 1)
    await client.setQueryData(cachedKey, "cached-ios-1")

    let state = PaginatedQueryState<String, Int, String, String>(
        input: "ios",
        initialPage: 1,
        options: QueryObserverOptions(
            refetchOnSubscribe: .never,
            refetchOnSceneActive: .never,
            refetchOnNetworkReconnect: .never
        ),
        key: { input, page in ["search-cache", AnyQueryKeyPart(input), AnyQueryKeyPart(page)] },
        nextPage: { $0 + 1 },
        previousPage: { $0 - 1 },
        canMoveToPreviousPage: { $0 > 1 }
    ) { input, page in
        await recorder.record(input: input, page: page)
    }

    state.start(using: client)
    #expect(await eventuallyOnMainActor { state.result?.data == "cached-ios-1" })

    state.nextPage(using: client)
    try? await Task.sleep(nanoseconds: 100_000_000)
    #expect(state.page == 2)

    state.previousPage(using: client)

    #expect(await eventuallyOnMainActor { state.page == 1 && state.result?.data == "cached-ios-1" })
    #expect(await recorder.values().isEmpty)
    state.stop()
}

@Test
@MainActor
func paginatedQueryStatePreviousPageGuardPreventsInvalidPage() async {
    let client = QueryClient()
    let recorder = PageFetchRecorder()
    let state = PaginatedQueryState<String, Int, String, String>(
        input: "ios",
        initialPage: 1,
        options: immediateFetchOptions(),
        key: { input, page in ["search-previous-guard", AnyQueryKeyPart(input), AnyQueryKeyPart(page)] },
        nextPage: { $0 + 1 },
        previousPage: { $0 - 1 },
        canMoveToPreviousPage: { $0 > 1 }
    ) { input, page in
        await recorder.record(input: input, page: page)
    }

    state.start(using: client)
    #expect(await eventuallyOnMainActor { state.result?.data == "ios-1" })

    state.previousPage(using: client)

    try? await Task.sleep(nanoseconds: 100_000_000)
    #expect(state.page == 1)
    #expect(state.result?.data == "ios-1")
    #expect(await recorder.values() == ["ios-1"])
    state.stop()
}

@Test
@MainActor
func paginatedQueryStateLatePreviousPageResponseDoesNotOverwriteCurrentPage() async {
    let client = QueryClient()
    let state = PaginatedQueryState<String, Int, String, String>(
        input: "ios",
        initialPage: 1,
        options: immediateFetchOptions(),
        key: { input, page in ["search-late", AnyQueryKeyPart(input), AnyQueryKeyPart(page)] },
        nextPage: { $0 + 1 },
        previousPage: { $0 - 1 },
        canMoveToPreviousPage: { $0 > 1 }
    ) { input, page in
        if page == 1 {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return "\(input)-\(page)"
    }

    state.start(using: client)
    #expect(await eventuallyOnMainActor { state.result?.isPending == true })

    state.nextPage(using: client)

    #expect(await eventuallyOnMainActor { state.page == 2 && state.result?.data == "ios-2" })
    try? await Task.sleep(nanoseconds: 250_000_000)
    #expect(state.page == 2)
    #expect(state.result?.data == "ios-2")
    state.stop()
}

@Test
@MainActor
func stopPreventsGhostUpdatesFromQueuedCallbacks() async {
    let client = QueryClient()
    let key = QueryKey<Int>("lifecycle", "ghost")
    await client.setQueryData(key, 1)

    let state = QueryState(
        key: ["lifecycle", "ghost"],
        options: QueryObserverOptions(
            refetchOnSubscribe: .never,
            refetchOnSceneActive: .never,
            refetchOnNetworkReconnect: .never
        )
    ) { 99 }

    state.start(using: client)
    #expect(await eventuallyOnMainActor { state.result?.data == 1 })

    // Enqueue an update to the cache and stop() on the same actor turn —
    // the delivery task is already scheduled but stop() must prevent it applying.
    Task {
        await client.setQueryData(key, 2)
    }
    state.stop()

    try? await Task.sleep(nanoseconds: 100_000_000)
    #expect(state.result?.data == 1)
}

@Test
@MainActor
func rapidStartStopStartDoesNotDeliverStaleCallbacks() async {
    let client = QueryClient()
    let counter = SwiftUIFetchCounter()
    let state = QueryState(
        key: ["lifecycle", "rapid"],
        options: QueryObserverOptions(
            refetchOnSubscribe: .always,
            refetchOnSceneActive: .never,
            refetchOnNetworkReconnect: .never
        )
    ) {
        await counter.next()
    }

    // Rapid start-stop-start
    state.start(using: client)
    state.stop()
    state.start(using: client)

    #expect(await eventuallyOnMainActor { state.result?.data != nil })

    // Result must reflect only the last start's fetch, not multiple deliveries
    let seen = state.result?.data
    try? await Task.sleep(nanoseconds: 100_000_000)
    #expect(state.result?.data == seen)
    state.stop()
}

@Test
@MainActor
func refetchBeforeSubscriptionSetupCompletesStillReceivesCacheUpdates() async {
    let client = QueryClient()
    let key = QueryKey<String>("lifecycle", "refetch-race")

    let state = QueryState(
        key: ["lifecycle", "refetch-race"],
        options: QueryObserverOptions(
            refetchOnSubscribe: .never,
            refetchOnSceneActive: .never,
            refetchOnNetworkReconnect: .never
        )
    ) { "fetched" }

    // start() then immediately refetch() before subscription setup can complete
    state.start(using: client)
    state.refetch(using: client)

    // Subscription must eventually be active: a setQueryData must be delivered
    #expect(await eventuallyOnMainActor { state.result?.data == "fetched" })
    await client.setQueryData(key, "updated")
    #expect(await eventuallyOnMainActor { state.result?.data == "updated" })
    state.stop()
}

@Test
@MainActor
func queryStateDeinitCleansUpAllResources() async {
    let client = QueryClient()
    var state: QueryState<Int, Int>? = QueryState(
        key: ["lifecycle", "deinit"],
        options: QueryObserverOptions(
            refetchOnSubscribe: .always,
            refetchOnSceneActive: .always,
            refetchOnNetworkReconnect: .always,
            refetchInterval: 60
        )
    ) { 1 }

    weak var weakState = state
    state?.start(using: client)

    // Wait for interval timer, scene observer, and network monitor to arm
    #expect(await eventuallyOnMainActor { state?.result?.data == 1 })

    // Release without calling stop() — deinit must cancel all resources so
    // the object is not kept alive by a strong reference in any closure
    state = nil
    try? await Task.sleep(nanoseconds: 100_000_000)

    // The weak reference must be nil: if intervalTask, sceneActiveObserver,
    // or pathMonitor held a strong reference, the object would still be alive
    #expect(weakState == nil)

    // Verify the scene-active observer was removed: posting the notification
    // after deallocation must not cause any crash or unexpected side effects
    NotificationCenter.default.post(
        name: QueryState<Int, Int>.sceneActiveNotificationName,
        object: nil
    )
    try? await Task.sleep(nanoseconds: 50_000_000)
    // If we reach here without a crash, the observer was safely cleaned up
    #expect(weakState == nil)
}

@Test
@MainActor
func subscriptionCancelDoesNotAbortInFlightFetch() async {
    let client = QueryClient()
    let counter = SwiftUIFetchCounter()

    // Two states subscribe to the same key — the fetch is shared (in-flight dedup)
    let stateA = QueryState(
        key: ["cancellation", "inflight"],
        options: QueryObserverOptions(
            refetchOnSubscribe: .always,
            refetchOnSceneActive: .never,
            refetchOnNetworkReconnect: .never
        )
    ) {
        try? await Task.sleep(nanoseconds: 200_000_000)
        return await counter.next()
    }

    let stateB = QueryState(
        key: ["cancellation", "inflight"],
        options: QueryObserverOptions(
            refetchOnSubscribe: .never,
            refetchOnSceneActive: .never,
            refetchOnNetworkReconnect: .never
        )
    ) {
        await counter.next()
    }

    stateA.start(using: client)
    stateB.start(using: client)

    // Wait until fetch starts (stateA should be pending)
    #expect(await eventuallyOnMainActor { stateA.result?.isFetching == true })

    // Cancel stateA's subscription — in-flight must continue for stateB
    stateA.stop()

    // stateB must still receive the result
    #expect(await eventuallyOnMainActor { stateB.result?.data == 1 })

    // Fetch ran exactly once (shared in-flight dedup)
    #expect(await counter.value() == 1)
    stateB.stop()
}

@Test
@MainActor
func queryStateEnabledFalseToTrueViaUpdateStartsFetch() async {
    let client = QueryClient()
    let counter = SwiftUIFetchCounter()
    let state = QueryState(
        key: ["swiftui", "enabled-transition"],
        options: QueryObserverOptions(
            enabled: false,
            refetchOnSubscribe: .always,
            refetchOnSceneActive: .never,
            refetchOnNetworkReconnect: .never
        )
    ) {
        await counter.next()
    }

    state.start(using: client)
    try? await Task.sleep(nanoseconds: 50_000_000)
    #expect(await counter.value() == 0)

    state.update(
        key: ["swiftui", "enabled-transition"],
        using: client,
        fetch: { await counter.next() },
        enabled: true
    )

    #expect(await eventuallyOnMainActor { state.result?.data != nil })
    #expect(await counter.value() == 1)
    state.stop()
}

@Test
@MainActor
func queryStateEnabledTrueToFalseViaUpdateStopsIntervalTimer() async {
    let client = QueryClient()
    let counter = SwiftUIFetchCounter()
    let state = QueryState(
        key: ["swiftui", "enabled-disable"],
        options: QueryObserverOptions(
            enabled: true,
            refetchOnSubscribe: .always,
            refetchOnSceneActive: .never,
            refetchOnNetworkReconnect: .never,
            refetchInterval: 0.05
        )
    ) {
        await counter.next()
    }

    state.start(using: client)
    #expect(await eventuallyOnMainActor { state.result?.data != nil })

    let countAfterStart = await counter.value()

    state.update(
        key: ["swiftui", "enabled-disable"],
        using: client,
        fetch: { await counter.next() },
        enabled: false
    )

    try? await Task.sleep(nanoseconds: 200_000_000)
    let countAfterDisable = await counter.value()
    #expect(countAfterDisable == countAfterStart)
    state.stop()
}

@Test
@MainActor
func queryStateEnabledTrueToFalseViaUpdateStillReceivesCachePublications() async {
    let client = QueryClient()
    let rawKey = QueryKey<Int>("swiftui", "enabled-disable-receives")
    let state = QueryState(
        key: ["swiftui", "enabled-disable-receives"],
        options: QueryObserverOptions(
            enabled: true,
            refetchOnSubscribe: .never,
            refetchOnSceneActive: .never,
            refetchOnNetworkReconnect: .never
        )
    ) { 1 }

    state.start(using: client)

    state.update(
        key: ["swiftui", "enabled-disable-receives"],
        using: client,
        fetch: { 1 },
        enabled: false
    )

    // Push data directly into cache — disabled observer should still receive it
    await client.setQueryData(rawKey, 42)

    #expect(await eventuallyOnMainActor { state.result?.data == 42 })
    state.stop()
}

@Test
@MainActor
func infiniteQueryStateEnabledFalseToTrueViaUpdateStartsFetch() async {
    let client = QueryClient()
    let counter = SwiftUIFetchCounter()
    let query = InfiniteQuery(
        key: ["swiftui", "infinite-enabled-transition"],
        initialPageParam: 0,
        getNextPageParam: { _, _ in nil }
    ) { _ in
        await counter.next()
    }
    let options = QueryObserverOptions<InfiniteData<Int, Int>, InfiniteData<Int, Int>>(
        enabled: false,
        refetchOnSubscribe: .always,
        refetchOnSceneActive: .never,
        refetchOnNetworkReconnect: .never
    )
    let state = InfiniteQueryState(query: query, options: options)

    state.start(using: client)
    try? await Task.sleep(nanoseconds: 50_000_000)
    #expect(await counter.value() == 0)

    let enabledQuery = InfiniteQuery(
        key: ["swiftui", "infinite-enabled-transition"],
        initialPageParam: 0,
        getNextPageParam: { _, _ in nil }
    ) { _ in
        await counter.next()
    }
    state.update(query: enabledQuery, using: client, enabled: true)

    #expect(await eventuallyOnMainActor { state.result?.data != nil })
    #expect(await counter.value() == 1)
    state.stop()
}

// MARK: - QueryObject tests

@Test
@MainActor
func queryObjectBindingConfiguresAndFetchesState() async {
    let client = QueryClient()
    let queryObject = QueryObject<String, String>(
        options: QueryObserverOptions(
            refetchOnSubscribe: .always,
            refetchOnSceneActive: .never,
            refetchOnNetworkReconnect: .never
        )
    )
    let state = queryObject.wrappedValue

    queryObject.projectedValue.apply(
        key: ["query-object", "basic"],
        using: client,
        fetch: { "value" },
        enabled: true
    )

    #expect(await eventuallyOnMainActor { state.result?.data == "value" })
    state.stop()
}

@Test
@MainActor
func queryObjectBindingUpdatesKeyAndFetcher() async {
    let client = QueryClient()
    let queryObject = QueryObject<String, String>(
        options: QueryObserverOptions(
            refetchOnSubscribe: .always,
            refetchOnSceneActive: .never,
            refetchOnNetworkReconnect: .never
        )
    )
    let state = queryObject.wrappedValue

    queryObject.projectedValue.apply(
        key: ["query-object", "first"],
        using: client,
        fetch: { "first" },
        enabled: true
    )
    #expect(await eventuallyOnMainActor { state.result?.data == "first" })

    queryObject.projectedValue.apply(
        key: ["query-object", "second"],
        using: client,
        fetch: { "second" },
        enabled: true
    )

    #expect(await eventuallyOnMainActor { state.result?.data == "second" })
    state.stop()
}

@Test
@MainActor
func queryObjectBindingEnabledTransitionStartsFetchForSameKey() async {
    let client = QueryClient()
    let counter = SwiftUIFetchCounter()
    let queryObject = QueryObject<Int, Int>(
        options: QueryObserverOptions(
            refetchOnSubscribe: .always,
            refetchOnSceneActive: .never,
            refetchOnNetworkReconnect: .never
        )
    )
    let state = queryObject.wrappedValue

    queryObject.projectedValue.apply(
        key: ["query-object", "enabled"],
        using: client,
        fetch: { await counter.next() },
        enabled: false
    )
    try? await Task.sleep(nanoseconds: 50_000_000)
    #expect(await counter.value() == 0)

    queryObject.projectedValue.apply(
        key: ["query-object", "enabled"],
        using: client,
        fetch: { await counter.next() },
        enabled: true
    )

    #expect(await eventuallyOnMainActor { state.result?.data == 1 })
    #expect(await counter.value() == 1)
    state.stop()
}

@Test
@MainActor
func queryStateKeyChangeUsesCurrentEnabledState() async {
    let client = QueryClient()
    let state = QueryState<String, String>(
        key: ["swiftui", "current-enabled", "initial"],
        options: QueryObserverOptions(
            enabled: false,
            refetchOnSubscribe: .always,
            refetchOnSceneActive: .never,
            refetchOnNetworkReconnect: .never
        )
    ) { "initial" }

    state.update(
        key: ["swiftui", "current-enabled", "updated"],
        using: client,
        fetch: { "updated" },
        enabled: true
    )

    #expect(await eventuallyOnMainActor { state.result?.data == "updated" })
    state.stop()
}
