# Query Results

Read query state from `QueryResult` snapshots.

## Overview

`QueryResult` is a Core-owned snapshot of a query's observable state. SunKit
creates these values through query APIs such as fetching, subscriptions, and
future adapters. Package users read the public projection properties instead of
constructing query results directly.

`QueryStatus` is also Core-owned. You can read the `status` value from a
`QueryResult`, but status values are not an enum surface for package users to
construct or switch over. Branch UI and cache logic with `QueryResult`
projections such as `isPending`, `isFetching`, `isSuccess`, `isError`, `data`,
`error`, and `failureCount`.

Use `data` to read the latest available value. When an initial fetch fails,
`data` is `nil`. When a refetch fails after data already exists, `data` keeps
the stale value and `error` describes the latest failure. Fetch failures do not
mark cache entries invalidated by themselves.

`isStale` describes this result snapshot. It can be `true` because the cache
entry became stale, because an explicit invalidation marked the delivered data
stale, or because a failed refetch is exposing stale data. Use
`QueryClient.isQueryStale(_:)` when you need to ask the client about the
current cache entry's freshness.

## Pending and Fetching

`isPending` describes whether the query is still waiting for successful data.
`isFetching` describes whether a fetch task is currently running. These
projections are independent.

Subscribing to a query does not start a fetch. A new query can therefore publish
its current value as pending while `isFetching` remains `false`.

| Situation | `isPending` | `isFetching` | Notes |
| --- | --- | --- | --- |
| New query before any fetch starts | `true` | `false` | `data` is `nil`. |
| Initial fetch running | `true` | `true` | The query is waiting for its first successful data. |
| Successful data available | `false` | `false` | `data` contains the current value. |
| Background refetch with successful data | `false` | `true` | Existing data remains available during the refetch. |
| Refetch failed with stale data | `false` | `false` | `isError` is `true`, and `data` keeps the stale value. |

```swift
let result = await client.fetchQuery(query)

if result.isSuccess {
    render(result.data)
}

if result.isError {
    showError(result.error)
}
```
