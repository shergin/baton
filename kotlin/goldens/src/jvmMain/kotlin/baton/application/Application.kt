package baton.application

import androidx.compose.runtime.Composable
import baton.Mutation
import baton.OperationKind
import baton.goldens.TestCommitVariable
import baton.goldens.invoke
import baton.rememberMutation

// What an application writes against generated code, compiled without the
// opt-in into the runtime's contract with generated code: a file here that
// stops compiling is application API that became the generator's alone.

/**
 * A mutation's action taken from its companion, its type inferred, and
 * called; the host carries two markers, as a host of two documents does.
 * The compiler does not scan this file: the markers are here to compile.
 */
@Mutation("mutation FavoriteOn { setFavorite(id: 1, favorite: true) { character { id } } }")
@Mutation("mutation FavoriteOff { setFavorite(id: 1, favorite: false) { character { id } } }")
@Composable
fun Favorite(onCommit: (suspend () -> Unit) -> Unit) {
    val favorite = rememberMutation(TestCommitVariable)
    onCommit { favorite(commit = "1") }
}

/** Whether an operation's companion names a mutation, read through the companion. */
fun isMutation(): Boolean = TestCommitVariable.kind == OperationKind.MUTATION
