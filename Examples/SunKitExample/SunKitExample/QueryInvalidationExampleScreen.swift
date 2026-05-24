import Foundation
import SwiftUI
import SunKit
import SunKitSwiftUI

struct QueryInvalidationExampleScreen: View {
    @Environment(\.queryClient) private var client

    @State private var title = "New project"
    @State private var projects = QueryState<InvalidationProjectSnapshot, InvalidationProjectSnapshot>(
        key: Self.projectsKey
    ) {
        try await Self.server.fetchProjects()
    }
    @State private var createProject = MutationState(
        mutation: Mutation<String, InvalidationProject>(
            options: MutationOptions(
                onSuccess: { _, _, client in
                    await client.invalidateQueries(AnyQueryKey("example", "projects"), exact: true)
                }
            )
        ) { title in
            try await Self.server.createProject(title: title)
        }
    )

    private static let server = InvalidationExampleServer()
    private static let projectsKey: [AnyQueryKeyPart] = ["example", "projects"]

    var body: some View {
        Form {
            Section("Subscribed server state") {
                if projects.result?.isFetching == true {
                    ProgressView("Refetching projects")
                }

                if let snapshot = projects.result?.data {
                    LabeledContent("Server fetches", value: snapshot.fetchCount.formatted())
                    LabeledContent("Last fetched") {
                        Text(snapshot.fetchedAt.formatted(date: .omitted, time: .standard))
                    }

                    ForEach(snapshot.projects) { project in
                        Label(project.title, systemImage: "folder")
                    }
                } else if projects.result?.isPending == true || projects.result == nil {
                    ProgressView("Loading projects")
                }

                if let error = projects.result?.error {
                    ExampleErrorText(error)
                }
            }

            Section("Mutation onSuccess invalidation") {
                TextField("Project title", text: $title)
                    .textInputAutocapitalization(.sentences)

                Button {
                    let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmedTitle.isEmpty else { return }

                    createProject.mutate(trimmedTitle, using: client)
                    title = ""
                } label: {
                    Label("Create project", systemImage: "plus")
                }
                .disabled(createProject.isPending)

                if createProject.isPending {
                    ProgressView("Creating project")
                } else if let project = createProject.data {
                    Label(project.title, systemImage: "checkmark.circle")
                } else if let error = createProject.error {
                    ExampleErrorText(error)
                }
            }

            Section("Manual invalidation") {
                Button {
                    Task {
                        await client.invalidateQueries(AnyQueryKey("example", "projects"), exact: true)
                    }
                } label: {
                    Label("Invalidate subscribed query", systemImage: "arrow.clockwise")
                }
                .disabled(projects.result?.isFetching == true)
            }
        }
        .navigationTitle("Query Invalidation")
        .onAppear {
            projects.start(using: client)
        }
        .onDisappear {
            projects.stop()
        }
    }
}

private actor InvalidationExampleServer {
    private var nextID = 3
    private var fetchCount = 0
    private var projects = [
        InvalidationProject(id: 1, title: "Document query keys"),
        InvalidationProject(id: 2, title: "Wire invalidation examples"),
    ]

    func fetchProjects() async throws -> InvalidationProjectSnapshot {
        try await Task.sleep(nanoseconds: 400_000_000)
        fetchCount += 1

        return InvalidationProjectSnapshot(
            projects: projects,
            fetchCount: fetchCount,
            fetchedAt: Date()
        )
    }

    func createProject(title: String) async throws -> InvalidationProject {
        try await Task.sleep(nanoseconds: 300_000_000)
        let project = InvalidationProject(id: nextID, title: title)
        nextID += 1
        projects.append(project)
        return project
    }
}

private struct InvalidationProjectSnapshot: Sendable {
    let projects: [InvalidationProject]
    let fetchCount: Int
    let fetchedAt: Date
}

private struct InvalidationProject: Identifiable, Sendable {
    let id: Int
    let title: String
}
