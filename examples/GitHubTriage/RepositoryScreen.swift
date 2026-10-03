import Baton
import SwiftUI

struct RepositoryScreen: View {
    @Query("""
        query RepositoryQuery($owner: String!, $name: String!) {
          repository(owner: $owner, name: $name) {
            nameWithOwner
            description
            forkCount
            issues(states: OPEN) { totalCount }
            ...StarButton_repository
          }
        }
        """)
    var repository: RepositoryQuery

    var body: some View {
        PhaseView(phase: repository.phase, retry: repository.retry) { data in
            if let repo = data.repository {
                VStack(alignment: .leading, spacing: 12) {
                    Text(repo.nameWithOwner).font(.title2.bold())
                    if let description = repo.description { Text(description) }
                    HStack(spacing: 16) {
                        Label("\(repo.forkCount) forks", systemImage: "tuningfork")
                        Label("\(repo.issues.totalCount) open issues", systemImage: "circle")
                        StarButton(repository: repo.starButton)
                    }
                    .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ContentUnavailableView("No such repository", systemImage: "questionmark.folder")
            }
        }
        .navigationTitle("\(repository.owner)/\(repository.name)")
    }
}

/// The star toggle. Each mutation is an action value; the optimistic response
/// is typed, goes through the same ingest as a server response, and is
/// reverted if the server fails. `starrable` is an interface, so the
/// optimistic response names the concrete type.
struct StarButton: View {
    @Fragment("""
        fragment StarButton_repository on Repository {
          id
          viewerHasStarred
          stargazerCount
        }
        """)
    var repository: StarButton_repository

    @Mutation("""
        mutation StarButtonAddStar($input: AddStarInput!) {
          addStar(input: $input) {
            starrable { id viewerHasStarred ... on Repository { stargazerCount } }
          }
        }
        """)
    var addStar: StarButtonAddStar.Action

    @Mutation("""
        mutation StarButtonRemoveStar($input: RemoveStarInput!) {
          removeStar(input: $input) {
            starrable { id viewerHasStarred ... on Repository { stargazerCount } }
          }
        }
        """)
    var removeStar: StarButtonRemoveStar.Action

    var body: some View {
        Button {
            let id = repository.id
            let starred = repository.viewerHasStarred
            let count = repository.stargazerCount
            Task {
                do {
                    if starred {
                        try await removeStar(
                            input: .object(["starrableId": .string(id)]),
                            optimistic: .init(removeStar: .init(starrable: .init(
                                __typename: "Repository", id: id, viewerHasStarred: false, stargazerCount: count - 1
                            )))
                        )
                    } else {
                        try await addStar(
                            input: .object(["starrableId": .string(id)]),
                            optimistic: .init(addStar: .init(starrable: .init(
                                __typename: "Repository", id: id, viewerHasStarred: true, stargazerCount: count + 1
                            )))
                        )
                    }
                } catch {
                    print("star toggle failed: \(error)")
                }
            }
        } label: {
            Label("\(repository.stargazerCount)", systemImage: repository.viewerHasStarred ? "star.fill" : "star")
                .foregroundStyle(repository.viewerHasStarred ? .yellow : .secondary)
        }
        .disabled(addStar.isInFlight || removeStar.isInFlight)
    }
}
