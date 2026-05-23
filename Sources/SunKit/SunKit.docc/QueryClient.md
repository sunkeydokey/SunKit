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

## Typed Cache Access

`getQueryData` and `setQueryData` use typed keys. The same raw key parts with
different `Value` types are separate cache entries.

```swift
let key = QueryKey<Project>("project", id)
await client.setQueryData(key, project)
let cached = await client.getQueryData(key)
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

`clear()` removes all stored query state for that client.
