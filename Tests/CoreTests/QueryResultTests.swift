import Foundation
import Testing
@testable import SunKit

private enum TestError: Error {
    case failed
}

@Test func idleQueryResultHasNoDataOrError() {
    let result = QueryResult<String>(status: .idle)

    #expect(result.data == nil)
    #expect(result.error == nil)
    #expect(!result.isPending)
    #expect(!result.isSuccess)
    #expect(!result.isError)
    #expect(!result.isFetching)
    #expect(!result.isStale)
    #expect(!result.isPlaceholderData)
    #expect(result.updatedAt == nil)
    #expect(result.failureCount == 0)
}

@Test func pendingQueryResultWithoutPreviousDataHasNoData() {
    let result = QueryResult<String>(status: .pending(previous: nil), isFetching: true)

    #expect(result.data == nil)
    #expect(result.error == nil)
    #expect(result.isPending)
    #expect(!result.isSuccess)
    #expect(!result.isError)
    #expect(result.isFetching)
    #expect(result.failureCount == 0)
}

@Test func pendingQueryResultWithPreviousDataExposesPreviousData() {
    let result = QueryResult(status: QueryStatus.success("cached"))
    let pending = QueryResult(status: QueryStatus.pending(previous: result.data))

    #expect(pending.data == "cached")
    #expect(pending.error == nil)
    #expect(pending.isPending)
    #expect(!pending.isSuccess)
    #expect(!pending.isError)
    #expect(pending.failureCount == 0)
}

@Test func successfulQueryResultExposesData() {
    let updatedAt = Date()
    let result = QueryResult(
        status: QueryStatus.success("fresh"),
        isStale: false,
        updatedAt: updatedAt
    )

    #expect(result.data == "fresh")
    #expect(result.error == nil)
    #expect(!result.isPending)
    #expect(result.isSuccess)
    #expect(!result.isError)
    #expect(!result.isFetching)
    #expect(!result.isStale)
    #expect(result.updatedAt == updatedAt)
    #expect(result.failureCount == 0)
}

@Test func failedQueryResultWithoutStaleDataExposesErrorOnly() {
    let result = QueryResult<String>(
        status: .failure(TestError.failed, stale: nil, failureCount: 1)
    )

    #expect(result.data == nil)
    #expect(result.error is TestError)
    #expect(!result.isPending)
    #expect(!result.isSuccess)
    #expect(result.isError)
    #expect(result.failureCount == 1)
}

@Test func failedQueryResultWithStaleDataKeepsDataAvailable() {
    let result = QueryResult(
        status: QueryStatus.failure(TestError.failed, stale: "stale", failureCount: 2)
    )

    #expect(result.data == "stale")
    #expect(result.error is TestError)
    #expect(!result.isPending)
    #expect(!result.isSuccess)
    #expect(result.isError)
    #expect(result.failureCount == 2)
}

@Test func queryResultPreservesFetchAndCacheFlags() {
    let updatedAt = Date()
    let result = QueryResult(
        status: QueryStatus.success("placeholder"),
        isFetching: true,
        isStale: true,
        isPlaceholderData: true,
        updatedAt: updatedAt
    )

    #expect(result.data == "placeholder")
    #expect(result.isSuccess)
    #expect(result.isFetching)
    #expect(result.isStale)
    #expect(result.isPlaceholderData)
    #expect(result.updatedAt == updatedAt)
}
