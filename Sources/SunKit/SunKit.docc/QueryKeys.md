# Query Keys

Use query keys to identify cached server data.

## Overview

A `QueryKey` represents both data identity and fetch semantics. Values that can
change the returned data, such as page, filter, auth scope, locale, endpoint, or
feature flag, must be included in the key.

```swift
let projects = QueryKey<[Project]>("projects", page)
let project = QueryKey<Project>("project", id)
```

Key part equality includes the concrete Swift type. This means `"1"` and `1`
are different key parts.

When an API accepts type-erased key parts, array literals can be used:

```swift
let parts: [AnyQueryKeyPart] = ["projects", page]
let key = QueryKey<[Project]>(parts)
```

Use `AnyQueryKey` for prefix matching during invalidation:

```swift
let key = QueryKey<[Project]>("projects", 1)
key.rawValue.starts(with: AnyQueryKey("projects")) // true
```
