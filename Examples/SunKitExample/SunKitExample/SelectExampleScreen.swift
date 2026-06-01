import SwiftUI
import SunKit
import SunKitSwiftUI

private struct FollowerSummary: Sendable {
    let count: Int
    let logins: [String]
}

struct SelectExampleScreen: View {
    @Environment(\.queryClient) private var client

    @State private var username = "apple"
    @State private var followers = QueryState<[GitHubUser], FollowerSummary>(
        key: ["github", "followers", "select", "apple"],
        options: QueryObserverOptions(
            refetchOnSubscribe: .always,
            refetchOnSceneActive: .never,
            refetchOnNetworkReconnect: .never,
            select: { users in
                FollowerSummary(
                    count: users.count,
                    logins: users.map(\.login)
                )
            }
        )
    ) {
        try await GitHubAPI.followers(username: "apple")
    }

    @State private var repositories = InfiniteQueryState<Int, GitHubRepositorySearchPage, [GitHubRepository]>(
        query: InfiniteQuery<Int, GitHubRepositorySearchPage>(
            key: ["github", "repositories", "select", "swift language:swift"],
            initialPageParam: 1,
            getNextPageParam: { lastPage, pages in
                let loadedCount = pages.count * GitHubAPI.repositoriesPerPage
                return loadedCount < lastPage.totalCount ? pages.count + 1 : nil
            }
        ) { page in
            try await GitHubAPI.searchRepositories(query: "swift language:swift", page: page)
        },
        options: QueryObserverOptions(
            refetchOnSubscribe: .always,
            refetchOnSceneActive: .never,
            refetchOnNetworkReconnect: .never,
            select: { data in
                data.pages.flatMap(\.items)
            }
        )
    )

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                followerSection
                repositorySection
            }
            .padding()
        }
        .navigationTitle("Select")
        .onAppear {
            followers.start(using: client)
            repositories.start(using: client)
        }
        .onDisappear {
            followers.stop()
            repositories.stop()
        }
    }

    private var followerSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                TextField("GitHub username", text: $username)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit(loadFollowers)

                Button(action: loadFollowers) {
                    Label("Load", systemImage: "person.2")
                }
                .buttonStyle(.borderedProminent)
            }

            if followers.isFetching {
                Label("Fetching followers", systemImage: "arrow.clockwise")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if let summary = followers.data {
                Text("\(summary.count.formatted()) followers selected")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(summary.logins, id: \.self) { login in
                        Label(login, systemImage: "person.crop.circle")
                    }
                }
            } else {
                ProgressView("Loading followers")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let error = followers.error {
                ExampleErrorText(error)
            }
        }
    }

    private var repositorySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("swift language:swift")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if repositories.result?.isPending == true || repositories.result == nil {
                ProgressView("Loading repositories")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let selected = repositories.data {
                if let totalCount = repositories.pages.last?.totalCount {
                    Text("\(selected.count.formatted()) of \(totalCount.formatted()) repositories selected")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(selected) { repository in
                        RepositoryRow(repository: repository)
                    }
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
        }
    }

    private func loadFollowers() {
        let username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !username.isEmpty else { return }

        followers.update(key: ["github", "followers", "select", AnyQueryKeyPart(username)], using: client) {
            try await GitHubAPI.followers(username: username)
        }
    }
}
