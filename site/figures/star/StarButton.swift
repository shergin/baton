import Baton
import SwiftUI

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
            let count = repository.stargazerCount
            Task {
                if repository.viewerHasStarred {
                    try await removeStar(
                        input: RemoveStarInput(starrableId: id),
                        optimistic: .init(removeStar: .init(starrable: .init(
                            __typename: "Repository", id: id, viewerHasStarred: false, stargazerCount: count - 1
                        )))
                    )
                } else {
                    try await addStar(
                        input: AddStarInput(starrableId: id),
                        optimistic: .init(addStar: .init(starrable: .init(
                            __typename: "Repository", id: id, viewerHasStarred: true, stargazerCount: count + 1
                        )))
                    )
                }
            }
        } label: {
            Label("\(repository.stargazerCount)", systemImage: repository.viewerHasStarred ? "star.fill" : "star")
        }
        .disabled(addStar.isInFlight || removeStar.isInFlight)
    }
}

struct RepositoryScreen: View {
    @Query("""
    query RepositoryQuery($owner: String!, $name: String!) {
      repository(owner: $owner, name: $name) {
        nameWithOwner
        ...StarButton_repository
      }
    }
    """)
    var repository: RepositoryQuery

    var body: some View {
        if case .ready(let data) = repository.phase, let repo = data.repository {
            Text(repo.nameWithOwner)
            StarButton(repository: repo.starButton)
        }
    }
}
