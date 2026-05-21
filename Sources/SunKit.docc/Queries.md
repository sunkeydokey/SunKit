# Queries

Use `Query` to describe how a typed key fetches data.

## Overview

A query is a fetch declaration, not a running operation. It stores a
`QueryKey<Value>`, optional execution options, and a fetcher that `QueryClient`
can run.

If `Query.options` is `nil`, the executing client uses its
`defaultQueryOptions`. Passing explicit options makes that query execution use
the override. During in-flight deduplication, the first request's effective
options win.

```swift
let key = QueryKey<[Project]>("projects", page)

let query = Query(key: key) {
    try await api.fetchProjects(page: page)
}
```

Completion-based APIs can also be wrapped:

```swift
let query = Query(key: key) { completion in
    api.fetchProjects(page: page) { result in
        completion(result)
    }
}
```

The completion must be called exactly once. Core does not define cancellation
for the underlying completion operation.
