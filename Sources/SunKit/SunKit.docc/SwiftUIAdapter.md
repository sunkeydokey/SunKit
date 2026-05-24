# SwiftUI Adapter

Use `SunKitSwiftUI` to bind Core query state to SwiftUI views.

## Overview

The SwiftUI adapter is intentionally small. It provides an environment value
for sharing a `QueryClient`, observable `QueryState` for rendering the latest
`QueryResult`, observable `InfiniteQueryState` for rendering accumulated next
pages, and observable `MutationState` for rendering mutation progress.

Store `QueryState` with SwiftUI `@State` so the view owns the query lifecycle.
`QueryState` stores the key and fetcher, then creates executable Core queries
internally only when it needs to fetch:

```swift
struct ProjectsView: View {
    @Environment(\.queryClient) private var client
    @State private var projects = QueryState(
        key: ["projects"]
    ) {
        try await api.fetchProjects()
    }

    var body: some View {
        Button("Refresh") {
            projects.refetch(using: client)
        }
        .onAppear {
            projects.start(using: client)
        }
        .onDisappear {
            projects.stop()
        }
    }
}
```

`QueryState` subscribes to its key when `start(using:)` is called. String,
integer, Boolean, and floating-point key literals are converted into Core key
parts internally.
Subscription delivers the current cached value only; the adapter then uses
`QueryObserverOptions.enabled` and `refetchOnSubscribe` to decide whether to
fetch. `.ifStale` checks the client's current cache state instead of relying on
the last rendered `QueryState.result`.

Core may publish natural stale-time transitions, but `QueryState.result` does
not update when `isStale` is the only changed field. Scene-active and
network-reconnect `.ifStale` triggers still ask `QueryClient` for the current
stale state before deciding whether to refetch.

## Dynamic Keys

Use `update(key:using:fetch:)` when the same SwiftUI state object should observe
a different cache key, such as after a search term, filter, or page value
changes:

```swift
.onChange(of: searchText) { _, searchText in
    projects.update(key: ["projects", AnyQueryKeyPart(searchText)], using: client) {
        try await api.searchProjects(searchText)
    }
}
```

`QueryState` compares the newly built key with its current key. If the key is
unchanged, it keeps the current subscription and uses the new fetcher for later
refetches. If the key changed, it cancels the current subscription and refetch
triggers, clears key-scoped placeholder data, subscribes to the new key, and
then follows the observer options for fetching.

`keepPreviousData` is scoped to the current key. A refetch for the same key can
show previous data as placeholder data while the fetch is pending. Changing to a
different key does not show data from the old key; cached data for the new key
is still delivered immediately when available.

## Paginated Queries

Use `PaginatedQueryState` for numbered or page-param based views where input or
page changes should rebuild the query key while preserving one state object:

```swift
@State private var projects = PaginatedQueryState(
    input: "",
    initialPage: 1,
    key: { searchText, page in
        ["projects", AnyQueryKeyPart(searchText), AnyQueryKeyPart(page)]
    },
    nextPage: { $0 + 1 },
    previousPage: { $0 - 1 },
    canMoveToPreviousPage: { $0 > 1 }
) { searchText, page in
    try await api.searchProjects(searchText, page: page)
}
```

Call `setInput(_:using:)` when a search or filter changes; the page resets to
the initial page. Call `setPage(_:using:)`, `nextPage(using:)`, or
`previousPage(using:)` for page navigation. Returning to a previous page uses
the `QueryClient` cache for that key. Use `canMoveToPreviousPage` to enforce a
lower bound before applying the `previousPage` closure. Appending multiple pages
into one result is handled by the separate infinite-query API, not by
`PaginatedQueryState`.

## Infinite Queries

Use `InfiniteQueryState` when the UI should append next pages into one rendered
sequence:

```swift
@State private var repositories = InfiniteQueryState(
    query: InfiniteQuery<Int, RepositoryPage>(
        key: ["github", "repositories", "swift"],
        initialPageParam: 1,
        getNextPageParam: { lastPage, pages in
            lastPage.hasMore ? pages.count + 1 : nil
        }
    ) { page in
        try await api.searchRepositories(query: "swift", page: page)
    }
)
```

Call `start(using:)` from view appearance to subscribe and load the initial
page according to `QueryObserverOptions`. Call `fetchNextPage(using:)` from a
load-more row or scroll sentinel. `pages` and `pageParams` expose the
accumulated data, `hasNextPage` reflects `getNextPageParam`, and
`isFetchingNextPage` is scoped to next-page fetches.

`InfiniteQueryState` uses the same observer refetch policies as `QueryState`.
Scene-active and network-reconnect triggers check the current client stale
state for `.ifStale`, and `.always` refetches regardless of freshness.
Natural stale-time transitions do not update `InfiniteQueryState.result` when
`isStale` is the only changed field.

Use `update(query:using:)` when the same state object should observe a new
infinite-query declaration, such as after a search term or filter changes. If
the key is unchanged, the current subscription remains active and future
refetches use the new query. If the key changes, the state subscribes to the
new key and starts from `initialPageParam`.

`keepPreviousData` also applies to infinite queries. When enabled, previous
`pages` and `pageParams` remain visible as observer-local placeholder data
while a refetch or key change is pending. Placeholder data is not written to
the `QueryClient` cache.

`refetch(using:)` reloads from `initialPageParam` and replaces accumulated data
with the first page. The MVP adapter does not fetch previous pages, evict old
pages, reverse page order, or perform optimistic infinite updates.

## Mutations

Store `MutationState` with SwiftUI `@State`, then call `mutate(_:using:)` from
user actions:

```swift
struct CreateProjectView: View {
    @Environment(\.queryClient) private var client
    @State private var createProject = MutationState(
        mutation: Mutation<CreateProjectInput, Project> { input in
            try await api.createProject(input)
        }
    )

    var body: some View {
        Button("Create") {
            createProject.mutate(input, using: client)
        }
        .disabled(createProject.isPending)
    }
}
```

Calling `mutate(_:using:)` cancels any in-flight mutation owned by that state
object, publishes `.pending`, then publishes success data or failure error on
the main actor. `reset()` cancels the current task and returns the result to
idle.

Render mutation failures from `isError` and `error`. `MutationState` does not
report retry-attempt counts; a failed mutation result uses `failureCount == 1`
as the minimum failed-execution marker even when Core retried the operation.

## Deferred Behavior

The SwiftUI adapter does not provide property wrappers. `MutationState` also
does not implement optimistic updates, mutation deduplication, mutation cache
storage, or automatic query invalidation. Use Core callbacks and cache APIs
directly when mutation success should update related query data.
