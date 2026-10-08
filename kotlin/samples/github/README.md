# GitHub triage, on the desktop

GitHub's GraphQL API (`https://api.github.com/graphql`) through the Kotlin
runtime, in Compose for Desktop; the Kotlin counterpart of
`examples/GitHubTriage`. Where the desktop sample only reads, this one
writes: mutations with optimistic responses, a connection a mutation's
edge is appended to, and a sign-out that throws the store away.

## Running it

Build the compiler first (`cargo build --release` in `compiler/`), then,
from `kotlin/`:

```bash
GITHUB_TOKEN=$(gh auth token) JAVA_HOME=$(/usr/libexec/java_home -v 21) gradle :samples:github:run
```

The token is a personal access token with the `repo` scope (or a
fine-grained one that may read the repository, star it and comment on its
issues). The sign-in screen's field is prefilled from `GITHUB_TOKEN` when
it is set, and empty otherwise. The token lives in the composition's state
and in the `Authorization: Bearer` header the HTTP transport sends to
`api.github.com`, and nowhere else: nothing writes it to disk, and the
store's image holds records, not credentials.

`gradle :samples:github:build` runs the tests, which need no token and no
network.

## The screens

- **Sign-in**: the token field. Signing in makes the environment in the
  composition, on the desktop's event thread the store belongs to:
  `Environment("https://api.github.com/graphql", headers = …, store =
  Store(persistence = Persistence.named("GitHubTriage", version =
  Types.schemaDigest)))`. The image lives in the user's cache directory
  under the schema's digest, so a relaunch renders before the network
  answers.
- **Repository** (left): owner and name fields, `octocat/Hello-World` to
  start. The repository's name, description and forks, with `@catch`
  turning a missing repository's field error into the server's reason. The
  star button reads `viewerHasStarred` and `stargazerCount` and calls
  `addStar` or `removeStar` with an optimistic response that flips the star
  and the count before the server answers; the server's answer replaces
  it, and a failure reverts it.
- **Issues**: the open issues as a `@connection` on a `@refetchable`
  fragment. The list's last item, a spinner, is composed only when the list
  is scrolled to its end, and calls `loadNext()` then; `hasNext` decides
  whether it is there at all.
- **Issue** (right): the issue selected, looked up with `node(id:)`, which
  finds the fields the list fetched in the store. Its title, author and
  body, and its comments as a `@connection`, with a button for more. The
  composer calls `addComment` with `@appendEdge(connections: $connections)`,
  passing the comments connection's `connectionID`, and an optimistic
  comment by the viewer, whose id and login a small `ViewerQuery`
  provides: the comment appears at the end of the list at once and the
  server's edge replaces it when it lands.
- **Sign-out**: `environment.end()`, which cancels what the environment
  started and closes the image, then `persistence.removeAll()`, which
  deletes the image's file, then back to sign-in, forgetting the token.

## How it is built

- `baton.json` names the schema of the Swift sample,
  `../../../examples/GitHubTriage/schema.docs.graphql`, the `Query.node`
  lookup by `id`, and the package `baton.github`.
- The hosts are the `.kt` files: `@Fragment` on the composable that renders
  a lens, `@Query` on the one that resolves an operation with
  `rememberQuery`, `@Mutation` on the composable or function that holds the
  action; documents with a variable in `$$"""…"""` strings. The documents
  are the Swift sample's, but for the triage searches, which this sample
  leaves out, and the viewer query, which it adds.
- The `generateBaton` task runs `batonc generate --language kotlin` over
  the hosts into `build/generated/baton`, as the desktop sample's does.
- `PhaseView.kt` is copied from the desktop sample; a module the samples
  share is a later step.
- `src/jvmTest` holds `ScreenTests`, which run the screens in a
  composition over `baton-testing`'s `ScriptedTransport`, answered with the
  small responses under `src/jvmTest/resources/responses/`: the recorded
  repository shown; the star flipped with its count while the mutation is
  held, and kept when the server answers in kind; the second page asked
  for and appended when the list is scrolled to its end; a posted comment
  at the end of the comments at once, still there, once, when the server's
  answer lands.

## Where the runtime is short

Two things the sample works around, for the runtime to answer:

- `rememberMutation(type)` takes the generated companion as an
  `OperationType`, an interface behind the `baton.Generated` opt-in, so an
  app cannot call it without opting in; and it cannot infer the operation's
  class from the companion, so the action's type is written out. The
  sample opts in at each call, on the local variable, and names the type:
  `@OptIn(Generated::class) val addStar: MutationAction<StarButtonAddStar,
  StarButtonAddStar.Data> = rememberMutation(StarButtonAddStar)`.
- The `@Mutation` marker is not repeatable, so a composable cannot host
  two mutations; the star's two mutations sit on the two small functions
  that call them.

The tests do not reach the live API, and the sample has not yet been run
against it with a token: the documents compile against GitHub's published
schema, and the responses the tests answer with are written to match them.
