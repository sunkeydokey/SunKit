import SwiftUI
import SunKit
import SunKitSwiftUI

struct InfiniteQueryExampleScreen: View {
    @Environment(\.queryClient) private var client

    private let queryText = "swift language:swift"

    @InfiniteQueryBinding() private var repositories: InfiniteQueryState<Int, GitHubRepositorySearchPage, InfiniteData<Int, GitHubRepositorySearchPage>>

    private var flattenedRepositories: [GitHubRepository] {
        repositories.pages.flatMap(\.items)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(queryText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

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
                    repositories.fetchNextPage(using: client)
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
            }
            .padding()
        }
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
