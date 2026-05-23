import SwiftUI
import SunKitSwiftUI

private struct ServerMessage: Sendable, Equatable {
    let title: String
    let detail: String
    let loadedAt: Date
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

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("SunKit Example")
                        .font(.largeTitle.bold())
                    Text("A minimal SwiftUI adapter wired to observable state.")
                        .foregroundStyle(.secondary)
                }

                statusCard()

                Button {
                    messageQuery.refetch(using: client)
                } label: {
                    Label("Refetch", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(messageQuery.result?.isFetching == true)

                Spacer()
            }
            .padding()
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
    private func statusCard() -> some View {
        let result = messageQuery.result

        VStack(alignment: .leading, spacing: 12) {
            if result?.isFetching == true {
                Label("Fetching", systemImage: "hourglass")
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
}

#Preview {
    ContentView()
}
