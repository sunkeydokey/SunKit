# Query Options

Configure query execution, cache lifetime, and observer refetch behavior.

## Overview

SunKit separates query options by ownership:

- `QueryOptions` belong to fetch execution. During in-flight deduplication, the
  first request's query options apply to the shared fetch.
- `QueryCacheOptions` belong to cache lifecycle. They define when successful
  data becomes stale and how long inactive data may stay cached. SwiftUI
  observers may pass per-observer cache options so each observer can apply its
  own stale-time calculation.
- `QueryObserverOptions<RawValue, SelectedValue>` belong to each subscriber or
  UI binding. They describe whether an observer may trigger fetches, which
  observer events refetch, whether placeholder data is exposed, and how raw
  cached data is selected for that observer.

Default query execution retries failed fetches up to three times with
exponential backoff capped at 30 seconds. Cache data is stale immediately by
default and inactive cache entries may remain for five minutes. Observers are
enabled by default and refetch on subscribe, scene activation, and network
reconnect only when cached data is stale. Setting `enabled` to `false` suppresses
all automatic refetch triggers while keeping the subscription alive. Pass
`enabled` to `update(key:using:fetch:enabled:)` or
`update(query:using:enabled:)` to react to runtime changes — a `false` to `true`
transition triggers an initial fetch and re-arms all active triggers; a `true` to
`false` transition disarms them immediately.

Observer `select` transforms raw cached data only for the observer that owns the
options. It does not change cache identity, the value stored by `QueryClient`,
in-flight deduplication, or invalidation. Use identity observer options when the
UI should expose the raw cache value.

When `staleTime` is greater than zero, a successful cache entry publishes a
new stale result after the freshness window elapses. This lets subscribers and
UI state observe `QueryResult.isStale` changing over time without requiring a
manual invalidation.

SwiftUI `QueryState` and `InfiniteQueryState` can also receive
`QueryCacheOptions` directly. When present, those observers compute
`QueryResult.isStale` from their own `staleTime`; explicit invalidation remains
stale for every observer. If multiple observers provide different `gcTime`
values for the same cache entry, the value from the last subscriber to leave is
used when the entry becomes inactive.
