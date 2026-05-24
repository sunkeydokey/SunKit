# Query Options

Configure query execution, cache lifetime, and observer refetch behavior.

## Overview

SunKit separates query options by ownership:

- `QueryOptions` belong to fetch execution. During in-flight deduplication, the
  first request's query options apply to the shared fetch.
- `QueryCacheOptions` belong to cache lifecycle. They define when successful
  data becomes stale and how long inactive data may stay cached.
- `QueryObserverOptions<RawValue, SelectedValue>` belong to each subscriber or
  UI binding. They describe whether an observer may trigger fetches, which
  observer events refetch, whether placeholder data is exposed, and how raw
  cached data is selected for that observer.

Default query execution retries failed fetches up to three times with
exponential backoff capped at 30 seconds. Cache data is stale immediately by
default and inactive cache entries may remain for five minutes. Observers are
enabled by default and refetch on subscribe, scene activation, and network
reconnect only when cached data is stale.

Observer `select` transforms raw cached data only for the observer that owns the
options. It does not change cache identity, the value stored by `QueryClient`,
in-flight deduplication, invalidation, or stale-time calculation. Use identity
observer options when the UI should expose the raw cache value.

When `staleTime` is greater than zero, a successful cache entry publishes a
new stale result after the freshness window elapses. This lets subscribers and
UI state observe `QueryResult.isStale` changing over time without requiring a
manual invalidation.
