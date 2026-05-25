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

Key parts should be stable value snapshots, such as strings, numbers, enum raw
values, or identifiers. SunKit compares newly built keys with existing keys; it
does not observe mutation inside reference-typed values that were already placed
in a key.

Prefer small, deterministic key parts. A key should describe the minimum inputs
that affect the returned value, not the entire request object. For example,
store a user id, page, filter, locale identifier, or auth-scope identifier
rather than a view model, service object, closure, timestamp, or mutable
reference.

```swift
// Good: small value snapshots that define the server result.
let key = QueryKey<[Project]>(
    "projects",
    organizationID,
    page,
    filter.rawValue,
    locale.identifier
)

// Avoid: large or mutable values make cache identity hard to reason about.
let unstable = QueryKey<[Project]>("projects", requestObject)
```

If two fetches can return different data, their keys must differ. If two query
declarations use the same key, SunKit treats them as the same cache identity and
may join an existing in-flight task instead of running the later fetcher.
Different fetchers competing for the same key are a caller bug; result
consistency is not guaranteed.

Prefix invalidation is based on ordered key parts. Put broad resource labels
first and increasingly specific identifiers after them:

```swift
let list = QueryKey<[Project]>("projects", organizationID, "list", filter.rawValue)
let detail = QueryKey<Project>("projects", organizationID, "detail", projectID)

await client.invalidateQueries(AnyQueryKey("projects", organizationID))
```

The prefix above invalidates both project list and project detail entries for
that organization. It does not invalidate unrelated organizations.

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
