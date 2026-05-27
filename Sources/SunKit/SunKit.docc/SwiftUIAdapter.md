# SwiftUI Adapter

Use `SunKitSwiftUI` to bind Core query state to SwiftUI views.

## Overview

The SwiftUI adapter is intentionally small. It provides an environment value
for sharing a `QueryClient`, observable `QueryState` for rendering the latest
`QueryResult`, `QueryBinding` for configuring query state from `body`,
observable `InfiniteQueryState` for rendering accumulated next pages,
`InfiniteQueryBinding` and `PaginatedQueryBinding` for modifier-driven page
queries, `ParallelQueriesState` for one-shot batch results, and observable
`MutationState` for rendering mutation progress.

Install one client near the app or scene root with `.queryClient(...)` before
using query modifiers or reading `@Environment(\.queryClient)`. Missing this
environment value is a programming error and terminates with `fatalError`
instead of creating an implicit cache scope.

## QueryBinding Modifier

Use `QueryBinding` with the `.query(...)` modifier when a query key or fetcher
depends on state owned by the same view. The property wrapper owns the
`QueryState` engine, and the modifier supplies dynamic values from `body`:

```swift
struct FollowersView: View {
    @State private var username = ""
    @QueryBinding(
        options: QueryObserverOptions(
            refetchOnSubscribe: .always,
            refetchOnSceneActive: .never,
            refetchOnNetworkReconnect: .never
        )
    ) private var followers: QueryState<[GitHubUser], [GitHubUser]>

    private var trimmedUsername: String {
        username.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        List(followers.result?.data ?? []) { user in
            FollowerRow(user: user)
        }
        .query(
            $followers,
            key: ["github", "followers", AnyQueryKeyPart(trimmedUsername)],
            enabled: !trimmedUsername.isEmpty
        ) { [trimmed = trimmedUsername] in
            guard !trimmed.isEmpty else { return [] }
            return try await GitHubAPI.followers(username: trimmed)
        }
    }
}
```

The `.query(...)` modifier reads `\.queryClient`, updates the stored state on
appearance, updates it again when the key or `enabled` flag changes, and stops
the state on disappearance. `QueryBinding` options are static for the lifetime of
the stored state; pass dynamic fetch gating through the modifier's `enabled`
parameter.

## Direct QueryState

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
fetch. `.ifStale` checks the client's current cache state with the state's
optional `QueryCacheOptions` instead of relying on the last rendered
`QueryState.result`.

Core may publish natural stale-time transitions, but `QueryState.result` does
not update when `isStale` is the only changed field. When a state has
per-observer cache options, it uses its own local stale timer to update
`result.isStale`; explicit invalidation still marks every observer stale.
Scene-active and network-reconnect `.ifStale` triggers still ask `QueryClient`
for the current stale state before deciding whether to refetch.

## Selecting Data

Use `QueryObserverOptions.select` when a view should render a projection of the
cached value. The cache stores the raw fetch result; only the observing state
exposes the selected value:

```swift
@State private var followerCount = QueryState<[GitHubUser], Int>(
    key: ["followers", "apple"],
    options: QueryObserverOptions(select: { $0.count })
) {
    try await api.followers(username: "apple")
}
```

`select` also applies to cached current values, stale data after refetch
failures, and `keepPreviousData` placeholders.

## Dynamic Keys

Use `QueryBinding` and `.query(...)` for dynamic keys driven by state in the same
view. If you manage lifecycle manually, call `update(key:using:fetch:)` when the
same SwiftUI state object should observe a different cache key, such as after a
search term, filter, or page value changes:

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

## Conditional Fetching

Use `QueryObserverOptions.enabled` to suppress automatic fetch triggers until a
condition is met. When `enabled` is `false`, the state still subscribes to cache
publications — data written by other observers is received immediately — but
the following triggers are suppressed:

- Initial fetch on subscribe (`refetchOnSubscribe`)
- Scene-active refetch (`refetchOnSceneActive`)
- Network-reconnect refetch (`refetchOnNetworkReconnect`)
- Periodic polling (`refetchInterval`)

Explicit calls to `refetch(using:)` are not affected by `enabled`.

Pass `enabled` to `update(key:using:fetch:enabled:)` to react to runtime
condition changes. A `false` to `true` transition immediately starts a fetch
according to `refetchOnSubscribe` and re-arms all refetch triggers. A `true` to
`false` transition disarms interval, scene-active, and network-reconnect triggers
while keeping the subscription active.

```swift
.onChange(of: isLoggedIn) { _, isLoggedIn in
    profile.update(
        key: ["profile", AnyQueryKeyPart(userID)],
        using: client,
        fetch: { try await api.fetchProfile(userID) },
        enabled: isLoggedIn
    )
}
```

`InfiniteQueryState` exposes the same pattern through
`update(query:using:enabled:)`.

## Paginated Queries

Use `PaginatedQueryBinding` with `.paginatedQuery(...)` when the input, key, or
fetcher depends on state owned by the same view:

```swift
@State private var searchText = ""
@State private var submittedSearchText = ""

@PaginatedQueryBinding(
    initialInput: "",
    initialPage: 1,
    nextPage: { $0 + 1 },
    previousPage: { $0 - 1 },
    canMoveToPreviousPage: { $0 > 1 },
    options: QueryObserverOptions(refetchOnSubscribe: .always)
) private var projects: PaginatedQueryState<String, Int, ProjectPage, ProjectPage>

var body: some View {
    List(projects.result?.data?.items ?? []) { project in
        ProjectRow(project: project)
    }
    .paginatedQuery(
        $projects,
        input: submittedSearchText,
        enabled: !submittedSearchText.isEmpty,
        key: { searchText, page in
            ["projects", AnyQueryKeyPart(searchText), AnyQueryKeyPart(page)]
        }
    ) { searchText, page in
        try await api.searchProjects(searchText, page: page)
    }
}
```

The modifier updates the stored state on appearance and when the input, current
page key, or `enabled` flag changes. Input changes reset to the initial page.
Page navigation methods keep using the latest key and fetch closures supplied by
the modifier.

You can also use `PaginatedQueryState` directly when manually managing the
lifecycle:

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

Use `InfiniteQueryBinding` with `.infiniteQuery(...)` when the infinite query key
or fetcher depends on state owned by the same view:

```swift
@InfiniteQueryBinding(
    options: QueryObserverOptions(refetchOnSubscribe: .always)
) private var repositories: InfiniteQueryState<Int, RepositoryPage, InfiniteData<Int, RepositoryPage>>

var body: some View {
    List(repositories.pages.flatMap(\.items)) { repository in
        RepositoryRow(repository: repository)
    }
    .infiniteQuery(
        $repositories,
        key: ["repositories", AnyQueryKeyPart(searchText)],
        initialPageParam: 1,
        enabled: !searchText.isEmpty,
        getNextPageParam: { lastPage, pages in
            lastPage.hasMore ? pages.count + 1 : nil
        }
    ) { page in
        try await api.searchRepositories(query: searchText, page: page)
    }
}
```

Call `fetchNextPage(using:)` from a load-more row or scroll sentinel. The
modifier owns subscription lifecycle and updates the state when the key or
`enabled` flag changes.

You can also use `InfiniteQueryState` directly when manually managing the
lifecycle:

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
while a refetch for the same key is pending. When the key changes, previous
pages are cleared and are not used as placeholder data for the new key.
Placeholder data is not written to the `QueryClient` cache.

`refetch(using:)` reloads from `initialPageParam` and replaces accumulated data
with the first page. The MVP adapter does not fetch previous pages, evict old
pages, refetch every previously loaded page, reverse page order, or perform
optimistic infinite updates.

Infinite query selection transforms the full accumulated raw container:

```swift
@State private var repositories = InfiniteQueryState<Int, SearchPage, [Repository]>(
    query: repositoryQuery,
    options: QueryObserverOptions(select: { data in
        data.pages.flatMap(\.items)
    })
)
```

`hasNextPage` and `fetchNextPage(using:)` still use the raw pages and
`getNextPageParam`; selected values are for rendering only.

## Parallel Queries

Use `ParallelQueriesBinding` with `.parallelQueries(...)` to run a one-shot batch
from values available in `body`. Parallel batches are not subscriptions; they
store the latest `ParallelQueryResults` and run again only when the explicit
token changes or `enabled` transitions to `true`:

```swift
@ParallelQueriesBinding private var dashboard: ParallelQueriesState

var body: some View {
    DashboardView(results: dashboard.result)
        .parallelQueries(
            $dashboard,
            queries: [
                AnyParallelQuery(userQuery),
                AnyParallelQuery(projectsQuery),
            ],
            token: dashboardInputToken,
            enabled: isReady
        )
}
```

Batch execution is configured through `.parallelQueries(...)`; the observable
state exposes results and fetching status for rendering. Execution uses
`QueryClient.fetchQueries(_:)`, so duplicate typed keys, partial failures, and
in-flight dedupe follow the Core parallel query semantics.

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

`MutationState` does not implement optimistic updates, mutation deduplication,
mutation cache storage, or automatic query invalidation. Use Core callbacks and
cache APIs directly when mutation success should update related query data.
