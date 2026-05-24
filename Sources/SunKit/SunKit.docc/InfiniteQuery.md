# Infinite Queries

Use `InfiniteQuery` when one cache entry should accumulate multiple next pages.

## Overview

`InfiniteQuery` stores the full loaded page sequence under one typed key:
`QueryKey<InfiniteData<PageParam, Page>>`. Include filters, auth scope, locale,
endpoint, or other values that change the sequence in the base key.

```swift
let repositories = InfiniteQuery<Int, RepositoryPage>(
    key: ["github", "repositories", "swift"],
    initialPageParam: 1,
    getNextPageParam: { lastPage, pages in
        lastPage.hasMore ? pages.count + 1 : nil
    }
) { page in
    try await api.searchRepositories(query: "swift", page: page)
}

let firstPage = await client.fetchInfiniteQuery(repositories)
let firstTwoPages = await client.fetchNextPage(repositories)
```

`fetchInfiniteQuery(_:)` loads `initialPageParam` and replaces the accumulated
data with a single first page. `fetchNextPage(_:)` reads the current cached
`InfiniteData`, computes the next page parameter from the last page, fetches
that page, and appends it.

If no cached page exists, `fetchNextPage(_:)` loads the initial page. If
`getNextPageParam` returns `nil`, no fetch is started and the current cached
result is returned.

SwiftUI `InfiniteQueryState` can select a render value from the full accumulated
raw container. For example, a state can store
`InfiniteData<Int, RepositoryPage>` in the cache while exposing a flat
`[Repository]` to the view. Selection is observer-local; `hasNextPage` and
`fetchNextPage(using:)` continue to use the raw pages and
`getNextPageParam`.

## MVP Limitations

SunKit's MVP infinite-query model is next-page-only. It does not provide
previous-page fetches, max page counts, page eviction, reversed order, or
optimistic infinite updates.

Concurrent `fetchNextPage(_:)` calls for the same typed key join the same
in-flight task through the normal query dedupe path, so a next page is appended
once.
