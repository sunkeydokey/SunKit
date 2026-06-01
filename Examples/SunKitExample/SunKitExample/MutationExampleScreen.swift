import Foundation
import SwiftUI
import SunKit
import SunKitSwiftUI

struct MutationExampleScreen: View {
    private static let server = LocalMutationServer()
    private static let projectsKey: [AnyQueryKeyPart] = ["mutation-example", "projects"]

    @State private var title = "Write mutation docs"
    @State private var shouldFail = false
    @QueryBinding(
        options: QueryObserverOptions(
            refetchOnSubscribe: .always,
            refetchOnSceneActive: .never,
            refetchOnNetworkReconnect: .never
        )
    )
    private var projects: QueryState<LocalMutationSnapshot, LocalMutationSnapshot>

    @MutationBinding(
        options: MutationOptions<LocalMutationInput, LocalMutationProject>(
            onSuccess: { _, _, client in
                await client.invalidateQueries(AnyQueryKey(Self.projectsKey), exact: true)
            }
        ),
        run: { input in
            if input.shouldFail {
                throw LocalMutationError.failed
            }

            return try await Self.server.createProject(title: input.title)
        }
    )
    private var createProject: MutationState<LocalMutationInput, LocalMutationProject>

    var body: some View {
        Form {
            Section("Input") {
                TextField("Project title", text: $title)
                    .textInputAutocapitalization(.sentences)
                Toggle("Fail next mutation", isOn: $shouldFail)
            }

            Section("Action") {
                Button {
                    let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmedTitle.isEmpty else { return }

                    createProject.mutate(
                        LocalMutationInput(title: trimmedTitle, shouldFail: shouldFail)
                    )
                    title = ""
                } label: {
                    Label("Create project", systemImage: "plus")
                }
                .disabled(createProject.isPending)

                Button("Reset") {
                    createProject.reset()
                }
                .disabled(createProject.isPending)
            }

            Section("Mutation result") {
                if createProject.isPending {
                    ProgressView("Creating project")
                } else if let project = createProject.data {
                    Label(project.title, systemImage: "checkmark.circle")
                } else if let error = createProject.error {
                    ExampleErrorText(error)
                } else {
                    Text("Idle")
                        .foregroundStyle(.secondary)
                }
            }

            Section("Invalidated query") {
                if projects.isFetching {
                    ProgressView("Refetching projects")
                }

                if let snapshot = projects.data {
                    LabeledContent("Server fetches", value: snapshot.fetchCount.formatted())
                    ForEach(snapshot.projects) { project in
                        Label(project.title, systemImage: "folder")
                    }
                } else if projects.isPending {
                    ProgressView("Loading projects")
                }

                if let error = projects.error {
                    ExampleErrorText(error)
                }
            }
        }
        .navigationTitle("Mutation")
        .query($projects, key: Self.projectsKey) {
            try await Self.server.fetchProjects()
        }
    }
}

private struct LocalMutationInput: Sendable {
    let title: String
    let shouldFail: Bool
}

private struct LocalMutationProject: Identifiable, Sendable {
    let id: Int
    let title: String
}

private struct LocalMutationSnapshot: Sendable {
    let projects: [LocalMutationProject]
    let fetchCount: Int
}

private enum LocalMutationError: LocalizedError {
    case failed

    var errorDescription: String? {
        "The local mutation failed."
    }
}

private actor LocalMutationServer {
    private var nextID = 3
    private var fetchCount = 0
    private var projects = [
        LocalMutationProject(id: 1, title: "Define query keys"),
        LocalMutationProject(id: 2, title: "Document invalidation"),
    ]

    func fetchProjects() async throws -> LocalMutationSnapshot {
        try await Task.sleep(nanoseconds: 400_000_000)
        fetchCount += 1
        return LocalMutationSnapshot(projects: projects, fetchCount: fetchCount)
    }

    func createProject(title: String) async throws -> LocalMutationProject {
        try await Task.sleep(nanoseconds: 500_000_000)
        let project = LocalMutationProject(id: nextID, title: title)
        nextID += 1
        projects.append(project)
        return project
    }
}
