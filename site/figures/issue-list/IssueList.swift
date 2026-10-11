import Baton
import SwiftUI

struct IssueList: View {
    @Fragment("""
    fragment IssueList_repository on Repository
    @refetchable(queryName: "IssueListPaginationQuery")
    @argumentDefinitions(
      count: {type: "Int", defaultValue: 20}
      cursor: {type: "String"}
    ) {
      issues(first: $count, after: $cursor, states: OPEN)
      @connection(key: "IssueList_issues") {
        edges { node { id ...IssueRow_issue } }
      }
    }
    """)
    var repository: IssueList_repository

    var body: some View {
        let issues = repository.issues
        ForEach(issues.nodes) { issue in
            IssueRow(issue: issue.issueRow)
        }
        if issues.hasNext {
            ProgressView().task {
                try? await issues.loadNext()
            }
        }
    }
}

struct IssueRow: View {
    @Fragment("""
    fragment IssueRow_issue on Issue {
      number
      title
    }
    """)
    var issue: IssueRow_issue

    var body: some View {
        Text("#\(issue.number) \(issue.title)")
    }
}

struct RepositoryScreen: View {
    @Query("""
    query RepositoryQuery($owner: String!, $name: String!) {
      repository(owner: $owner, name: $name) {
        nameWithOwner
        ...IssueList_repository
      }
    }
    """)
    var repository: RepositoryQuery

    var body: some View {
        switch repository.phase {
        case .ready(let data):
            if let repo = data.repository {
                List { IssueList(repository: repo.issueList) }
                    .navigationTitle(repo.nameWithOwner)
            }
        case .loading:
            ProgressView()
        case .failed(let error):
            ErrorView(error) { repository.retry() }
        }
    }
}
