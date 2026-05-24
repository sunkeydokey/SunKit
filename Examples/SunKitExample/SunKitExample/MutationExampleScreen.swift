import Foundation
import SwiftUI
import SunKit
import SunKitSwiftUI

struct MutationExampleScreen: View {
    @Environment(\.queryClient) private var client

    @State private var message = "Ship SunKit"
    @State private var shouldFail = false
    @State private var saveMessage = MutationState(
        mutation: Mutation<LocalMutationInput, LocalMutationOutput> { input in
            try await Task.sleep(nanoseconds: 600_000_000)
            if input.shouldFail {
                throw LocalMutationError.failed
            }

            return LocalMutationOutput(
                message: input.message,
                savedAt: Date()
            )
        }
    )

    var body: some View {
        Form {
            Section("Input") {
                TextField("Message", text: $message)
                Toggle("Fail next mutation", isOn: $shouldFail)
            }

            Section("Action") {
                Button {
                    saveMessage.mutate(
                        LocalMutationInput(message: message, shouldFail: shouldFail),
                        using: client
                    )
                } label: {
                    Label("Run mutation", systemImage: "square.and.pencil")
                }
                .disabled(saveMessage.isPending)

                Button("Reset") {
                    saveMessage.reset()
                }
                .disabled(saveMessage.isPending)
            }

            Section("Result") {
                if saveMessage.isPending {
                    ProgressView("Saving")
                } else if let output = saveMessage.data {
                    Label(output.message, systemImage: "checkmark.circle")
                    Text(output.savedAt.formatted(date: .abbreviated, time: .standard))
                        .foregroundStyle(.secondary)
                } else if let error = saveMessage.error {
                    ExampleErrorText(error)
                } else {
                    Text("Idle")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Mutation")
    }
}

private struct LocalMutationInput: Sendable {
    let message: String
    let shouldFail: Bool
}

private struct LocalMutationOutput: Sendable {
    let message: String
    let savedAt: Date
}

private enum LocalMutationError: LocalizedError {
    case failed

    var errorDescription: String? {
        "The local mutation failed."
    }
}
