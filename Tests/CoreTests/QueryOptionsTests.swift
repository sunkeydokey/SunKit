import Foundation
import Testing
@testable import SunKit

@Test func defaultQueryOptionsMatchPlan() {
    let options = QueryOptions.default

    #expect(options.retry == .count(3))
    #expect(options.retryDelay == .exponential(maxDelay: 30))
}

@Test func queryOptionsInitializerStoresValues() {
    let options = QueryOptions(
        retry: .never,
        retryDelay: .fixed(2)
    )

    #expect(options.retry == .never)
    #expect(options.retryDelay == .fixed(2))
}

@Test func defaultQueryCacheOptionsMatchPlan() {
    let options = QueryCacheOptions.default

    #expect(options.staleTime == 0)
    #expect(options.gcTime == 300)
}

@Test func queryCacheOptionsInitializerStoresValues() {
    let options = QueryCacheOptions(staleTime: 10, gcTime: 60)

    #expect(options.staleTime == 10)
    #expect(options.gcTime == 60)
}

@Test func defaultQueryObserverOptionsMatchPlan() {
    let options = QueryObserverOptions<Int, Int>.default

    #expect(options.enabled)
    #expect(options.placeholderData == .none)
    #expect(options.refetchOnSubscribe == .ifStale)
    #expect(options.refetchOnSceneActive == .ifStale)
    #expect(options.refetchOnNetworkReconnect == .ifStale)
    #expect(options.refetchInterval == nil)
    #expect(options.select(1) == 1)
}

@Test func queryObserverOptionsInitializerStoresValues() {
    let options = QueryObserverOptions<Int, String>(
        enabled: false,
        placeholderData: .keepPreviousData,
        refetchOnSubscribe: .always,
        refetchOnSceneActive: .never,
        refetchOnNetworkReconnect: .always,
        refetchInterval: 15,
        select: { "\($0)" }
    )

    #expect(!options.enabled)
    #expect(options.placeholderData == .keepPreviousData)
    #expect(options.refetchOnSubscribe == .always)
    #expect(options.refetchOnSceneActive == .never)
    #expect(options.refetchOnNetworkReconnect == .always)
    #expect(options.refetchInterval == 15)
    #expect(options.select(42) == "42")
}
