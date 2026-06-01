# SunKit

[English README](../README.md)

SunKit은 Swift 앱을 위한 가벼운 메모리 캐시 및 서버 상태 관리 런타임입니다.

SunKit은 query cache lifecycle, stale 상태, in-flight request deduplication,
subscription, invalidation, mutation, SwiftUI binding을 관리합니다. 네트워킹
스택을 감싸지는 않습니다. 앱에 맞는 `URLSession`, Alamofire, generated SDK,
또는 임의의 async 작업을 그대로 사용하면 됩니다. v0.1 preview는 SwiftUI 우선
모바일 Apple platform MVP 범위이며, 광범위한 production-ready data framework를
목표로 하지 않습니다.

SunKit의 핵심 규칙은 단순합니다. query key가 진실 공급원입니다. key는 그 key를
읽는 view가 아니라, 읽고 있는 서버 데이터를 설명해야 합니다. 같은 typed key가
두 곳에 나타나면 SunKit은 그 read를 같은 cache identity와 같은 fetch semantics로
취급합니다.

## 요구 사항

- iOS 18+, tvOS 18+, macOS 15+
- Swift 6, Xcode 16+
- swift-tools-version 6.0 이상

## 상태

SunKit은 pre-1.0입니다. 현재 초점은 iOS 18, tvOS 18, macOS 15, Swift 6,
Xcode 16을 대상으로 하는 SwiftUI 우선 모바일 MVP입니다.

구현된 범위:

- Typed query key와 type-safe cache access
- Actor-isolated `QueryClient`
- In-memory query cache lifecycle
- `fetchQuery`, `ensureQueryData`, in-flight dedupe, retry, failure 시 stale data 유지
- Query invalidation, removal, manual cache write, cache GC
- SwiftUI stale-time 조정을 위한 observer-local cache option
- 명시적 invalidation 또는 cache update를 사용하는 Core mutation
- Infinite query 및 parallel query convenience
- regular, paginated, infinite, parallel, mutation flow용 SwiftUI adapter

유예된 범위:

- Disk persistence 및 offline mutation resume
- Optimistic update
- UIKit observer
- Global `isFetching` / `isMutating`

## 설치

### Swift Package Manager

Xcode에서 **File -> Add Package Dependencies**를 선택하고 다음 URL을 입력합니다.

```
https://github.com/sunkeydokey/SunKit
```

또는 `Package.swift`에 추가합니다.

```swift
dependencies: [
    .package(url: "https://github.com/sunkeydokey/SunKit", from: "0.1.1")
],
targets: [
    .target(
        name: "MyTarget",
        dependencies: [
            .product(name: "SunKit", package: "SunKit"),
            .product(name: "SunKitSwiftUI", package: "SunKit"),
        ]
    )
]
```

필요한 모듈만 import합니다.

```swift
import SunKit          // Core - QueryClient, Query, Mutation, QueryKey
import SunKitSwiftUI   // SwiftUI adapters - QueryBinding, MutationBinding, etc.
```

## Core 사용법

cache scope를 위해 오래 유지되는 `QueryClient`를 만듭니다. client는 actor이며
main actor에 묶이지 않습니다.

```swift
let client = QueryClient()
let key = QueryKey<Project>("project", projectID)

let query = Query(key: key) {
    try await api.project(id: projectID)
}

let result = await client.fetchQuery(query)
let project = result.data
```

## Query Key

SunKit에서 cache correctness는 key에서 시작합니다. `QueryKey<Value>`는 동시에
다음 두 역할을 합니다.

- cache lookup, invalidation, in-flight dedupe, manual cache write에 사용되는 identity
- 그 identity에 저장되는 value의 typed contract

`QueryKey<Value>`는 cache identity에 value type을 포함합니다. raw part가 같아도
`Value` type이 다르면 충돌하지 않습니다.

반환 데이터를 바꾸는 값은 반드시 key에 포함되어야 합니다.

```swift
let key = QueryKey<[Repository]>(
    "repositories",
    searchText,
    page,
    locale.identifier
)
```

여기에는 page, filter, search text, auth scope, locale, endpoint, feature flag,
그리고 fetcher가 반환하는 데이터를 바꿀 수 있는 모든 값이 포함됩니다. response를
바꾸는 값이 key에 없으면 서로 다른 서버 상태가 하나의 cache slot을 공유하게 됩니다.

여러 곳에서 재사용되는 key에는 작은 key factory를 권장합니다.

```swift
enum ProjectQueries {
    static func project(_ id: Project.ID) -> QueryKey<Project> {
        QueryKey("project", id)
    }

    static func issues(
        projectID: Project.ID,
        state: IssueState
    ) -> QueryKey<[Issue]> {
        QueryKey("project", projectID, "issues", state.rawValue)
    }
}

let key = ProjectQueries.project(projectID)
let query = Query(key: key) {
    try await api.project(id: projectID)
}
```

Key factory는 필수는 아니지만 identity contract를 눈에 보이게 만듭니다.
`ProjectQueries.project(id)`를 사용하는 두 view는 같은 in-flight request에 join하고,
같은 cached result를 읽으며, 같은 invalidation에 반응합니다.

하나의 key를 서로 다른 fetch semantics에 재사용하지 마세요. 두 fetcher가 같은 typed
key를 두고 경쟁하면 첫 번째 in-flight request가 dedupe에서 이기며, 이후 result가
caller가 기대한 fetcher를 대표하지 않을 수 있습니다.

Manual cache access는 typed 상태를 유지합니다.

```swift
await client.setQueryData(key, repositories)
let cached = await client.getQueryData(key)

await client.updateQueryData(key) { current in
    current.sorted { $0.name < $1.name }
}
```

정확한 typed key 또는 type-erased prefix를 invalidate할 수 있습니다.

```swift
await client.invalidate(key: key)
await client.invalidateQueries(AnyQueryKey("repositories"))
```

Prefix invalidation은 순서가 있는 key part를 기준으로 동작합니다.
`AnyQueryKey("project", projectID)`는 `["project", projectID, "issues", state]`와
match되지만, `["project", otherID, ...]`와는 match되지 않습니다.

Active query를 invalidate하면 client가 이전 fetcher를 가지고 있을 때 background
refetch가 시작됩니다. 해당 typed key가 이미 fetching 중이면 invalidation refetch는
새 request를 강제하지 않고 기존 in-flight task에 join합니다.

`QueryResult.isStale`은 현재 읽는 result snapshot을 설명합니다. Refetch failure는
`result.data`와 `result.isStale`을 통해 stale data를 노출할 수 있습니다.
`QueryClient.isQueryStale(_:)`는 현재 cache entry를 확인합니다. missing entry,
invalidated entry, successful data가 없는 entry, `staleTime`이 지난 entry는 stale입니다.
Fetch failure 자체가 entry를 invalidated 상태로 만들지는 않습니다.

### Completion 기반 fetcher

Legacy completion API는 내장 bridge로 감쌀 수 있습니다.

```swift
let query = Query(key: key) { completion in
    legacyAPI.fetch(id: id) { result in
        completion(result)
    }
}
```

Completion은 정확히 한 번 호출되어야 합니다. underlying operation의 cancellation은
v0.1에서 정의하지 않습니다.

## SwiftUI 사용법

앱 root 가까이에 하나의 client를 주입합니다. SunKit SwiftUI modifier와
`@Environment(\.queryClient)`는 이 environment value를 필요로 합니다.
`.queryClient(...)` 없이 사용하면 programming error이며 `fatalError`로 종료됩니다.

```swift
@main
struct ExampleApp: App {
    private let queryClient = QueryClient()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .queryClient(queryClient)
        }
    }
}
```

View state에 의존하는 dynamic key 또는 fetcher에는 `@QueryBinding`과 `.query(...)`를
우선 사용합니다.

```swift
struct FollowersView: View {
    @State private var username = ""
    @QueryBinding(
        queryOptions: QueryOptions(retry: 1),
        cacheOptions: QueryCacheOptions(staleTime: 60),
        options: QueryObserverOptions(refetchOnSubscribe: .always)
    ) private var followers: QueryState<[GitHubUser], [GitHubUser]>

    private var trimmedUsername: String {
        username.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        List(followers.data ?? []) { user in
            Text(user.login)
        }
        .query(
            $followers,
            key: ["github", "followers", AnyQueryKeyPart(trimmedUsername)],
            enabled: !trimmedUsername.isEmpty
        ) { [trimmed = trimmedUsername] in
            try await GitHubAPI.followers(username: trimmed)
        }
    }
}
```

`QueryBinding`은 SwiftUI `@State`를 통해 stable한 `QueryState` engine을 소유합니다.
View modifier는 `body`에서 최신 key, fetcher, `enabled` flag를 공급한 뒤 environment
client로 state를 start, update, stop합니다. 여기서도 key가 identity contract를
가집니다. `username`이 바뀌면 key가 바뀌므로, view는 이전 user의 followers를
덮어쓰지 않고 다른 cache entry를 관찰합니다.

`queryOptions`는 이 observer가 실행하는 fetch의 retry / retry delay 같은 실행 정책을
설정합니다. `cacheOptions`는 observer의 cache lifecycle 정책을 설정합니다.
`staleTime`은 이 `QueryState`에서 local로 평가되고, `gcTime`은 이 observer가 cache
entry를 떠나는 마지막 subscriber일 때 inactive data 제거 예약에 사용됩니다.
`cacheOptions`를 생략하면 client 기본값을 사용합니다.

`QueryState`는 view 분기에 자주 쓰는 convenience property를 제공합니다:
`data`, `error`, `isPending`, `isFetching`, `isSuccess`, `isError`.
`result`는 `result?.isStale` 또는 `result?.isPlaceholderData`처럼 전체
`QueryResult`가 필요할 때만 사용하세요.

직접 제어가 필요하면 `QueryState` lifecycle을 직접 사용할 수도 있습니다.

```swift
@Environment(\.queryClient) private var client
@State private var projects = QueryState(key: ["projects"]) {
    try await api.projects()
}

var body: some View {
    List(projects.data ?? []) { project in
        ProjectRow(project: project)
    }
    .overlay {
        if projects.isPending {
            ProgressView("Loading projects")
        }
    }
    .toolbar {
        Button("Refresh") {
            projects.refetch(using: client)
        }
        .disabled(projects.isFetching)
    }
    .onAppear { projects.start(using: client) }
    .onDisappear { projects.stop() }
}
```

Direct lifecycle에서 dynamic input을 사용할 때는 input이 바뀔 때마다
`update(key:using:fetch:enabled:)`를 호출하세요.

### Refetch trigger

자동 refetch가 언제 발생할지는 `QueryObserverOptions`로 제어합니다.

```swift
QueryObserverOptions(
    enabled: true,
    refetchOnSubscribe: .ifStale,       // .never / .ifStale / .always
    refetchOnSceneActive: .ifStale,
    refetchOnNetworkReconnect: .ifStale,
    refetchInterval: 30                 // seconds, nil to disable
)
```

### Cache option

특정 observer가 client 기본값보다 data를 더 오래 또는 더 짧게 fresh로 유지해야 하면
`QueryCacheOptions`를 사용합니다.

```swift
@QueryBinding(
    cacheOptions: QueryCacheOptions(staleTime: 120)
) private var repositories: QueryState<[Repository], [Repository]>
```

같은 parameter는 paginated / infinite binding에서도 사용할 수 있습니다. Pagination에서는
최근에 load한 page를 다시 방문할 때 즉시 refetch하지 않고 cache를 재사용하는 데 유용합니다.

```swift
@PaginatedQueryBinding(
    initialInput: "swift",
    initialPage: 1,
    cacheOptions: QueryCacheOptions(staleTime: 120),
    nextPage: { $0 + 1 },
    previousPage: { $0 - 1 },
    canMoveToPreviousPage: { $0 > 1 }
) private var repositories: PaginatedQueryState<String, Int, RepositoryPage, RepositoryPage>
```

Observer-local cache option을 사용하면 두 view가 같은 key를 보더라도 각자의
`staleTime` 기준에 따라 서로 다른 `result.isStale` 값을 노출할 수 있습니다. 명시적
invalidation은 여전히 모든 observer를 stale로 만듭니다. `gcTime`은 cache entry
lifetime 규칙을 따릅니다. 마지막 subscriber가 떠날 때 그 subscriber의 `gcTime`이
inactive data 제거 시점을 결정합니다.

### Select

Cache를 바꾸지 않고 observer별로 cached data를 transform합니다.

```swift
@QueryBinding(
    options: QueryObserverOptions(
        select: { (users: [User]) in users.map(\.name) }
    )
) private var names: QueryState<[User], [String]>
```

### Placeholder data

Refetch가 pending 중일 때 이전 data를 계속 보여줍니다.

```swift
QueryObserverOptions(placeholderData: .keepPreviousData)
```

Stale value가 표시되는 동안 `result.isPlaceholderData`는 `true`입니다.

## Mutation

Mutation은 query를 자동으로 invalidate하지 않습니다. Callback 또는 success 이후에
관련 query를 명시적으로 invalidate하세요.

```swift
let createProject = Mutation<CreateProjectInput, Project>(
    options: MutationOptions(
        onSuccess: { _, _, client in
            await client.invalidateQueries(AnyQueryKey("projects"))
        }
    )
) { input in
    try await api.createProject(input)
}

let project = try await client.mutate(createProject, input: input)
```

SwiftUI에서는 `MutationState`를 사용합니다.

```swift
@State private var createProject = MutationState(mutation: createProjectMutation)

Button("Create") {
    createProject.mutate(input, using: client)
}
```

SwiftUI environment의 `QueryClient`를 사용하려면 `@MutationBinding`으로 client
전달을 생략할 수 있습니다.

```swift
@MutationBinding(
    options: MutationOptions<CreateProjectInput, Project>(
        onSuccess: { _, _, client in
            await client.invalidateQueries(AnyQueryKey("projects"))
        }
    ),
    run: { input in
        try await api.createProject(input)
    }
)
private var createProject: MutationState<CreateProjectInput, Project>

Button("Create") {
    createProject.mutate(input)
}
```

## Paginated Query

SunKit의 paginated-query는 두 가지 용례 중 선택할 수 있습니다. 기준은 현재 page를
누가 소유해야 하는지입니다.

`@PaginatedQueryBinding`은 page navigation을 query state의 책임으로 둘 때
사용합니다. `PaginatedQueryState`가 `input`, `page`, next/previous-page closure,
현재 subscription을 소유합니다. `.paginatedQuery(...)` modifier는 `body`에서 만든
최신 key와 fetcher를 state에 공급하고, input이 바뀌면 page를 `initialPage`로
reset합니다. 화면 instance가 살아 있는 동안 SwiftUI body가 다시 계산되어도 page가
유지되어야 하는 일반적인 pagination 화면에 적합합니다.

반대로 view가 page를 명시적으로 소유해야 하면 일반 `@State`와 `@QueryBinding`을
함께 사용합니다. page를 query key에 넣고 버튼 같은 UI에서 `@State` 값을 변경합니다.
이 방식에서는 reset 동작을 SwiftUI state lifecycle이 결정합니다. 예를 들어 push된
화면을 뒤로 pop해 해제한 뒤 다시 들어오면 `@State private var page = 1` 초기값에
따라 다시 1 page부터 시작합니다. Query layer는 현재 key를 observe하고 각
`(input, page)` result를 cache할 뿐입니다.

두 방식 모두 반환 data를 바꾸는 값은 반드시 key에 포함해야 합니다. 최근에 load한
page로 돌아갈 때 cached value가 아직 fresh라면 `QueryClient` cache를 재사용할 수
있습니다.

## Infinite Query

SunKit의 infinite-query model은 next-page-only입니다. `fetchInfiniteQuery`와
`refetch(using:)`는 cached page가 없을 때 `initialPageParam`을 load합니다. 이미
cached page가 있으면 첫 stored page parameter에서 시작해 같은 수의 loaded page를
순차 refetch하고 fresh sequence로 accumulated data를 교체합니다. `fetchNextPage`는
`getNextPageParam`이 값을 반환할 때 다음 page 하나를 append합니다.
`getNextPageParam`이 `nil`을 반환하면 fetch는 시작되지 않고 현재 cached result가
반환됩니다. Previous-page fetch와 optimistic infinite update는 MVP 범위가 아닙니다.

`maxPages`로 저장할 page 수를 제한할 수 있습니다. next-page-only model에서는
제한을 초과해 다음 page를 가져오면 가장 오래된 page를 제거하고 `pages`와
`pageParams`의 정렬을 유지합니다.

`fetchNextPage` request가 이미 in-flight인 동안 invalidation이 발생하면, append가
해당 key의 successful fetch로 완료되어 invalidation state를 clear할 수 있습니다.

```swift
@InfiniteQueryBinding(
    cacheOptions: QueryCacheOptions(staleTime: 60)
) private var feed: InfiniteQueryState<Int, Post, InfiniteData<Int, Post>>

var body: some View {
    List {
        ForEach(feed.pages.flatMap { $0 }) { post in
            PostRow(post: post)
        }
        if feed.hasNextPage {
            ProgressView()
                .onAppear { feed.fetchNextPage() }
        }
    }
    .infiniteQuery(
        $feed,
        key: ["feed"],
        initialPageParam: 1,
        maxPages: 5,
        getNextPageParam: { lastPage, _ in lastPage.nextPage }
    ) { page in
        try await api.feed(page: page)
    }
}
```

## Parallel Query

여러 heterogeneous query를 동시에 fetch하고 typed key로 result를 조회합니다.

```swift
@ParallelQueriesBinding() private var batch: ParallelQueriesState

let userKey   = QueryKey<User>("user", userID)
let reposKey  = QueryKey<[Repo]>("repos", userID)

var body: some View {
    VStack {
        if let user = batch.result?[userKey]?.data { ... }
        if let repos = batch.result?[reposKey]?.data { ... }
    }
    .parallelQueries(
        $batch,
        queries: [
            AnyParallelQuery(Query(key: userKey) { try await api.user(id: userID) }),
            AnyParallelQuery(Query(key: reposKey) { try await api.repos(userID: userID) }),
        ],
        token: userID
    )
}
```

`batch.result?[key] == nil`은 batch에 해당 typed key의 result가 저장되어 있지 않다는
뜻입니다. 실행된 query가 실패한 경우에도 `isError == true`인 `QueryResult`로
존재합니다. 실패 처리는 `error`를 확인하세요.

## 문서

DocC article은 `Sources/SunKit/SunKit.docc`에 있습니다.

먼저 볼 문서:

- `QueryKeys`
- `QueryClient`
- `Queries`
- `Invalidation`
- `SwiftUIAdapter`
- `Mutations`

## 검증

Package test를 실행합니다.

```sh
swift test
```
