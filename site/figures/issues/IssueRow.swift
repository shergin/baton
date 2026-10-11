import Baton
import SwiftUI

struct IssueRow: View {
    @Fragment("""
    fragment IssueRow_issue on Issue {
      number
      title
      author { login }
    }
    """)
    var issue: IssueRow_issue

    var body: some View {
        VStack(alignment: .leading) {
            Text("#\(issue.number) \(issue.title)")
            Text(issue.author?.login ?? "ghost")
                .foregroundStyle(.secondary)
        }
    }
}
