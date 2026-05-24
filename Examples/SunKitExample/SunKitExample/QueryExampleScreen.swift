import SwiftUI
import SunKit
import SunKitSwiftUI

struct QueryExampleScreen: View {
    @Environment(\.queryClient) private var client

    @State private var username = "apple"
    @State private var followers = QueryState<[GitHubUser], [GitHubUser]>(
        key: ["github", "followers", "apple"]
    ) {
        try await GitHubAPI.followers(username: "apple")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
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

                if followers.result?.isFetching == true {
                    Label("Fetching followers", systemImage: "arrow.clockwise")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                if let users = followers.result?.data {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(users) { user in
                            FollowerRow(user: user)
                        }
                    }
                } else if followers.result?.isPending == true || followers.result == nil {
                    ProgressView("Loading followers")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if let error = followers.result?.error {
                    ExampleErrorText(error)
                }
            }
            .padding()
        }
        .navigationTitle("Query")
        .onAppear {
            followers.start(using: client)
        }
        .onDisappear {
            followers.stop()
        }
    }

    private func loadFollowers() {
        let username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !username.isEmpty else { return }

        followers.update(key: ["github", "followers", AnyQueryKeyPart(username)], using: client) {
            try await GitHubAPI.followers(username: username)
        }
    }
}
