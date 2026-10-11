import Baton
import SwiftUI

struct IssuesScreen: View {
    @Query("""
    query IssuesQuery($owner: String!, $name: String!) {
      repository(owner: $owner, name: $name) {
        issues(first: 20, states: OPEN) {
          nodes { id ...IssueRow_issue }
        }
      }
    }
    """)
    var issues: IssuesQuery

    var body: some View { EmptyView() }
}
