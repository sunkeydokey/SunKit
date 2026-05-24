import SwiftUI

struct RepositoryRow: View {
    let repository: GitHubRepository

    var body: some View {
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
}

struct FollowerRow: View {
    let user: GitHubUser

    var body: some View {
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
}

func ExampleErrorText(_ error: Error) -> some View {
    Text(error.localizedDescription)
        .font(.subheadline)
        .foregroundStyle(.red)
}
