# SunKit

[한국어 README](DOCS/README.ko.md)

SunKit is a lightweight memory-cache and server-state management runtime for
Swift apps.

It manages query cache lifecycle, stale state, in-flight request deduplication,
subscriptions, invalidation, mutations, and SwiftUI binding. It does not wrap a
networking stack. Use `URLSession`, Alamofire, a generated SDK, or any async
operation that fits your app. The 0.2 line is SwiftUI-first and scoped to
mobile Apple platform apps, not a broad production-ready data framework.

SunKit's core rule is simple: the query key is the source of truth. A key should
describe the server data being read, not the view that happens to read it. When
the same typed key appears in two places, SunKit treats those reads as the same
cache identity and the same fetch semantics.

## Requirements

- iOS 18+, tvOS 18+, macOS 15+
- Swift 6, Xcode 16+
- swift-tools-version 6.0 or later

## Status

SunKit is pre-1.0. The current focus is a SwiftUI-first mobile MVP for iOS 18,
tvOS 18, macOS 15, Swift 6, and Xcode 16.

Implemented scope:

- Typed query keys and type-safe cache access
- Actor-isolated `QueryClient`
- In-memory query cache lifecycle
- `fetchQuery`, `ensureQueryData`, in-flight dedupe, retry, stale data on failure
- Query invalidation, removal, manual cache writes, and cache GC
- Observer-local cache options for SwiftUI stale-time tuning
- Core mutations with explicit invalidation or cache updates
- Infinite query and parallel query conveniences
- SwiftUI adapters for regular, paginated, infinite, parallel, and mutation flows

Deferred scope:

- Disk persistence and offline mutation resume
- Optimistic updates
- UIKit observer
- Global `isFetching` / `isMutating`

## Installation

### Swift Package Manager

Add the package in Xcode via **File → Add Package Dependencies** and enter:

```
https://github.com/sunkeydokey/SunKit
```

Or add it to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/sunkeydokey/SunKit", from: "0.2.1")
],
targets: [
    .target(
        name: "MyTarget",
        dependencies: [
            .product(name: "SunKit", package: "SunKit"),
            .product(name: "SunKitSwiftUI", package: "SunKit"),
        ]
    )
]
```

Import only what you need:

```swift
import SunKit          // Core — QueryClient, Query, Mutation, QueryKey
import SunKitSwiftUI   // SwiftUI adapters — QueryBinding, MutationBinding, etc.
```

## Core Usage

Create a long-lived `QueryClient` for a cache scope. The client is an actor and
is not tied to the main actor.

```swift
let client = QueryClient()
let key = QueryKey<Project>("project", projectID)

let query = Query(key: key) {
    try await api.project(id: projectID)
}

let result = await client.fetchQuery(query)
let project = result.data
```

## Query Keys

In SunKit, cache correctness starts with the key. A `QueryKey<Value>` is both:

- the identity used for cache lookup, invalidation, in-flight dedupe, and manual
  cache writes
- the typed contract for the value stored at that identity

`QueryKey<Value>` includes the value type in the cache identity. The same raw
parts with different `Value` types do not collide.

Values that change returned data must be part of the key:

```swift
let key = QueryKey<[Repository]>(
    "repositories",
    searchText,
    page,
    locale.identifier
)
```

This includes page, filter, search text, auth scope, locale, endpoint, feature
flag, and any other value that can change the data returned by the fetcher. If a
value changes the response but is not part of the key, different server states
will share one cache slot.

Prefer small key factories when a key is reused in multiple places:

```swift
enum ProjectQueries {
    static func project(_ id: Project.ID) -> QueryKey<Project> {
        QueryKey("project", id)
    }

    static func issues(
        projectID: Project.ID,
        state: IssueState
    ) -> QueryKey<[Issue]> {
        QueryKey("project", projectID, "issues", state.rawValue)
    }
}

let key = ProjectQueries.project(projectID)
let query = Query(key: key) {
    try await api.project(id: projectID)
}
```

Key factories are not required, but they make the identity contract visible. Two
views using `ProjectQueries.project(id)` join the same in-flight request, read
the same cached result, and respond to the same invalidation.

Do not reuse one key for different fetch semantics. If two fetchers compete for
the same typed key, the first in-flight request wins dedupe and later results may
not represent the fetcher a caller expected.

Manual cache access stays typed:

```swift
await client.setQueryData(key, repositories)
let cached = await client.getQueryData(key)

await client.updateQueryData(key) { current in
    current.sorted { $0.name < $1.name }
}
```

Invalidate exact typed keys or type-erased prefixes:

```swift
await client.invalidate(key: key)
await client.invalidateQueries(AnyQueryKey("repositories"))
```

Prefix invalidation follows the ordered key parts. `AnyQueryKey("project",
projectID)` matches `["project", projectID, "issues", state]`, but not
`["project", otherID, ...]`.

Invalidating an active query starts a background refetch when the client has a
previous fetcher. If that typed key is already fetching, the invalidation
refetch joins the existing in-flight task instead of forcing another request.

`QueryResult.isStale` describes the result snapshot being read. A refetch
failure can expose stale data through `result.data` and `result.isStale`.
`QueryClient.isQueryStale(_:)` checks the current cache entry instead: missing
entries, invalidated entries, entries without successful data, and entries past
`staleTime` are stale. Fetch failures do not mark entries invalidated by
themselves.

### Completion-based fetchers

Wrap legacy completion APIs with the built-in bridge:

```swift
let query = Query(key: key) { completion in
    legacyAPI.fetch(id: id) { result in
        completion(result)
    }
}
```

The completion must be called exactly once. Cancellation of the underlying
operation is not part of the 0.2 API surface.

## SwiftUI Usage

Inject one client near the app root. SunKit SwiftUI modifiers and
`@Environment(\.queryClient)` require this environment value; using them without
`.queryClient(...)` is a programming error and terminates with `fatalError`.

```swift
@main
struct ExampleApp: App {
    private let queryClient = QueryClient()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .queryClient(queryClient)
        }
    }
}
```

For dynamic keys or fetchers that depend on view state, prefer
`@QueryBinding` with `.query(...)`:

```swift
struct FollowersView: View {
    @State private var username = ""
    @QueryBinding(
        queryOptions: QueryOptions(retry: 1),
        cacheOptions: QueryCacheOptions(staleTime: 60),
        options: QueryObserverOptions(refetchOnSubscribe: .always)
    ) private var followers: QueryState<[GitHubUser], [GitHubUser]>

    private var trimmedUsername: String {
        username.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        List(followers.data ?? []) { user in
            Text(user.login)
        }
        .query(
            $followers,
            key: ["github", "followers", AnyQueryKeyPart(trimmedUsername)],
            enabled: !trimmedUsername.isEmpty
        ) { [trimmed = trimmedUsername] in
            try await GitHubAPI.followers(username: trimmed)
        }
    }
}
```

`QueryBinding` owns a stable `QueryState` engine through SwiftUI `@State`.
The view modifier supplies the latest key, fetcher, and `enabled` flag from
`body`, then starts, updates, and stops the state with the environment client.
The key still carries the identity contract: changing `username` changes the key,
so the view observes a different cache entry instead of overwriting the previous
user's followers.

`queryOptions` configure fetch execution for this observer's requests.
`cacheOptions` configure cache lifecycle policy for the observer: `staleTime`
is evaluated locally for this `QueryState`, while `gcTime` is used if this
observer is the last subscriber to leave the cache entry. If `cacheOptions` is
omitted, the client defaults are used.

`QueryState` exposes convenience properties for common view branches:
`data`, `error`, `isPending`, `isFetching`, `isSuccess`, and `isError`.
Use `result` only when you need the full `QueryResult`, such as
`result?.isStale` or `result?.isPlaceholderData`.

Direct `QueryState` lifecycle is still available when you need manual control:

```swift
@Environment(\.queryClient) private var client
@State private var projects = QueryState(key: ["projects"]) {
    try await api.projects()
}

var body: some View {
    List(projects.data ?? []) { project in
        ProjectRow(project: project)
    }
    .overlay {
        if projects.isPending {
            ProgressView("Loading projects")
        }
    }
    .toolbar {
        Button("Refresh") {
            projects.refetch(using: client)
        }
        .disabled(projects.isFetching)
    }
    .onAppear { projects.start(using: client) }
    .onDisappear { projects.stop() }
}
```

When using direct lifecycle with dynamic inputs, call
`update(key:using:fetch:enabled:)` whenever the input changes.

### Refetch triggers

Control when automatic refetches fire through `QueryObserverOptions`:

```swift
QueryObserverOptions(
    enabled: true,
    refetchOnSubscribe: .ifStale,       // .never / .ifStale / .always
    refetchOnSceneActive: .ifStale,
    refetchOnNetworkReconnect: .ifStale,
    refetchInterval: 30                 // seconds, nil to disable
)
```

### Cache options

Use `QueryCacheOptions` when a specific observer should keep data fresh longer
or shorter than the client default:

```swift
@QueryBinding(
    cacheOptions: QueryCacheOptions(staleTime: 120)
) private var repositories: QueryState<[Repository], [Repository]>
```

The same parameter is available on paginated and infinite bindings. This is
useful for pagination, where revisiting a recently loaded page usually should
reuse cache instead of refetching immediately:

```swift
@PaginatedQueryBinding(
    initialInput: "swift",
    initialPage: 1,
    cacheOptions: QueryCacheOptions(staleTime: 120),
    nextPage: { $0 + 1 },
    previousPage: { $0 - 1 },
    canMoveToPreviousPage: { $0 > 1 }
) private var repositories: PaginatedQueryState<String, Int, RepositoryPage, RepositoryPage>
```

With observer-local cache options, two views can watch the same key and expose
different `result.isStale` values based on their own `staleTime`. Explicit
invalidation still makes every observer stale. `gcTime` follows cache-entry
lifetime rules: when the last subscriber leaves, that subscriber's `gcTime`
controls when inactive data is removed.

### Select

Transform cached data per observer without changing the cache:

```swift
@QueryBinding(
    options: QueryObserverOptions(
        select: { (users: [User]) in users.map(\.name) }
    )
) private var names: QueryState<[User], [String]>
```

### Placeholder data

Keep previous data visible while a refetch is pending:

```swift
QueryObserverOptions(placeholderData: .keepPreviousData)
```

`result.isPlaceholderData` is `true` while the stale value is shown.

## Mutations

Mutations do not invalidate queries automatically. Invalidate related queries
explicitly from callbacks or after success:

```swift
let createProject = Mutation<CreateProjectInput, Project>(
    options: MutationOptions(
        onSuccess: { _, _, client in
            await client.invalidateQueries(AnyQueryKey("projects"))
        }
    )
) { input in
    try await api.createProject(input)
}

let project = try await client.mutate(createProject, input: input)
```

In SwiftUI, use `MutationState`:

```swift
@State private var createProject = MutationState(mutation: createProjectMutation)

Button("Create") {
    createProject.mutate(input, using: client)
}
```

Use `@MutationBinding` when the view should read the `QueryClient` from the
SwiftUI environment:

```swift
@MutationBinding(
    options: MutationOptions<CreateProjectInput, Project>(
        onSuccess: { _, _, client in
            await client.invalidateQueries(AnyQueryKey("projects"))
        }
    ),
    run: { input in
        try await api.createProject(input)
    }
)
private var createProject: MutationState<CreateProjectInput, Project>

Button("Create") {
    createProject.mutate(input)
}
```

## Paginated Queries

SunKit supports two paginated-query styles. Choose based on who should own the
current page.

Use `@PaginatedQueryBinding` when page navigation is part of the query state.
`PaginatedQueryState` owns `input`, `page`, next/previous-page closures, and
the current subscription. The `.paginatedQuery(...)` modifier supplies the
latest key and fetcher from `body`; input changes reset the page to
`initialPage`. This is the convenient default for screens where the page should
survive SwiftUI body re-renders while the screen instance remains alive.

Use regular `@State` plus `@QueryBinding` when the view should own the page
explicitly. Put the page in the query key and update the `@State` value from
buttons or other UI. In this style, SwiftUI owns reset behavior: if a pushed
screen is popped and later recreated, `@State private var page = 1` starts from
page 1 again. The query layer only observes the current key and caches each
`(input, page)` result.

In both styles, every value that changes the returned page must be part of the
key. Returning to a recently loaded page can reuse the `QueryClient` cache when
the cached value is still fresh.

## Infinite Queries

SunKit's infinite-query model is next-page-only. `fetchInfiniteQuery` and
`refetch(using:)` load `initialPageParam` when no pages are cached; when pages
are already cached, they start from the first stored page parameter, refetch the
same number of loaded pages sequentially, and replace the accumulated data with
the fresh sequence. `fetchNextPage` appends one next page when
`getNextPageParam` returns a value. If `getNextPageParam` returns `nil`, no
fetch starts and the current cached result is returned. Previous-page fetches
and optimistic infinite updates are not part of the MVP.

Use `maxPages` to cap stored pages. In the next-page-only model, fetching
beyond the limit drops the oldest pages while keeping `pages` and `pageParams`
aligned.

If invalidation happens while a `fetchNextPage` request is already in flight,
the append may complete as the successful fetch for that key and clear the
invalidation state.

```swift
@InfiniteQueryBinding(
    cacheOptions: QueryCacheOptions(staleTime: 60)
) private var feed: InfiniteQueryState<Int, Post, InfiniteData<Int, Post>>

var body: some View {
    List {
        ForEach(feed.pages.flatMap { $0 }) { post in
            PostRow(post: post)
        }
        if feed.hasNextPage {
            ProgressView()
                .onAppear { feed.fetchNextPage() }
        }
    }
    .infiniteQuery(
        $feed,
        key: ["feed"],
        initialPageParam: 1,
        maxPages: 5,
        getNextPageParam: { lastPage, _ in lastPage.nextPage }
    ) { page in
        try await api.feed(page: page)
    }
}
```

## Parallel Queries

Fetch multiple heterogeneous queries concurrently and look up results by typed key:

```swift
@ParallelQueriesBinding() private var batch: ParallelQueriesState

let userKey   = QueryKey<User>("user", userID)
let reposKey  = QueryKey<[Repo]>("repos", userID)

var body: some View {
    VStack {
        if let user = batch.result?[userKey]?.data { ... }
        if let repos = batch.result?[reposKey]?.data { ... }
    }
    .parallelQueries(
        $batch,
        queries: [
            AnyParallelQuery(Query(key: userKey) { try await api.user(id: userID) }),
            AnyParallelQuery(Query(key: reposKey) { try await api.repos(userID: userID) }),
        ],
        token: userID
    )
}
```

`batch.result?[key] == nil` means the batch has no result stored for that typed
key. A query that ran and failed is still present as a `QueryResult` with
`isError == true`; inspect `error` to handle that failure.

## Documentation

DocC articles live in `Sources/SunKit/SunKit.docc`.

Start with:

- `QueryKeys`
- `QueryClient`
- `Queries`
- `Invalidation`
- `SwiftUIAdapter`
- `Mutations`

## Validation

Run the package tests:

```sh
swift test
```
