import Testing
@testable import SunKit

private enum QueryTestError: Error {
    case failed
}

@Test func queryStoresTypedKey() {
    let key = QueryKey<Int>("value")
    let query = Query(key: key) { 1 }

    #expect(query.key == key)
}

@Test func queryDistinguishesOmittedOptionsFromExplicitOverride() {
    let key = QueryKey<Int>("value")
    let omitted = Query(key: key) { 1 }
    let explicit = Query(key: key, options: QueryOptions(retry: .never)) { 1 }

    #expect(omitted.options == nil)
    #expect(explicit.options == QueryOptions(retry: .never))
}

@Test func asyncQueryFetcherCanBeInvokedByCore() async throws {
    let query = Query(key: QueryKey<Int>("value")) {
        42
    }

    let value = try await query.fetch()

    #expect(value == 42)
}

@Test func completionQueryFetcherReturnsSuccess() async throws {
    let query = Query<Int>(key: QueryKey<Int>("value")) { completion in
        completion(.success(42))
    }

    let value = try await query.fetch()

    #expect(value == 42)
}

@Test func completionQueryFetcherReturnsFailure() async {
    let query = Query<Int>(key: QueryKey<Int>("value")) { completion in
        completion(.failure(QueryTestError.failed))
    }

    do {
        _ = try await query.fetch()
        Issue.record("Expected completion query fetcher to throw.")
    } catch {
        #expect(error is QueryTestError)
    }
}
