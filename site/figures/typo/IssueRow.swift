import Baton
import SwiftUI

struct IssueRow: View {
    @Fragment("""
    fragment IssueRow_issue on Issue {
      number
      titel
      author { login }
    }
    """)
    var issue: IssueRow_issue

    var body: some View {
        Text("#\(issue.number) \(issue.title)")
    }
}
