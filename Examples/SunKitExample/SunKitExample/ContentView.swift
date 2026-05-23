import SwiftUI
import SunKit
import SunKitSwiftUI

private struct ServerMessage: Sendable, Equatable {
    let title: String
    let detail: String
    let loadedAt: Date
}

private enum SubmitError: LocalizedError {
    case emptyTitle

    var errorDescription: String? {
        switch self {
        case .emptyTitle:
            return "Title cannot be empty."
        }
    }
}

struct ContentView: View {
    @Environment(\.queryClient) private var client

    @State private var messageQuery = QueryState(key: ["example", "message"]) {
        try await Task.sleep(nanoseconds: 800_000_000)
        return ServerMessage(
            title: "SunKit server state",
            detail: "Loaded from an async query.",
            loadedAt: Date()
        )
    }

    @State private var submitMutation = MutationState(
        mutation: Mutation<String, ServerMessage> { title in
            guard !title.trimmingCharacters(in: .whitespaces).isEmpty else {
                throw SubmitError.emptyTitle
            }
            try await Task.sleep(nanoseconds: 600_000_000)
            return ServerMessage(title: title, detail: "Created via mutation.", loadedAt: Date())
        }
    )

    @State private var newTitle: String = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("SunKit Example")
                            .font(.largeTitle.bold())
                        Text("Query + Mutation SwiftUI adapter demo.")
                            .foregroundStyle(.secondary)
                    }

                    sectionHeader("Query")
                    queryCard()

                    Button {
                        messageQuery.refetch(using: client)
                    } label: {
                        Label("Refetch", systemImage: "arrow.clockwise")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(messageQuery.result?.isFetching == true)

                    sectionHeader("Mutation")
                    mutationCard()

                    TextField("New message title", text: $newTitle)
                        .textFieldStyle(.roundedBorder)

                    HStack {
                        Button {
                            submitMutation.mutate(newTitle, using: client)
                        } label: {
                            Label("Submit", systemImage: "paperplane")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(submitMutation.isPending)

                        if submitMutation.isSuccess || submitMutation.isError {
                            Button("Reset") {
                                submitMutation.reset()
                                newTitle = ""
                            }
                            .buttonStyle(.bordered)
                        }
                    }

                    Spacer()
                }
                .padding()
            }
            .navigationTitle("Example")
            .onAppear {
                messageQuery.start(using: client)
            }
            .onDisappear {
                messageQuery.stop()
            }
        }
    }

    @ViewBuilder
    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.headline)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func queryCard() -> some View {
        let result = messageQuery.result

        VStack(alignment: .leading, spacing: 12) {
            if result?.isFetching == true {
                Label("Fetching...", systemImage: "hourglass")
                    .foregroundStyle(.secondary)
            }

            if let message = result?.data {
                Text(message.title)
                    .font(.title2.bold())
                Text(message.detail)
                Text(message.loadedAt, format: .dateTime.hour().minute().second())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if result?.isPending == true || result == nil {
                ProgressView("Loading query")
            }

            if result?.isStale == true {
                Label("Stale data", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }

            if let error = result?.error {
                Text(error.localizedDescription)
                    .foregroundStyle(.red)
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

    @ViewBuilder
    private func mutationCard() -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if submitMutation.isPending {
                Label("Submitting...", systemImage: "hourglass")
                    .foregroundStyle(.secondary)
            } else if let message = submitMutation.data {
                Label("Success", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text(message.title)
                    .font(.title3.bold())
                Text(message.detail)
                Text(message.loadedAt, format: .dateTime.hour().minute().second())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let error = submitMutation.error {
                Label("Failed", systemImage: "xmark.circle.fill")
                    .foregroundStyle(.red)
                Text(error.localizedDescription)
                    .foregroundStyle(.red)
            } else {
                Text("No mutation result yet.")
                    .foregroundStyle(.secondary)
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
    ContentView()
}
