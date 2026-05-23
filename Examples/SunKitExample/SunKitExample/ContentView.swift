import Foundation
import SwiftUI
import SunKit
import SunKitSwiftUI

private struct GitHubRepositorySearchPage: Decodable, Sendable {
    let totalCount: Int
    let items: [GitHubRepository]

    private enum CodingKeys: String, CodingKey {
        case totalCount = "total_count"
        case items
    }
}

private struct GitHubRepository: Decodable, Identifiable, Sendable {
    let id: Int
    let name: String
    let fullName: String
    let htmlURL: URL
    let description: String?
    let stars: Int
    let language: String?
    let owner: GitHubUser

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case fullName = "full_name"
        case htmlURL = "html_url"
        case description
        case stars = "stargazers_count"
        case language
        case owner
    }
}

private struct GitHubUser: Decodable, Identifiable, Sendable {
    let id: Int
    let login: String
    let avatarURL: URL
    let htmlURL: URL

    private enum CodingKeys: String, CodingKey {
        case id
        case login
        case avatarURL = "avatar_url"
        case htmlURL = "html_url"
    }
}

private enum GitHubAPIError: LocalizedError {
    case invalidURL
    case badStatus(Int)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "The GitHub API URL could not be built."
        case let .badStatus(status):
            return "GitHub returned HTTP \(status)."
        }
    }
}

private enum GitHubAPI {
    static func searchRepositories(query: String, page: Int) async throws -> GitHubRepositorySearchPage {
        var components = URLComponents(string: "https://api.github.com/search/repositories")
        components?.queryItems = [
            URLQueryItem(name: "q", value: query.trimmingCharacters(in: .whitespacesAndNewlines)),
            URLQueryItem(name: "sort", value: "stars"),
            URLQueryItem(name: "order", value: "desc"),
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "per_page", value: "10"),
        ]

        return try await request(components?.url)
    }

    static func followers(username: String) async throws -> [GitHubUser] {
        let username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        var components = URLComponents(string: "https://api.github.com/users/\(username)/followers")
        components?.queryItems = [
            URLQueryItem(name: "per_page", value: "20"),
        ]

        return try await request(components?.url)
    }

    private static func request<Value: Decodable>(_ url: URL?) async throws -> Value {
        guard let url else {
            throw GitHubAPIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("SunKitExample", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw GitHubAPIError.badStatus((response as? HTTPURLResponse)?.statusCode ?? -1)
        }

        return try JSONDecoder().decode(Value.self, from: data)
    }
}

struct ContentView: View {
    @Environment(\.queryClient) private var client

    @State private var repositorySearchText = "swift language:swift"
    @State private var followerUsername = "apple"

    @State private var repositories = PaginatedQueryState<String, Int, GitHubRepositorySearchPage>(
        input: "swift language:swift",
        initialPage: 1,
        key: { query, page in
            ["github", "repositories", AnyQueryKeyPart(query), AnyQueryKeyPart(page)]
        },
        nextPage: { $0 + 1 },
        previousPage: { $0 - 1 },
        canMoveToPreviousPage: { $0 > 1 }
    ) { query, page in
        try await GitHubAPI.searchRepositories(query: query, page: page)
    }

    @State private var followers = QueryState<[GitHubUser]>(
        key: ["github", "followers", "apple"]
    ) {
        try await GitHubAPI.followers(username: "apple")
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    repositorySearchSection
                    followersSection
                }
                .padding()
            }
            .navigationTitle("SunKit")
            .onAppear {
                repositories.start(using: client)
                followers.start(using: client)
            }
            .onDisappear {
                repositories.stop()
                followers.stop()
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("GitHub API Example")
                .font(.largeTitle.bold())
            Text("Real public API calls through QueryState and PaginatedQueryState.")
                .foregroundStyle(.secondary)
        }
    }

    private var repositorySearchSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Repository Search")

            HStack(spacing: 8) {
                TextField("Search repositories", text: $repositorySearchText)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit {
                        searchRepositories()
                    }

                Button {
                    searchRepositories()
                } label: {
                    Label("Search", systemImage: "magnifyingglass")
                }
                .buttonStyle(.borderedProminent)
            }

            queryStateLine(
                isFetching: repositories.result?.isFetching == true,
                isStale: repositories.result?.isStale == true,
                page: repositories.page
            )

            if let searchPage = repositories.result?.data {
                Text("\(searchPage.totalCount.formatted()) repositories found")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(searchPage.items) { repository in
                        repositoryRow(repository)
                    }
                }
            } else if repositories.result?.isPending == true || repositories.result == nil {
                ProgressView("Searching repositories")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let error = repositories.result?.error {
                errorText(error)
            }

            HStack {
                Button {
                    repositories.previousPage(using: client)
                } label: {
                    Label("Previous", systemImage: "chevron.left")
                }
                .buttonStyle(.bordered)
                .disabled(repositories.page <= 1 || repositories.result?.isFetching == true)

                Spacer()

                Button {
                    repositories.nextPage(using: client)
                } label: {
                    Label("Next", systemImage: "chevron.right")
                }
                .buttonStyle(.borderedProminent)
                .disabled(repositories.result?.isFetching == true)
            }
        }
    }

    private var followersSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Followers")

            HStack(spacing: 8) {
                TextField("GitHub username", text: $followerUsername)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit {
                        loadFollowers()
                    }

                Button {
                    loadFollowers()
                } label: {
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
                        followerRow(user)
                    }
                }
            } else if followers.result?.isPending == true || followers.result == nil {
                ProgressView("Loading followers")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let error = followers.result?.error {
                errorText(error)
            }
        }
    }

    private func searchRepositories() {
        repositories.setInput(repositorySearchText, using: client)
    }

    private func loadFollowers() {
        let username = followerUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !username.isEmpty else { return }

        followers.update(key: ["github", "followers", AnyQueryKeyPart(username)], using: client) {
            try await GitHubAPI.followers(username: username)
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.headline)
            .foregroundStyle(.secondary)
    }

    private func queryStateLine(isFetching: Bool, isStale: Bool, page: Int) -> some View {
        HStack(spacing: 12) {
            Label("Page \(page)", systemImage: "doc.text")
            if isFetching {
                Label("Fetching", systemImage: "arrow.clockwise")
            }
            if isStale {
                Label("Stale", systemImage: "exclamationmark.triangle")
            }
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }

    private func repositoryRow(_ repository: GitHubRepository) -> some View {
        Link(destination: repository.htmlURL) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(repository.fullName)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Spacer()
                    Label(repository.stars.formatted(), systemImage: "star.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let description = repository.description, !description.isEmpty {
                    Text(description)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                HStack(spacing: 12) {
                    Text(repository.owner.login)
                    if let language = repository.language {
                        Text(language)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
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
        .buttonStyle(.plain)
    }

    private func followerRow(_ user: GitHubUser) -> some View {
        Link(destination: user.htmlURL) {
            HStack(spacing: 12) {
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
                .frame(width: 44, height: 44)
                .clipShape(Circle())

                Text(user.login)
                    .font(.headline)
                    .foregroundStyle(.primary)

                Spacer()

                Image(systemName: "arrow.up.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding()
            .background(.background)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(.quaternary)
            }
        }
        .buttonStyle(.plain)
    }

    private func errorText(_ error: Error) -> some View {
        Text(error.localizedDescription)
            .font(.subheadline)
            .foregroundStyle(.red)
    }
}

#Preview {
    ContentView()
}
