# SwiftUI Adapter

Use `SunKitSwiftUI` to bind Core query state to SwiftUI views.

## Overview

The SwiftUI adapter is intentionally small. It provides an environment value
for sharing a `QueryClient` and observable `QueryState` for rendering the
latest `QueryResult`.

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

## Deferred Behavior

The first SwiftUI adapter does not implement scene-active refetch, network
reconnect refetch, refetch intervals, placeholder data behavior, or property
wrappers. Use `QueryState.refetch(using:)` or Core APIs directly when these
behaviors are needed.
