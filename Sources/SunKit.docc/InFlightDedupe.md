# In-Flight Dedupe

SunKit joins matching in-flight query fetches.

## Overview

When `fetchQuery` is called while the same `QueryKey` and the same `Value` type
are already fetching, the later call waits for the first task. The later fetcher
does not run.

This means a query key is a cache identity and a fetch semantics contract. If
two different fetchers compete for the same key, whichever request starts first
defines the shared result for that in-flight operation.

```swift
async let first = client.fetchQuery(projectsQuery)
async let second = client.fetchQuery(projectsQuery)

let results = await (first, second)
```

Successful fetches store data and reset failure count. Initial failures have no
data. Refetch failures keep stale data from the previous success.
