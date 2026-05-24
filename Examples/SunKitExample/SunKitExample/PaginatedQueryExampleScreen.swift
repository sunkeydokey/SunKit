import SwiftUI
import SunKit
import SunKitSwiftUI

struct PaginatedQueryExampleScreen: View {
    @Environment(\.queryClient) private var client

    @State private var searchText = "swift language:swift"
    @State private var repositories = PaginatedQueryState<String, Int, GitHubRepositorySearchPage, GitHubRepositorySearchPage>(
        input: "swift language:swift",
        initialPage: 1,
        key: { query, page in
            ["github", "repositories", AnyQueryKeyPart(query), AnyQueryKeyPart(page)]
        },
        nextPage: { $0 + 1 },
        previousPage: { $0 - 1 },
        canMoveToPreviousPage: { $0 > 1 }
    ) { query, page in
        try await GitHubAPI.searchRepositories(query: query, page: page)
    }

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
                    Label("Page \(repositories.page)", systemImage: "doc.text")
                    if repositories.result?.isFetching == true {
                        Label("Fetching", systemImage: "arrow.clockwise")
                    }
                    if repositories.result?.isStale == true {
                        Label("Stale", systemImage: "exclamationmark.triangle")
                    }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)

                if let searchPage = repositories.result?.data {
                    Text("\(searchPage.totalCount.formatted()) repositories found")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(searchPage.items) { repository in
                            RepositoryRow(repository: repository)
                        }
                    }
                } else if repositories.result?.isPending == true || repositories.result == nil {
                    ProgressView("Searching repositories")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if let error = repositories.result?.error {
                    ExampleErrorText(error)
                }

                HStack {
                    Button {
                        repositories.previousPage(using: client)
                    } label: {
                        Label("Previous", systemImage: "chevron.left")
                    }
                    .buttonStyle(.bordered)
                    .disabled(repositories.page <= 1 || repositories.result?.isFetching == true)

                    Spacer()

                    Button {
                        repositories.nextPage(using: client)
                    } label: {
                        Label("Next", systemImage: "chevron.right")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(repositories.result?.isFetching == true)
                }
            }
            .padding()
        }
        .navigationTitle("Paginated Query")
        .onAppear {
            repositories.start(using: client)
        }
        .onDisappear {
            repositories.stop()
        }
    }

    private func searchRepositories() {
        repositories.setInput(searchText, using: client)
    }
}
