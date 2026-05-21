# Invalidation

Use invalidation to mark cached query data stale.

## Overview

`invalidate(key:)` is an exact typed-key convenience API:

```swift
await client.invalidate(key: QueryKey<[Project]>("projects", page))
```

Use `invalidateQueries(_:exact:)` for type-erased exact or prefix invalidation:

```swift
await client.invalidateQueries(AnyQueryKey("projects"), exact: false)
```

Prefix invalidation matches raw key parts. The example above can match
`["projects"]`, `["projects", 1]`, and `["projects", filter]`.

Invalidation behavior depends on activity:

- Active query: marked stale, then background refetch starts if Core has a
  known previous fetcher.
- Inactive query: marked stale only.

A query is active when it has at least one Core subscriber. If a subscribed
entry has never been fetched, Core has no fetcher to run; invalidation still
marks it stale but does not invent a fetch.

`removeQueries(_:exact:)` removes matching cache entries.
