# Subscriptions

Use Core subscriptions to observe query result changes without a UI dependency.

## Overview

`subscribe` registers a listener for a typed query key. It can deliver the
current result immediately, but it never starts a fetch by itself.

```swift
let subscription = await client.subscribe(to: key, deliverOn: .main) { result in
    render(result)
}
```

Delivery can be scheduled on a `DispatchQueue`, or Core can schedule listener
work asynchronously without a queue. Listener closures are not called directly
while mutating actor-isolated cache state.

Cancel the returned `QuerySubscription` to stop receiving publications:

```swift
await subscription.cancel()
```

Core tracks active queries through subscriber count.
