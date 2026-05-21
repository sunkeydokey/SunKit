# Query Options

Configure query execution, cache lifetime, and observer refetch behavior.

## Overview

SunKit separates query options by ownership:

- `QueryOptions` belong to fetch execution. During in-flight deduplication, the
  first request's query options apply to the shared fetch.
- `QueryCacheOptions` belong to cache lifecycle. They define when successful
  data becomes stale and how long inactive data may stay cached.
- `QueryObserverOptions` belong to each subscriber or UI binding. They describe
  whether an observer may trigger fetches, which observer events refetch, and
  whether placeholder data is exposed.

Default query execution retries failed fetches up to three times with
exponential backoff capped at 30 seconds. Cache data is stale immediately by
default and inactive cache entries may remain for five minutes. Observers are
enabled by default and refetch on subscribe, scene activation, and network
reconnect only when cached data is stale.
