# SunKit

SunKit is a lightweight server-state runtime for Swift apps.

It manages query cache lifecycle, stale state, in-flight request deduplication,
subscriptions, invalidation, mutations, and SwiftUI binding. It does not wrap a
networking stack. Use `URLSession`, Alamofire, a generated SDK, or any async
operation that fits your app.

## Requirements

- iOS 18+, tvOS 18+, macOS 15+
- Swift 6, Xcode 16+
- swift-tools-version 6.0 or later

## Status

SunKit is pre-1.0. The current focus is a mobile MVP for iOS 18, tvOS 18,
macOS 15, Swift 6, and Xcode 16.

Implemented scope:

- Typed query keys and type-safe cache access
- Actor-isolated `QueryClient`
- `fetchQuery`, `ensureQueryData`, in-flight dedupe, retry, stale data on failure
- Query invalidation, removal, manual cache writes, and cache GC
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
    .package(url: "https://github.com/sunkeydokey/SunKit", from: "0.1.0")
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
import SunKitSwiftUI   // SwiftUI adapters — QueryBinding, MutationState, etc.
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
operation is not defined in v0.1.

## SwiftUI Usage

Inject one client near the app root:

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
        options: QueryObserverOptions(refetchOnSubscribe: .always)
    ) private var followers: QueryState<[GitHubUser], [GitHubUser]>

    private var trimmedUsername: String {
        username.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        List(followers.result?.data ?? []) { user in
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

Direct `QueryState` lifecycle is still available when you need manual control:

```swift
@Environment(\.queryClient) private var client
@State private var projects = QueryState(key: ["projects"]) {
    try await api.projects()
}

var body: some View {
    Button("Refresh") {
        projects.refetch(using: client)
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

Mutations do not invalidate queries automatically. Update or invalidate related
queries explicitly from callbacks or after success:

```swift
let createProject = Mutation<CreateProjectInput, Project>(
    options: MutationOptions(
        onSuccess: { project, _, client in
            await client.invalidateQueries(AnyQueryKey("projects"))
            await client.setQueryData(QueryKey<Project>("project", project.id), project)
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

## Infinite Queries

```swift
@InfiniteQueryBinding() private var feed: InfiniteQueryState<Int, Post, InfiniteData<Int, Post>>

var body: some View {
    List {
        ForEach(feed.pages.flatMap { $0 }) { post in
            PostRow(post: post)
        }
        if feed.hasNextPage {
            ProgressView()
                .onAppear { feed.fetchNextPage(using: client) }
        }
    }
    .infiniteQuery(
        $feed,
        key: ["feed"],
        initialPageParam: 1,
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
