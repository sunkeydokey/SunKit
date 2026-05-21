# Query Results

Read query state from `QueryResult` snapshots.

## Overview

`QueryResult` is a Core-owned snapshot of a query's observable state. SunKit
creates these values through query APIs such as fetching, subscriptions, and
future adapters. Package users read the public projection properties instead of
constructing query results directly.

Use `data` to read the latest available value. When an initial fetch fails,
`data` is `nil`. When a refetch fails after data already exists, `data` keeps
the stale value and `error` describes the latest failure.

`isFetching` is independent from the success and error projections. A background
refetch can expose successful data while `isFetching` is `true`.

```swift
let result = await client.fetchQuery(query)

if result.isSuccess {
    render(result.data)
}

if result.isError {
    showError(result.error)
}
```
