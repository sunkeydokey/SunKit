# QueryClient

Use `QueryClient` as the actor-isolated runtime for query cache state.

## Overview

`QueryClient` owns cache storage. It is not `@MainActor`; UI adapters choose how
to deliver changes to the main actor or a dispatch queue.

Most apps should keep a long-lived client near the app root and inject it into
feature code. SunKit does not provide a process-global singleton, and separate
client instances do not share cache state.

```swift
let client = QueryClient()
```

`QueryClient` computes execution options as:

```swift
query.options ?? client.defaultQueryOptions
```

Cache lifecycle defaults come from `defaultCacheOptions`. MVP Core does not
include per-query cache overrides or per-key default merging.

## Typed Cache Access

`getQueryData` and `setQueryData` use typed keys. The same raw key parts with
different `Value` types are separate cache entries.

```swift
let key = QueryKey<Project>("project", id)
await client.setQueryData(key, project)
let cached = await client.getQueryData(key)
```

`clear()` removes all stored query state for that client.
