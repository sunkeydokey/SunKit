# Mutations

Execute remote writes without coupling Core to networking or UI frameworks.

## Overview

`Mutation` describes work that changes remote state, such as creating,
updating, or deleting a server resource. `QueryClient` executes the mutation
and applies retry options, then runs lifecycle callbacks.

```swift
let createProject = Mutation<CreateProjectInput, Project> { input in
    try await api.createProject(input)
}

let project = try await client.mutate(createProject, input: input)
```

Mutation retry is disabled by default. Configure retry only for mutation
operations that are safe to repeat:

```swift
let createProject = Mutation<CreateProjectInput, Project>(
    options: MutationOptions(retry: .count(1), retryDelay: .fixed(1))
) { input in
    try await api.createProject(input)
}
```

## Explicit Invalidation

Mutations do not automatically invalidate query data. Invalidate or update
related queries explicitly after a successful mutation:

```swift
let project = try await client.mutate(createProject, input: input)
await client.invalidateQueries(AnyQueryKey("projects"), exact: false)
```

You can also place invalidation in `onSuccess` so the mutation declaration owns
the cache follow-up:

```swift
let createProject = Mutation<CreateProjectInput, Project>(
    options: MutationOptions(
        onSuccess: { project, input, client in
            await client.invalidateQueries(AnyQueryKey("projects"), exact: false)
        }
    )
) { input in
    try await api.createProject(input)
}
```

The callback order is fixed. On success, Core runs the mutation operation,
then `onSuccess`, then `onSettled`, and finally returns the output. On failure,
Core exhausts retries, then runs `onFailure`, then `onSettled`, and finally
throws the error.

Core mutation execution returns output or throws the final error. Retry-attempt
counts are not part of the public mutation execution API; SwiftUI mutation UI
state should render failed mutations from `isError` and `error`.

## Completion-Based Mutations

Completion-based APIs can be wrapped in the same mutation type:

```swift
let createProject = Mutation<CreateProjectInput, Project> { input, completion in
    sdk.createProject(input) { result in
        completion(result)
    }
}

client.mutate(createProject, input: input, deliverOn: .main) { result in
    // Handle success or failure.
}
```

The completion must be called exactly once. Core does not define cancellation
behavior for the underlying completion-based operation.

## Deferred Behavior

MVP Mutation Core is an execution helper. It does not include optimistic
updates, mutation deduplication, mutation cache storage, global mutation
observers, or automatic invalidation.
