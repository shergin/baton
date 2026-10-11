package app

import androidx.compose.foundation.layout.Column
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import baton.Fragment

@Fragment($$"""
    fragment IssueRow_issue on Issue {
      number
      title
      author { login }
    }
    """)
@Composable
fun IssueRow(issue: IssueRow_issue) {
    Column {
        Text("#${issue.number} ${issue.title}")
        Text(issue.author?.login ?: "ghost")
    }
}
