# ``SunKit``

Core runtime primitives for a Swift server-state library.

## Overview

`SunKit` manages server data lifecycle separately from networking and UI
frameworks. The MVP module is intentionally independent from SwiftUI, UIKit,
Combine, Observation, RxSwift, and networking libraries.

The first supported primitives are query identity through `QueryKey`,
`AnyQueryKey`, and `AnyQueryKeyPart`, fetch declarations through `Query`,
read-only query state snapshots through `QueryResult`, option ownership through
`QueryOptions`, `QueryCacheOptions`, and `QueryObserverOptions`, and cache
runtime behavior through `QueryClient`. Infinite query Core adds
`InfiniteQuery` and `InfiniteData` for next-page-only accumulated page loading.
Mutation Core adds typed mutation declarations through `Mutation` and explicit
mutation execution through `QueryClient`.

## Topics

### Query Core

- <doc:QueryKeys>
- <doc:QueryResult>
- <doc:QueryOptions>
- <doc:Queries>
- <doc:QueryClient>
- <doc:InFlightDedupe>
- <doc:Invalidation>
- <doc:Subscriptions>
- <doc:InfiniteQuery>
- <doc:Mutations>
- <doc:SwiftUIAdapter>
