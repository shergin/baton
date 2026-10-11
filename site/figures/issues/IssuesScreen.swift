import Baton
import SwiftUI

struct IssuesScreen: View {
    @Query("""
    query IssuesQuery($owner: String!, $name: String!) {
      repository(owner: $owner, name: $name) {
        nameWithOwner
        issues(first: 20, states: OPEN) {
          nodes { id ...IssueRow_issue }
        }
      }
    }
    """)
    var issues: IssuesQuery

    var body: some View {
        switch issues.phase {
        case .ready(let data):
            if let repo = data.repository {
                List {
                    ForEach(repo.issues.nodes ?? .empty) {
                        IssueRow(issue: $0.issueRow)
                    }
                }
                .navigationTitle(repo.nameWithOwner)
            }
        case .loading:
            ProgressView()
        case .failed(let error):
            ErrorView(error) { issues.retry() }
        }
    }
}
