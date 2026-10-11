# Compose

The Kotlin runtime is the same machine written for its platform: the same compiler, the same plans, the same fixtures under `spec/`, in Kotlin's words. Every chapter on this site shows the Compose spelling beside the SwiftUI one; this page is what differs, and the setup.

## Where the marker stands

In Swift the marker is a macro on a stored property; in Kotlin it is an annotation on the composable that renders, holds or acts. A fragment's composable takes the lens as a parameter; a query's composable resolves the operation value with `rememberQuery`; a mutation's takes its action from `rememberMutation`. The markers repeat, so one composable may carry a fragment and two mutations.

{{host star StarButton.kt | One composable hosting the fragment it renders and the two mutations it calls.}}

A document with a variable is written in a `$$"""…"""` raw string, because `$` starts a template in a plain one and GraphQL's variables need it; a document without a variable may be a plain string. The compiler reads the string dedented, so it equals the `.graphql` file an author would write.

## The same words, Kotlin's shapes

| | Swift | Kotlin |
|---|---|---|
| The document | `@Fragment("""…""")` on a stored property | `@Fragment($$"""…""")` on the composable |
| A query | `@Query(…) var issue: IssueQuery`, whose value the parent passes | `val issue = rememberQuery(IssueQuery(id = id))` |
| A mutation | `@Mutation(…) var addComment: CommentComposerAddComment.Action` | `val addComment = rememberMutation(CommentComposerAddComment)` |
| Calling it | `try await addComment(input: …, connections: [id], optimistic: …)` | `addComment(input = …, connections = listOf(id), optimistic = …)` in a coroutine |
| A subscription | `@Subscription(…) var noteAdded: NoteAdded` | `rememberSubscription(NoteAdded(…))` |
| The phase | `.loading`, `.ready(data)`, `.failed(error)` | `Phase.Loading`, `Phase.Ready(data)`, `Phase.Failed(error)` |
| `@catch` | A `Result<T, FieldErrors>` | A `kotlin.Result<T>` whose failure is a `FieldErrors` |
| `@required(action: THROW)` | A `get throws` accessor | A getter that throws `RequiredFieldError` |
| A plural link | `Baton.List`, a collection of lenses identifiable by record | `LensList`, a `List` of lenses; key items by `recordID.key` |
| The next page | `try await issues.loadNext()` in a `Task` | `issues.loadNext()` in a coroutine |
| A retention | `Retention`, released with its holder | `Hold`, released by `release()`, since Kotlin has no deinit |
| An unknown enum value | `.unknown(String)` | `Undeclared(scalarText)` |
| Observation | Observation, through the record's registrar | Compose snapshot state, one channel per slot read |
| The store's thread | The main actor | The thread that made the store; the environment's main dispatcher |

Everything else is the same by construction: the same operation text, the same records, the same notifications, the same phases, proven by the same fixtures run through code the compiler generates for Kotlin.

{{host issues IssuesScreen.kt | The README's screen in Compose. `rememberQuery` holds the retention while the composable stays and releases it when the composable leaves.}}

## The environment in a composition

```kotlin
val environment = remember(token) {
    Environment(
        Exchange(HttpTransport("https://api.github.com/graphql", credentials = { mapOf("Authorization" to "Bearer $token") })),
        store = Store(persistence = Persistence.named("GitHubTriage", version = Types.schemaDigest)),
    )
}
CompositionLocalProvider(LocalBaton provides environment) { Triage() }
```

The store belongs to the thread that made it and its entry points check the caller's; in a composition that is the composition's dispatcher. A test outside a composition passes one test dispatcher as both the main and the ingest dispatcher and runs under `runTest`.

## Android

- The runtime starts at API 23 and needs no R8 or ProGuard rules: no reflection, no serialization, no lookup by name.
- The runtime holds no `Context`, so an image named is placed by the app: `Persistence.named(name, directory = cacheDir.path)`.
- The platform has no WebSocket client, so a subscription over a socket goes through `baton-okhttp`'s `OkHttpWebSocketClient` or an app's own client.
- The process lifecycle tells the environment its activity: the sample's `Activation` observes `ProcessLifecycleOwner`, sets `isActive` and calls `revalidate()` on the return.
- An Android application module adds the generated directory through the variant API; [Gradle](../../recipes/gradle/) has the lines.

## The build

The runtime is `com.shergin.baton:baton` on Maven Central, with `baton-testing`, `baton-okhttp` and `baton-inspector` beside it, and the Gradle plugin `com.shergin.baton` runs the compiler as a task with every input and output declared, fetching the release's prebuilt binary on first use. [Gradle](../../recipes/gradle/) is the page; [the Kotlin runtime](../../kotlin/) is the tree's own README, with the layout, the dependencies and how it is built and published.

## Without Compose UI

A view model behind Android Views, a desktop window, a service: each asks the environment for the handle, holds the retention, and reads what it shows through `snapshotFlow`, which emits again when a field it read changed. [Views and view models](../../recipes/views/) is the recipe, with the code the runtime's tests compile.
