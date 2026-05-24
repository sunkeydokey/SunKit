import Foundation

struct GitHubRepositorySearchPage: Decodable, Sendable {
    let totalCount: Int
    let items: [GitHubRepository]

    private enum CodingKeys: String, CodingKey {
        case totalCount = "total_count"
        case items
    }
}

struct GitHubRepository: Decodable, Identifiable, Sendable {
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

struct GitHubUser: Decodable, Identifiable, Sendable {
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

enum GitHubAPIError: LocalizedError {
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

enum GitHubAPI {
    static let repositoriesPerPage = 10

    static func searchRepositories(query: String, page: Int) async throws -> GitHubRepositorySearchPage {
        var components = URLComponents(string: "https://api.github.com/search/repositories")
        components?.queryItems = [
            URLQueryItem(name: "q", value: query.trimmingCharacters(in: .whitespacesAndNewlines)),
            URLQueryItem(name: "sort", value: "stars"),
            URLQueryItem(name: "order", value: "desc"),
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "per_page", value: String(repositoriesPerPage)),
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
