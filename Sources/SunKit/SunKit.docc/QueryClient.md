# QueryClient

Use `QueryClient` as the actor-isolated runtime for query cache state.

## Overview

`QueryClient` owns cache storage, in-flight fetches, subscriptions, and
invalidation scope. It is not `@MainActor`; UI adapters choose how to deliver
changes to the main actor or a dispatch queue.

Most apps should keep a long-lived client near the app root and inject it into
feature code. SunKit does not provide a process-global singleton, and separate
client instances do not share cache, in-flight task, subscription, or
invalidation state.

```swift
let client = QueryClient()
```

`QueryClient` computes execution options as:

```swift
query.options ?? client.defaultQueryOptions
```

Cache lifecycle defaults come from `defaultCacheOptions`. MVP Core does not
include per-query cache overrides or per-key default merging.

Successful results become stale according to `defaultCacheOptions.staleTime`.
For nonzero stale times, `QueryClient` publishes a new result with
`isStale == true` when the freshness window elapses. Natural staleness does
not mark the entry invalidated and does not start a refetch by itself.
Fetch failures also do not invalidate entries by themselves; they publish a
failure result and keep any existing stale data available. Explicit
`invalidate(key:)` and `invalidateQueries(_:exact:)` calls are the only APIs
that mark entries invalidated.

Use `isQueryStale(_:)` when an observer needs to decide whether an `.ifStale`
trigger should fetch. Missing entries are stale. Existing entries are stale
when invalidated, when they have no successful update time, or when their
freshness window has elapsed.

## Typed Cache Access

`getQueryData` and `setQueryData` use typed keys. The same raw key parts with
different `Value` types are separate cache entries.

```swift
let key = QueryKey<Project>("project", id)
await client.setQueryData(key, project)
let cached = await client.getQueryData(key)
let shouldRefetch = await client.isQueryStale(key)
```

Use `updateQueryData` to transform data that is already cached:

```swift
await client.updateQueryData(key) { project in
    var updated = project
    updated.name = "Updated name"
    return updated
}
```

If a key has no cached data, `updateQueryData` is a no-op and the updater is
not called. The updater accepts and returns non-optional data; invalidation is
only performed through `invalidate(key:)` and
`invalidateQueries(_:exact:)`.

`clear()` removes all stored query state for that client, cancels stale and GC
timers, and requests cancellation of in-flight fetch tasks. Cancellation is
cooperative: a fetcher may still finish if it ignores task cancellation, but
cleared results are not stored or published.

## Parallel Queries

Use `fetchQueries(_:)` to fetch heterogeneous `Query` values concurrently
without tuple overloads or user-visible casting:

```swift
let results = await client.fetchQueries([
    AnyParallelQuery(userQuery),
    AnyParallelQuery(projectsQuery),
])

let user = results[userQuery.key]
let projects = results[projectsQuery.key]
```

Parallel Queries are not HTTP batching. Each unique query still runs through
`fetchQuery(_:)`, so cache writes, retries, stale state, in-flight
deduplication, subscriptions, and later invalidation refetch behavior are the
same as single-query execution.

The batch itself does not throw. A failed query is returned as a failed
`QueryResult` for that key while other query results remain available.
Duplicate typed keys in one batch use first-wins semantics. `InfiniteQuery`
batching is not part of v0.1.
