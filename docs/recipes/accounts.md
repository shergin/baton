# Accounts: a sign-out, a switch, and what the disk keeps

An app with accounts holds data for one of them. That data sits in memory
and in the store's image on disk. After a sign-out, none of it may stay
readable. Not in memory. Not on disk. Not through a response that lands
late.

Baton has no session type, and no switch on the store for this. The
environment is the session. A sign-in makes one. A sign-out ends it.
Which one is current is the app's state
([the decision](../decisions/the-environment-is-the-session.md)). The
image belongs to that one environment. What keeps one account's rows from
the next is the image's identity, the account in its path or in its
`version`, not a purge
([the decision](../decisions/an-image-belongs-to-one-store.md)).

Nothing on this page is a second API. You use `Environment.end()`, the
persistence's path and `version`, `removeAll()`, and `baton.json`'s
`transient` block. The sign-out below is quoted from the two GitHub
samples, which compile in this repository. The rest is what the lifetime
and persistence tests prove, named where they prove it.

## Where the account lives

An image is one SQLite file, made for one store with a path and a
`version`. An image written under another `version` has its rows deleted
in the transaction that opens it, before anything is read. Put the account
in one or the other:

- **In the path**, one file per account. Caches coexist. A switch back to
  an account finds its cache warm. Pick this when users switch accounts
  and expect each to open as they left it.
- **In the `version`**, one file for the app. Opened for another account,
  the file is emptied before any read. Pick this when one account at a
  time is enough, and one file is simpler to protect, inspect, or delete.

```swift
// One file per account.
Persistence(name: "Main-\(account)", version: Types.schemaDigest)
// One file, emptied when another account opens it.
Persistence(name: "Main", version: "\(Types.schemaDigest):\(account)")
```

```kotlin
// One file per account.
Persistence.named("Main-$account", version = Types.schemaDigest)
// One file, emptied when another account opens it.
Persistence.named("Main", version = "${Types.schemaDigest}:$account")
```

On Android the runtime holds no `Context`, so a named image takes its
directory from the app, `Persistence.named(name, directory =
cacheDir.path, version = …)`. `Persistence(url:)` in Swift and
`Persistence(path)` in Kotlin place the file where the app says.

`account` is the identity the app learned at sign-in. It is a user id from
the sign-in response, not the credential. A refreshed token is the same
identity and the same environment. The built-in transports read
credentials per attempt for that reason. The two GitHub samples take one
personal access token and no account, so their images carry the schema's
digest alone. The generated `Types.schemaDigest` already folds the
`transient` lists into that digest.

## The order of a sign-out

The Swift GitHub sample is
[`examples/GitHubTriage/GitHubTriageApp.swift`](../../examples/GitHubTriage/GitHubTriageApp.swift):

```swift
@State private var environment = GitHubTriageApp.makeEnvironment()

private static func makeEnvironment() -> Baton.Environment {
    Baton.Environment(
        transport: Exchange(base: URLSessionTransport(
            url: URL(string: "https://api.github.com/graphql")!,
            credentials: { ["Authorization": "Bearer \(token)"] }
        )),
        store: Store(persistence: Persistence(name: "GitHubTriage", version: Types.schemaDigest))
    )
}

private func signOut() async {
    let ending = environment
    await ending.end()
    ending.store.persistence?.removeAll()
    environment = Self.makeEnvironment()
}
```

The Kotlin one is
[`kotlin/samples/github/src/jvmMain/kotlin/baton/github/Main.kt`](../../kotlin/samples/github/src/jvmMain/kotlin/baton/github/Main.kt).
There the token is a state of the composition, and `onSignedOut` clears it:

```kotlin
val environment = remember(token) {
    Environment(
        Exchange(HttpTransport("https://api.github.com/graphql", credentials = { mapOf("Authorization" to "Bearer $token") })),
        store = Store(persistence = Persistence.named("GitHubTriage", version = Types.schemaDigest)),
    )
}
onSignOut = {
    scope.launch {
        environment.end()
        environment.store.persistence?.removeAll()
        onSignedOut()
    }
}
```

Three steps, in this order. A crash after any of them leaves the account
signed in, and nothing readable by another:

1. **End the environment.** `end()` cancels every fetch and stream the
   environment started. It drops the roots, clears every record, forgets
   the session's keys, and closes the image, giving its file back. In
   Kotlin it is a `suspend` function. A crash here leaves the file intact
   under the account's own identity. The next launch, still signed in,
   reads its own cache.
2. **Remove the image.** `removeAll()` deletes the file, the interned
   names and argument values with it, and drops the work queued before it.
   The log goes before the database, so an interrupted removal leaves a
   consistent older image rather than a log to replay into the next file.
   A marker beside the file has the next open finish a deletion a crash
   interrupted, or one a locked device put off
   ([the decision](../decisions/the-images-file-is-protected-and-waited-for.md)).
   The removal is hygiene. It can be interrupted and repeated. The
   identity is what keeps another account out.
3. **Forget the credential last.** A crash before this step leaves the
   account signed in, with or without its cache. That is the state the
   next launch can finish from.

Signing out and signing in again is a new environment. The Swift sample's
`makeEnvironment()` makes one, and so does the Kotlin sample's
`remember(token)`. A store is never cleared or replaced in place.

## What is still held after the end

| What the app still holds | What it sees |
|---|---|
| A view under `@Query`, `@Subscription` or `rememberQuery` | Resolves its operation again in the next environment the app injects, with no help from the app. |
| A handle a model holds | Reads `.failed(EnvironmentError.gone)` in Swift, `Phase.Failed(EnvironmentError.Gone)` in Kotlin, and tells its observers, so the model resolves again in the current environment. |
| A lens a model holds | Finds its records cleared. |
| A fetch in flight | Cancelled. A response that lands anyway reaches neither memory nor the image. |
| A mutation in flight | Never cancelled, since the server applies it anyway; its response reaches neither memory nor the image. |
| A subscription | Its stream ends on `gone`. |
| Any later call on the environment | Fails on `gone`: a fetch, a mutation, a payload committed by hand, a handle made after the end. |

An ended store commits nothing. The check sits at the one door a payload
takes, which is what covers a response cancellation cannot reach. The
rule is the contract's "A session ends once"
([`spec/runtime.md`](../../spec/runtime.md#7-the-lifetime-roots-retention-ages-collection)),
held by the script `end`, which both runtimes run.

## A switch without a sign-out

To switch accounts and keep the first one's cache, end the environment
and keep the file. With the account in the path, the next environment
opens the other account's file, and the first stays warm. With the
account in the `version`, the next environment empties the one file, and
the first account refetches when it returns. Either way, the second
account never reads the first account's rows. An image opened under
another `version` is emptied before any read. Another path is another
file.

## The walkthrough: A signs out, B signs in, relaunch offline

Check this case before you ship. Step by step, with the account in the
`version` and the sign-out above:

1. **A opens a private screen.** The response is committed to memory and
   written behind the commit to the image, under A's identity.
2. **A signs out.** `end()`, then `removeAll()`, then forget the
   credential. If A's response was still in flight, it lands after the
   end and reaches neither memory nor the image. If the removal was
   interrupted, the next open finishes it.
3. **B signs in.** A new environment, with its own image on the same path.
   The file is gone. Or, had the removal been skipped, B's open empties
   it before any read. B opens the same screen. The check misses, and the
   screen fetches from the network.
4. **Relaunch offline as B.** B's image holds B's rows and B's fetch
   time, so the screen renders from disk and is not stale.
5. **A signs in again.** A's environment finds nothing of A's earlier
   session, because the file was removed. With the account in the path,
   and the switch above instead of the sign-out, A's cache is still warm.

The Swift persistence tests prove each step. "each step of a sign-out
leaves nothing another account can read: after the end, another account
reads nothing and the same account still reads its data; after
removeAll, neither does", "a response the user who signed out was
waiting for lands after the end and the removal, and reaches neither the
image nor the next user, whose own image took the same file", "an
environment that ended before removeAll reads nothing from the next
user's image, and its invalidation leaves the next user's data fresh",
"after the end, removeAll deletes the file, and a new image on the same
path in a new environment starts empty, reads nothing and writes its own
rows for the next launch", and "a mutation in flight at the end that the
server answers reaches neither memory nor the image". The lifetime tests
hold the table above: "a view whose environment is replaced resolves its
operation again in the new one", "a handle a model holds reads gone after
the end and tells its observer, and a subscription it holds ends on gone",
and "every call after the end fails on gone". The Kotlin runtime runs the
`end` script and proves `removeAll` deletes an image and the work queued
before it. The two-account walkthrough is not yet a Kotlin test.

## Keeping data off the disk

A purge is weaker than never writing. Three controls. Each is decided
when the image is made, or at build time. None is a switch at run time:

- **`transient` types and root fields.** `baton.json`'s `transient` block
  names types whose records never reach the image, an interface standing
  for its implementers, and root fields such as `Query.search`. Those
  fields' cells, storage keys, and fetch stamps are never written, since
  a root field's key carries its arguments and an operation's stamp
  carries its variables. Memory is unaffected. The next launch misses on
  what was left out and fetches it. The lists join the image's `version`,
  so a changed list is an image started again
  ([the decision](../decisions/what-may-reach-the-image.md); the fixtures
  `spec/tests/secrets.json` and `character-secret.json`).

  ```json
  "transient": {
    "types": ["Secret"],
    "fields": ["Query.secrets"]
  }
  ```

- **The platform's protection class.** `Persistence(name:version:protection:)`
  takes a `FileProtectionType`. Apple's SQLite makes the file and its
  write-ahead log under it. Under `.complete` the file cannot be opened
  while the device is locked. The writer keeps its work for the next try,
  and a read meanwhile misses, rather than the image being discarded. An
  image made under another class starts again. Kotlin has no protection
  class.
- **No image.** `Store()` with no persistence keeps everything in memory,
  and the end clears it.

To wipe everything an account has, for a security setting or a remote
sign-out, do what the sign-out does. End the environment, remove the
image, and make a new environment for whoever is signed in next.
