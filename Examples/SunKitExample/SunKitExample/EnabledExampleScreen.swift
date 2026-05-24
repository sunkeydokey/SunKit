import SwiftUI
import SunKit
import SunKitSwiftUI

struct EnabledExampleScreen: View {
    @Environment(\.queryClient) private var client

    @State private var username = ""
    @State private var followers = QueryState<[GitHubUser], [GitHubUser]>(
        key: ["github", "followers", "enabled", ""],
        options: QueryObserverOptions(
            enabled: false,
            refetchOnSubscribe: .always,
            refetchOnSceneActive: .never,
            refetchOnNetworkReconnect: .never
        )
    ) {
        []
    }

    private var isEnabled: Bool { !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("enabled 옵션은 fetch를 자동으로 시작할지 결정합니다.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("username이 비어 있으면 enabled: false — fetch가 억제됩니다.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 4) {
                    Circle()
                        .fill(isEnabled ? Color.green : Color.gray)
                        .frame(width: 8, height: 8)
                    Text(isEnabled ? "enabled: true" : "enabled: false")
                        .font(.caption.monospaced())
                        .foregroundStyle(isEnabled ? .green : .secondary)
                }

                TextField("GitHub username 입력 후 Return", text: $username)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit(search)

                if !isEnabled {
                    Label("username을 입력하면 자동으로 fetch가 시작됩니다.", systemImage: "info.circle")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else if followers.result?.isFetching == true {
                    Label("Fetching \(username)'s followers…", systemImage: "arrow.clockwise")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else if let users = followers.result?.data {
                    if users.isEmpty {
                        Text("팔로워가 없습니다.")
                            .foregroundStyle(.secondary)
                    } else {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(users) { user in
                                FollowerRow(user: user)
                            }
                        }
                    }
                } else if followers.result == nil || followers.result?.isPending == true {
                    ProgressView("불러오는 중…")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if let error = followers.result?.error {
                    ExampleErrorText(error)
                }
            }
            .padding()
        }
        .navigationTitle("Enabled")
        .onAppear {
            followers.start(using: client)
        }
        .onDisappear {
            followers.stop()
        }
    }

    private func search() {
        let trimmed = username.trimmingCharacters(in: .whitespacesAndNewlines)
        followers.update(
            key: ["github", "followers", "enabled", AnyQueryKeyPart(trimmed)],
            using: client,
            fetch: {
                guard !trimmed.isEmpty else { return [] }
                return try await GitHubAPI.followers(username: trimmed)
            },
            enabled: !trimmed.isEmpty
        )
    }
}
