import SwiftUI
import SunKit
import SunKitSwiftUI

struct StateBackedPaginatedQueryExampleScreen: View {
    private static let pageCacheOptions = QueryCacheOptions(staleTime: 120)

    @State private var searchText = "swift language:swift"
    @State private var submittedSearchText = "swift language:swift"
    @State private var page = 1

    @QueryBinding(cacheOptions: Self.pageCacheOptions)
    private var repositories: QueryState<GitHubRepositorySearchPage, GitHubRepositorySearchPage>

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 8) {
                    TextField("Search repositories", text: $searchText)
                        .textFieldStyle(.roundedBorder)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit(searchRepositories)

                    Button(action: searchRepositories) {
                        Label("Search", systemImage: "magnifyingglass")
                    }
                    .buttonStyle(.borderedProminent)
                }

                HStack(spacing: 12) {
                    Label("Page \(page)", systemImage: "doc.text")
                    Label("View state resets on pop", systemImage: "arrow.uturn.backward")
                    if repositories.isFetching {
                        Label("Fetching", systemImage: "arrow.clockwise")
                    }
                    if repositories.result?.isStale == false {
                        Label("Fresh", systemImage: "checkmark.circle")
                    } else if repositories.result?.isStale == true {
                        Label("Stale", systemImage: "exclamationmark.triangle")
                    }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

                if let searchPage = repositories.data {
                    Text("\(searchPage.totalCount.formatted()) repositories found")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(searchPage.items) { repository in
                            RepositoryRow(repository: repository)
                        }
                    }
                } else if repositories.isPending {
                    ProgressView("Searching repositories")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if let error = repositories.error {
                    ExampleErrorText(error)
                }

                HStack {
                    Button {
                        page -= 1
                    } label: {
                        Label("Previous", systemImage: "chevron.left")
                    }
                    .buttonStyle(.bordered)
                    .disabled(page <= 1 || repositories.isFetching)

                    Spacer()

                    Button {
                        page += 1
                    } label: {
                        Label("Next", systemImage: "chevron.right")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(repositories.isFetching)
                }
            }
            .padding()
        }
        .navigationTitle("State Page Query")
        .query(
            $repositories,
            key: [
                "github",
                "repositories",
                "state-backed-page",
                AnyQueryKeyPart(submittedSearchText),
                AnyQueryKeyPart(page),
            ]
        ) {
            try await GitHubAPI.searchRepositories(query: submittedSearchText, page: page)
        }
    }

    private func searchRepositories() {
        submittedSearchText = searchText
        page = 1
    }
}
