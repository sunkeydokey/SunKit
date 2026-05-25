import SwiftUI
import SunKit
import SunKitSwiftUI

struct ParallelQueriesBindingModifierExampleScreen: View {
    @State private var usernamesText = "apple, swiftlang, github"
    @State private var submittedUsernames = ["apple", "swiftlang", "github"]
    @ParallelQueriesBinding() private var followersBatch: ParallelQueriesState

    private var batchToken: String {
        submittedUsernames.joined(separator: "|")
    }

    private var queries: [AnyParallelQuery] {
        submittedUsernames.map { username in
            AnyParallelQuery(
                Query(key: followersKey(for: username)) {
                    try await GitHubAPI.followers(username: username)
                }
            )
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("GitHub usernames", text: $usernamesText)
                        .textFieldStyle(.roundedBorder)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit(loadBatch)

                    Button(action: loadBatch) {
                        Label("Load Batch", systemImage: "rectangle.stack")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(parsedUsernames.isEmpty)
                }

                if followersBatch.isFetching {
                    Label("Fetching parallel queries", systemImage: "arrow.clockwise")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(submittedUsernames, id: \.self) { username in
                        ParallelFollowersCard(
                            username: username,
                            result: followersBatch.result?[followersKey(for: username)]
                        )
                    }
                }
            }
            .padding()
        }
        .navigationTitle("Parallel Queries")
        .parallelQueries(
            $followersBatch,
            queries: queries,
            token: batchToken,
            enabled: !submittedUsernames.isEmpty
        )
    }

    private var parsedUsernames: [String] {
        usernamesText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func loadBatch() {
        submittedUsernames = parsedUsernames
    }

    private func followersKey(for username: String) -> QueryKey<[GitHubUser]> {
        QueryKey("github", "parallel-followers", username)
    }
}

private struct ParallelFollowersCard: View {
    let username: String
    let result: QueryResult<[GitHubUser]>?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(username)
                    .font(.headline)

                Spacer()

                if let count = result?.data?.count {
                    Text("\(count) followers")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let users = result?.data {
                if users.isEmpty {
                    Text("No followers returned.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(users.prefix(5)) { user in
                            Link(destination: user.htmlURL) {
                                HStack(spacing: 8) {
                                    AsyncImage(url: user.avatarURL) { phase in
                                        switch phase {
                                        case let .success(image):
                                            image
                                                .resizable()
                                                .scaledToFill()
                                        default:
                                            Image(systemName: "person.crop.circle")
                                                .resizable()
                                                .scaledToFit()
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    .frame(width: 28, height: 28)
                                    .clipShape(Circle())

                                    Text(user.login)
                                        .font(.subheadline)
                                        .foregroundStyle(.primary)

                                    Spacer()
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            } else if result?.isError == true, let error = result?.error {
                ExampleErrorText(error)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(.quaternary)
        }
    }
}

#Preview {
    NavigationStack {
        ParallelQueriesBindingModifierExampleScreen()
    }
    .queryClient(QueryClient())
}
