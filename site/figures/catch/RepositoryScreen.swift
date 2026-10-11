import Baton
import SwiftUI

struct IssueRow: View {
    @Fragment("""
    fragment IssueRow_issue on Issue {
      number
      title
      author @required(action: LOG) { login }
    }
    """)
    var issue: IssueRow_issue

    var body: some View {
        Text("#\(issue.number) \(issue.title) by \(issue.author.login)")
    }
}

struct RepositoryScreen: View {
    @Query("""
    query RepositoryQuery($owner: String!, $name: String!) {
      repository(owner: $owner, name: $name) @catch {
        nameWithOwner
        description
        issues(first: 5, states: OPEN) {
          nodes { id ...IssueRow_issue }
        }
      }
    }
    """)
    var repository: RepositoryQuery

    var body: some View {
        switch repository.phase {
        case .ready(let data):
            switch data.repository {
            case .failure(let errors):
                Text("Could not load the repository: \(errors.description)")
            case .success(nil):
                Text("No such repository")
            case .success(let repo?):
                List {
                    Text(repo.nameWithOwner).font(.headline)
                    if let description = repo.description { Text(description) }
                    ForEach(repo.issues.nodes ?? .empty) { issue in
                        // An issue whose author is gone reads as no row.
                        if let row = issue.issueRow { IssueRow(issue: row) }
                    }
                }
            }
        case .loading:
            ProgressView()
        case .failed(let error):
            ErrorView(error) { repository.retry() }
        }
    }
}
