import SwiftUI
import SunKit
import SunKitSwiftUI

struct InfiniteQueryExampleScreen: View {
    private static let cacheOptions = QueryCacheOptions(staleTime: 60)

    private let queryText = "swift language:swift"

    @InfiniteQueryBinding(
        cacheOptions: Self.cacheOptions
    ) private var repositories: InfiniteQueryState<Int, GitHubRepositorySearchPage, InfiniteData<Int, GitHubRepositorySearchPage>>

    private var flattenedRepositories: [GitHubRepository] {
        repositories.pages.flatMap(\.items)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(queryText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                HStack(spacing: 12) {
                    Label("Fresh for \(Int(Self.cacheOptions.staleTime))s", systemImage: "clock")
                    if repositories.result?.isStale == false {
                        Label("Fresh", systemImage: "checkmark.circle")
                    } else if repositories.result?.isStale == true {
                        Label("Stale", systemImage: "exclamationmark.triangle")
                    }
                    if repositories.result?.isFetching == true {
                        Label("Fetching", systemImage: "arrow.clockwise")
                    }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

                if repositories.result?.isPending == true || repositories.result == nil {
                    ProgressView("Loading repositories")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if let totalCount = repositories.pages.last?.totalCount {
                    Text("\(flattenedRepositories.count.formatted()) of \(totalCount.formatted()) repositories loaded")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(flattenedRepositories) { repository in
                        RepositoryRow(repository: repository)
                    }
                }

                if let error = repositories.error {
                    ExampleErrorText(error)
                }

                Button {
                    repositories.fetchNextPage()
                } label: {
                    if repositories.isFetchingNextPage {
                        Label("Loading more", systemImage: "arrow.clockwise")
                    } else {
                        Label("Load more", systemImage: "arrow.down")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!repositories.hasNextPage || repositories.isFetchingNextPage)
                .frame(maxWidth: .infinity, alignment: .center)
                .accessibilityIdentifier("infinite.loadMoreButton")
            }
            .padding()
        }
        .accessibilityIdentifier("screen.infinite")
        .navigationTitle("Infinite Query")
        .infiniteQuery(
            $repositories,
            key: ["github", "repositories", "infinite", AnyQueryKeyPart(queryText)],
            initialPageParam: 1,
            getNextPageParam: { lastPage, pages in
                let loadedCount = pages.count * GitHubAPI.repositoriesPerPage
                return loadedCount < lastPage.totalCount ? pages.count + 1 : nil
            }
        ) { [queryText] page in
            try await GitHubAPI.searchRepositories(query: queryText, page: page)
        }
    }
}
