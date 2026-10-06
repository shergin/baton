import Baton
import SwiftUI

/// A repository that does not exist comes back as null with a field error;
/// `@catch` turns the field into a `Result`, so the screen shows the server's
/// reason instead of guessing.
struct RepositoryScreen: View {
    @Query("""
        query RepositoryQuery($owner: String!, $name: String!) {
          repository(owner: $owner, name: $name) @catch {
            nameWithOwner
            description
            forkCount
            ...StarButton_repository
            ...IssueList_repository
          }
        }
        """)
    var repository: RepositoryQuery

    var body: some View {
        PhaseView(phase: repository.phase, retry: repository.retry) { data in
            switch data.repository {
            case .failure(let errors):
                ContentUnavailableView("Could not load the repository", systemImage: "questionmark.folder", description: Text(errors.description))
            case .success(nil):
                ContentUnavailableView("No such repository", systemImage: "questionmark.folder")
            case .success(let repo?):
                List {
                    Section {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(repo.nameWithOwner).font(.title2.bold())
                            if let description = repo.description { Text(description) }
                            HStack(spacing: 16) {
                                Label("\(repo.forkCount) forks", systemImage: "tuningfork")
                                StarButton(repository: repo.starButton)
                            }
                            .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                    IssueList(repository: repo.issueList)
                }
            }
        }
        .navigationTitle("\(repository.owner)/\(repository.name)")
    }
}

/// Open issues as a cursor connection. The fragment is refetchable, so the
/// connection lens can fetch the next page with the fragment's own query; the
/// pages merge into one list in the store, and `hasNext` and `isLoadingNext`
/// are read from it like any other field.
struct IssueList: View {
    @Fragment("""
        fragment IssueList_repository on Repository
        @refetchable(queryName: "IssueListPaginationQuery")
        @argumentDefinitions(count: {type: "Int", defaultValue: 20}, cursor: {type: "String"}) {
          issues(first: $count, after: $cursor, states: OPEN, orderBy: {field: CREATED_AT, direction: DESC})
            @connection(key: "IssueList_issues") {
            totalCount
            edges { node { id ...IssueRow_issue } }
          }
        }
        """)
    var repository: IssueList_repository

    var body: some View {
        Section("\(repository.issues.totalCount) open issues") {
            ForEach(repository.issues.nodes) { issue in
                // The row requires an author; an issue without one reads as no row.
                if let row = issue.issueRow {
                    NavigationLink(value: IssueQuery(id: issue.id)) { IssueRow(issue: row) }
                }
            }
            if repository.issues.hasNext {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
                .task(id: repository.issues.pageInfo.endCursor) {
                    try? await repository.issues.loadNext()
                }
            }
        }
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
