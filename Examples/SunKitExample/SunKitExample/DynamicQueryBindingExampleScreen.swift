import SwiftUI
import SunKit
import SunKitSwiftUI

struct DynamicQueryBindingExampleScreen: View {
    @State private var username = "apple"

    var body: some View {
        List {
            Section("Input") {
                TextField("Username", text: $username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }

            Section("Broken direct capture") {
                BrokenDirectQueryCapture(username: username)
            }

            Section("QueryBinding modifier") {
                WorkingQueryBindingCapture(username: username)
            }
        }
        .navigationTitle("Dynamic Query")
    }
}

private struct BrokenDirectQueryCapture: View {
    @Environment(\.queryClient) private var client
    let username: String

    @State private var followers = QueryState<[String], [String]>(
        key: ["example", "broken-dynamic-query", "initial"],
        options: QueryObserverOptions(refetchOnSubscribe: .always)
    ) {
        await DynamicQueryDemoAPI.followers(username: "initial")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("View input: \(username)")
                .font(.subheadline)

            if let users = followers.result?.data {
                ForEach(users, id: \.self) { user in
                    Label(user, systemImage: "xmark.circle")
                        .foregroundStyle(.secondary)
                }
            } else {
                ProgressView()
            }

            Text("This intentionally does not call update when the input changes.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onAppear {
            followers.start(using: client)
        }
        .onDisappear {
            followers.stop()
        }
    }
}

private struct WorkingQueryBindingCapture: View {
    let username: String

    @QueryBinding(
        options: QueryObserverOptions(refetchOnSubscribe: .always)
    ) private var followers: QueryState<[String], [String]>

    private var trimmedUsername: String {
        username.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("View input: \(trimmedUsername)")
                .font(.subheadline)

            if followers.result?.isFetching == true {
                ProgressView()
            }

            if let users = followers.result?.data {
                ForEach(users, id: \.self) { user in
                    Label(user, systemImage: "checkmark.circle")
                }
            }
        }
        .query(
            $followers,
            key: ["example", "working-dynamic-query", AnyQueryKeyPart(trimmedUsername)],
            enabled: !trimmedUsername.isEmpty
        ) { [trimmedUsername] in
            await DynamicQueryDemoAPI.followers(username: trimmedUsername)
        }
    }
}

private enum DynamicQueryDemoAPI {
    static func followers(username: String) async -> [String] {
        try? await Task.sleep(nanoseconds: 150_000_000)
        let normalized = username.isEmpty ? "empty" : username
        return [
            "\(normalized)-follower-1",
            "\(normalized)-follower-2",
            "\(normalized)-follower-3",
        ]
    }
}

