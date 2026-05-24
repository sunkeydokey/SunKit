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

private func eventuallyOnMainActor(_ condition: @escaping @MainActor () -> Bool) async -> Bool {
    for _ in 0..<50 {
        if await MainActor.run(body: condition) {
            return true
        }

        try? await Task.sleep(nanoseconds: 20_000_000)
    }

    return false
}

private var immediateFetchOptions: QueryObserverOptions {
    QueryObserverOptions(
        refetchOnSubscribe: .always,
        refetchOnSceneActive: .never,
        refetchOnNetworkReconnect: .never
    )
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

    // Simulate scene becoming active
    NotificationCenter.default.post(name: QueryState<Int>.sceneActiveNotificationName, object: nil)

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
    let state = QueryState(
        key: ["swiftui", "late-response", "slow"],
        options: immediateFetchOptions
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
    let state = PaginatedQueryState<String, Int, String>(
        input: "ios",
        initialPage: 1,
        options: immediateFetchOptions,
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
    let state = PaginatedQueryState<String, Int, String>(
        input: "ios",
        initialPage: 1,
        options: immediateFetchOptions,
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

    let state = PaginatedQueryState<String, Int, String>(
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
    let state = PaginatedQueryState<String, Int, String>(
        input: "ios",
        initialPage: 1,
        options: immediateFetchOptions,
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
    let state = PaginatedQueryState<String, Int, String>(
        input: "ios",
        initialPage: 1,
        options: immediateFetchOptions,
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
    var state: QueryState<Int>? = QueryState(
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

    // Wait for all triggers to arm
    #expect(await eventuallyOnMainActor { state?.result?.data == 1 })

    // Release — deinit must not require a stop() call first
    state = nil

    // Give any lingering tasks a moment to complete
    try? await Task.sleep(nanoseconds: 100_000_000)

    // If deinit did not clean up, the weak ref may still be retained by a Task/Observer
    #expect(weakState == nil)
}
