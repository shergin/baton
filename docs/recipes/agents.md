# Agents: integrating Baton into an app

This page is for a coding agent asked to integrate Baton into an app, or to
write a screen in an app that has it. It says what to read, the shape a
screen takes, what never to write, what to run, and what to check before
handing the change back. Every word it uses is defined in
[`terminology.md`](../terminology.md). Where this page and that file
differ, that file is right.

A SwiftPM checkout of Baton carries this `docs/` tree, so you read it
locally, at the version the app resolved. The Maven artifact carries no
docs, so read them on GitHub at the tag the app depends on.

## Read first

1. The [README](../../README.md): what Baton is and is not, and the
   SwiftUI and Compose spellings side by side.
2. [`terminology.md`](../terminology.md), the closed vocabulary. Do not
   name a concept it does not name.
3. The platform's build:
   - SwiftPM: add the package, `https://github.com/shergin/baton`. Depend
     on `.product(name: "Baton", package: "baton")`. Put
     `plugins: [.plugin(name: "BatonPlugin", package: "baton")]` on each
     target that holds documents. The plugin reads `baton.json` from the
     target's directory, then the package root
     ([`batonc.md`](batonc.md#under-the-swiftpm-plugin)). The samples'
     `examples/RickAndMorty/baton.json` is the smallest one.
   - Gradle: [`gradle.md`](gradle.md), the runtime from Maven Central and
     the plugin `com.shergin.baton`.
   - Bazel: [`bazel.md`](bazel.md).
   - Anything else: [`batonc.md`](batonc.md), the command's contract.
4. [`testing.md`](testing.md), a store without a server, for previews and
   tests.

Then read one sample screen whole before writing one. Swift is under
`examples/GitHubTriage/`, and Kotlin is under `kotlin/samples/github/`.
They cover a query, fragments, a connection, a mutation with an optimistic
response, an edge directive, `@required`, and `@catch`. Coming from Relay,
[`porting-from-relay.md`](porting-from-relay.md) puts the words side by
side.

## The shape of a screen

- **One query per screen.** The screen declares one `@Query` whose
  document spreads its children's fragments, and the compiler assembles
  the operation. A part that may arrive later is a
  [deferred fragment](../terminology.md#documents), not a second query.
  The parent, or a navigation path, constructs the query's
  [operation value](../terminology.md#generated) from its variables, as
  `IssueQuery(id: issue.id)`.
- **A fragment per view, beside its body.** Each view that reads server
  data declares a `@Fragment` for exactly the fields it reads, and takes
  the fragment's [lens](../terminology.md#generated). Fragment names
  follow Relay's convention, `<View>_<prop>`, as `IssueRow_issue`.
- **The parent passes the child its lens through the spread's accessor.**
  `...IssueRow_issue` in the parent compiles to an accessor, `issueRow`,
  and the parent writes `IssueRow(issue: issue.issueRow)`. `@alias(as:)`
  names the accessor when the derived name does not read well. The parent
  cannot read the child's fields, and should not try.
- **A list is a connection.** The fragment that owns the list is
  `@refetchable(queryName:)` with `@argumentDefinitions` for `count` and
  `cursor`, and the field is `@connection(key:)`. The view reads `nodes`
  and `hasNext`, and calls `loadNext` when the end shows
  ([Pagination](../terminology.md#lists)). The store merges the pages.
- **A list the schema pages by number is `@paged`.** On a schema without
  cursors, the list field inside the field that takes the page carries
  `@paged(key:, page:)`, the page is an `Int!` variable of the query, and
  `pageInfo { hasNextPage }` is selected beside the list. The view reads
  the list through the wrapper's lens, with `hasNext`, and calls
  `loadNext()` when the end shows; no `@refetchable` fragment is needed
  ([Paged list](../terminology.md#lists)).
- **A write is an action.** A `@Mutation` compiles to an
  [action](../terminology.md#generated). Call it with one argument per
  variable, and an optional typed `OptimisticResponse`. When the write
  adds to or removes from a list, the payload field carries an
  [edge directive](../terminology.md#lists): `@appendEdge`,
  `@prependEdge`, `@deleteEdge`, or `@deleteRecord`. The directive names
  the connection through a `connections` variable, which the view fills
  from the connection's `connectionID`. When the payload carries no id of
  the record the write deletes, the mutation carries `@deletes(type:id:)`,
  naming the record by its type and the variable its key is passed as.
  The optimistic response is applied at once, and reverted if the server
  fails.
- **The fields a view cannot do without** carry `@required(action: NONE |
  LOG | THROW)`. The fields whose errors the view shows carry `@catch`
  ([Required, Catch](../terminology.md#documents)). Otherwise nullability
  is what the schema says.
- **The phase decides what the screen shows.** A query's handle has a
  [phase](../terminology.md#generated): loading, ready, or failed, and a
  `retry`. Render each case.
- **The environment is injected once,** at the root of the app. Swift
  uses `.environment(\.baton, environment)`, and Kotlin uses
  `CompositionLocalProvider(LocalBaton provides environment)`.

Where Swift and Kotlin differ:

| | Swift | Kotlin |
|---|---|---|
| The document | A string in the macro, `@Fragment("""...""")` | A `$$"""..."""` raw string, since `$` starts a template in a plain one; a document without a variable may be a plain one |
| Where the marker stands | On the stored property: `@Fragment(...) var issue: IssueRow_issue` | On the composable, which takes the lens as a parameter |
| A query | `@Query(...) var issue: IssueQuery`, whose value the parent passes | `val issue = rememberQuery(IssueQuery(id = id))` in the composable |
| A mutation | `@Mutation(...) var addComment: CommentComposerAddComment.Action` | `val addComment = rememberMutation(CommentComposerAddComment)` |
| Calling it | `try await addComment(input: ..., connections: [id], optimistic: ...)` | `addComment(input = ..., connections = listOf(id), optimistic = ...)` in a coroutine |
| `@catch` | A `Result` | A `Result` |
| The next page | `try await issues.loadNext()` in a `Task` | `issues.loadNext()` in a coroutine |

The two screens in [`examples/GitHubTriage/IssueScreen.swift`](../../examples/GitHubTriage/IssueScreen.swift)
and [`kotlin/samples/github/src/jvmMain/kotlin/baton/github/IssueScreen.kt`](../../kotlin/samples/github/src/jvmMain/kotlin/baton/github/IssueScreen.kt)
are the same screen: a lookup, a connection, and a mutation with
`@appendEdge`, written once per platform.

## What never to write

- **A model layer, or a view model that copies fields.** The lens is the
  model, and the store is the only copy. A struct or data class that
  mirrors a fragment's fields goes stale the moment the store changes,
  and it defeats the per-field re-render. A Kotlin screen with no
  composition at all holds the handle, as [`views.md`](views.md) shows,
  and does not hold a copy.
- **A query file for a screen.** The screen's operation is assembled from
  the fragments spread into it. Write a fragment beside each view, and a
  query that spreads them. Never write a hand-merged query with every
  field. A `.graphql` file is for a host that is not a view, such as a
  UIKit controller ([`uikit.md`](uikit.md)).
- **A cache updater.** There is no function that edits the store after a
  mutation. What a mutation changes is what its payload selects, what it
  adds to or removes from a list is an edge directive, and what it shows
  before the server answers is its optimistic response.
- **A runtime policy object.** Identity is schema configuration in
  `baton.json`, and behaviour is a directive in the document or a value
  on a handle. Nothing is configured by an object at run time.
- **A GraphQL string built at run time,** or a parse of one. Every
  operation is known at build time.
- **A field a view did not declare.** A view reads its own fragment: it
  does not read through a parent's lens into a child's fields, and it
  does not add a field to a parent because a child needs it.

## Diagnostics and what to run

The compiler prints each problem as
`path:line:column: severity: message`. The position is inside the GraphQL
text in the host file, the Swift or Kotlin source that carries the
marker, so the IDE shows it at the line. Read the position, open the
document there, and fix the GraphQL. The message names the field, type,
or argument it could not resolve against the schema. A warning does not
fail the build.

Run, in this order:

1. `batonc validate --config baton.json <files...>`, for the quickest
   answer on every document of a target
   ([`batonc.md`](batonc.md#validate)).
2. The build. The SwiftPM plugin, the Gradle task, or the Bazel rule runs
   the same compilation, so a diagnostic there is the same diagnostic.
3. The app's tests over `RecordedTransport`, or `ScriptedTransport` when
   you need to hold a mutation and observe its optimistic response
   ([Recorded transport](../terminology.md#runtime),
   [`testing.md`](testing.md)). In Swift the product is `BatonTesting`.
   In Kotlin the module is `baton-testing`. Answer the tests with
   responses recorded from the app's server, not with hand-written data.

## Review checklist

- [ ] Each screen has one `@Query`, and every view that reads server data
      reads it through its own `@Fragment` and lens.
- [ ] Each fragment sits beside the view that reads it, and selects only
      the fields that view reads.
- [ ] Each child receives its lens through the parent's spread accessor.
      No view reads a field another view declared.
- [ ] Each list is a `@connection` on a `@refetchable` fragment, and pages
      with `loadNext`; on a schema that pages by number, the list field is
      `@paged` inside the field that takes the page.
- [ ] Each write is an action. A write the user should see at once has a
      typed optimistic response. A write that changes a list names the
      connection with an edge directive.
- [ ] `@required` and `@catch` stand on the fields whose absence or error
      the view handles, and nowhere else.
- [ ] Every phase is rendered: loading, ready, and failed with a retry.
- [ ] No model copies, no screen query written by hand, no cache updater,
      no policy object, no GraphQL built at run time.
- [ ] `batonc validate` and the build are clean, and the tests pass over
      recorded responses.
- [ ] The screens that matter were measured before and after. The numbers
      are in the report back, and what stood in the way is filed as an
      [issue](https://github.com/shergin/baton/issues).
