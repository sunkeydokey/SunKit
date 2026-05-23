# SwiftUI Adapter

Use `SunKitSwiftUI` to bind Core query state to SwiftUI views.

## Overview

The SwiftUI adapter is intentionally small. It provides an environment value
for sharing a `QueryClient`, observable `QueryState` for rendering the latest
`QueryResult`, and observable `MutationState` for rendering mutation progress.

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
Subscription delivers the current cached value only; the adapter then starts a
fetch when
`QueryObserverOptions.enabled` is `true` and `refetchOnSubscribe` is not
`.never`.

Because Core publishes natural stale-time transitions, `QueryState.result`
updates when cached data becomes stale.

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

## Deferred Behavior

The SwiftUI adapter does not provide property wrappers. `MutationState` also
does not implement optimistic updates, mutation deduplication, mutation cache
storage, or automatic query invalidation. Use Core callbacks and cache APIs
directly when mutation success should update related query data.
