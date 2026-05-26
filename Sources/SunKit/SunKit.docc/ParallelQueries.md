# Parallel Queries

Fetch multiple Core queries concurrently with typed result lookup.

## Overview

Parallel Queries are Swift concurrency convenience. They do not merge requests
into one HTTP call, and they do not change cache identity, retry behavior,
stale state, subscriptions, invalidation, or in-flight deduplication.

Wrap regular `Query` values with `AnyParallelQuery`, execute them with
`QueryClient.fetchQueries(_:)`, then read each result with the original typed
`QueryKey`:

```swift
let userKey = QueryKey<User>("user", userID)
let projectsKey = QueryKey<[Project]>("projects", userID)

let userQuery = Query(key: userKey) {
    try await api.fetchUser(userID)
}

let projectsQuery = Query(key: projectsKey) {
    try await api.fetchProjects(userID)
}

let results = await client.fetchQueries([
    AnyParallelQuery(userQuery),
    AnyParallelQuery(projectsQuery),
])

let user = results[userKey]
let projects = results[projectsKey]
```

`ParallelQueryResults` uses the same typed cache identity as `QueryClient`:
the raw `AnyQueryKey` parts plus the `Value` type. The same raw key with
different value types remains separate.

Looking up a key returns `nil` only when the batch result storage has no value
for that typed key. A query that ran and failed is still stored as a
`QueryResult` with `isError == true` and an `error` value.

## Failure and Dedupe

`fetchQueries(_:)` does not throw. Each query returns its own `QueryResult`, so
one query can fail while another succeeds in the same batch.

Each unique query runs through normal `fetchQuery(_:)`. If another caller is
already fetching the same typed key, the batch joins that in-flight task. If
the same typed key appears more than once in one batch, the first query wins
and later duplicates are skipped before execution.

## Cancellation

Batch execution uses child tasks. If the caller task is cancelled, child tasks
receive cooperative cancellation. Because each child uses normal
`fetchQuery(_:)`, shared in-flight fetches still follow `QueryClient`
semantics and may continue when they are already shared with other callers.

## Limitations

Parallel Queries accept only regular `Query<Value>` declarations in v0.1.
`InfiniteQuery` batching is intentionally excluded.
