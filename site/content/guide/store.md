# The store

The store is the UI's state. Every response becomes records keyed by type and id. Records are observable objects. A view body that read a field is invalidated when that field of that record changes, and at no other time. This chapter follows a record from the bytes to the body, then to the disk, and then to the next launch.

## Records and keys

A record is `Type:id` by default. `baton.json` configures identity for types keyed otherwise, by one field, by several, or for an interface whose implementers share a key. The compiler selects the key fields wherever the type is read, so a response always carries what the ingest needs. An object without a key gets a client id from its path, `client:root:characters(page:1)`, as in Relay.

```json
{
  "schema": "schema.graphql",
  "identity": {
    "types": {
      "Asset": ["uuid"],
      "Quote": ["base", "quote"]
    }
  }
}
```

A field is stored under its name, or under its name and its arguments when it has any. `notes(first:2)` and `notes(after:"c2",first:2)` are two slots of one record. An argument whose value is null is left out, so the same page is the same slot whether or not the document mentioned `after`. The compiler computes every storage key that has no variable in it and emits a constant, which the process numbers on first use. A key with variables is rendered once per owner and numbered by the store. A read hashes nothing.

{{normalize spec/rickandmorty/character-header-9 | A response and its records, linked both ways. The root record holds the query's root fields under their storage keys. A nested object with an id became a record of its own.}}

## The commit

A response's bytes are decoded straight into record slots, off the main actor, by the plan the compiler emitted. There is no model tree in between. That is the ingest. What it produces is a change set, and the commit applies it on the main actor as one batch. Each slot that changed is written. A slot whose value is equal is left alone. Each observed field that changed is notified once, when the batch ends. A view never sees half a response.

{{script notifications steps=1,2,3,5,6 | What each commit notifies. The same response again notifies nothing. A rename notifies one slot. A response that carries errors for three fields notifies those three. A response that answers them notifies the three again.}}

There are three kinds of batch. A server batch is written to the image. An optimistic batch keeps its undo log with its layer, and it is never written to the image. A local batch is the runtime's own writes, a page's loading flag or a lookup's link bound, and it never reaches the image.

## What a view observes

Each record carries the UI framework's registrar: Observation's in Swift, and a snapshot-state channel per slot in Kotlin. Each lens accessor registers the read of one field of one record. The framework then knows which bodies depend on which slots, and the commit tells it which slots changed. There are no subscriptions of Baton's own, no snapshots to diff, and no watcher that re-executes a query.

{{stage characters CharactersQuery spec/rickandmorty/characters-page-1.store.json rows=4 | Four rows over real records. Change a row's field and that row's body runs. Change the list and the screen's body runs. Answer with the same data and nothing runs.}}

A commit is ordinary main-actor state mutation, so a data-driven change animates like any other state change in the framework. Nothing of Baton's sits in the way.

## Roots, retention, collection

A record lives while a root reaches it. A root is an operation's selection and the record it starts from. A view holds a retention on its handle for its life. When the last retention ends, the root waits in a release buffer, ten by default, before its records become collectable. Going back to a screen you just left is free. The store collects once per turn of the main thread, after a root left or a commit dropped a link. It marks from the roots, the optimistic layers, and the image's write queue.

{{script lifetime steps=3,4,5,9 | The specification's lifetime script, with a release buffer of one. Three handles hold five records. Releasing one changes nothing while the buffer holds its root. Releasing a second pushes the first out, and its character goes. Releasing the last pushes the second out. The last handle's own records stay while its root waits in the buffer, one of them held by a mutation's payload as well.}}

The consequence for a scrolling list is that memory plateaus. The store releases what no view holds, and a page scrolled far out of view is a page that can go.

## Ages and staleness

The store stamps each root with the time of its last commit. A query's `@cacheExpiration(seconds:)`, or the store's default, says how old its data may be before it reads as stale. `environment.invalidate()` marks everything stale and refetches what is retained. `environment.revalidate()` refetches what is stale or failed, for a return to the foreground or a connection regained. Stale data stays readable. The age survives a launch, because the image keeps it.

{{script ages steps=10,11,13,14,15,16 | An invalidation marks both handles stale and refetches them. After a relaunch, a handle attached over the image reads ready. When the clock passes the store's default expiration of a minute, it reads stale.}}

## The image

Every server batch is written behind to an image, one SQLite file, off the main actor. It holds a row per record, a row per root field, and each operation's fetch time. When a handle is made, the availability check reads from the image whatever memory lacks. An operation an earlier launch fetched is ready before the first body. The screen you left is the screen you get back.

```swift tab
Store(persistence: Persistence(name: "App", version: Types.schemaDigest))
```

```kotlin tab
Store(persistence = Persistence.named("App", version = Types.schemaDigest, directory = cacheDir.path))
```

{{script check steps=1,2,3,4,5,7 | A commit, a check answered from memory, a check for data nobody fetched, a relaunch, the first check answered from the image, and the miss still a miss.}}

The image is a cache, and nothing more. One written under another schema digest, another format, or another identity configuration starts again rather than migrating. A record that goes a whole launch unread is dropped at the next. An image over its size limit evicts the rows of older launches first. Optimistic layers never reach it. Types and root fields that must never touch the disk are named in `baton.json` under `transient`, and those lists join the schema's digest.

## Client fields

A field the server does not have, a pin or a draft, is described in a client schema extension named in `baton.json`. You write it by committing a payload by hand, `environment.commitPayload(operation, payload)`, for an operation that selects it. It reads through a lens like any field. It is left out of the text a server receives. It reaches the image like any record. There are no resolvers. A client field is data, described and committed.

```graphql
extend type Character {
  """Whether the app pinned the character; the device's alone."""
  isPinned: Boolean
}
```

## Looking inside

`StoreExport.text(of: environment.store)`, from `BatonInspector`, writes the store in the dump format every plate on this site uses. Every record by key, sorted, one a line. A dump from a debug menu is a fixture a test can start from, and a diff of two dumps is a reviewable change to identity or layout. In Kotlin the same text is `StoreExport.text(environment.store)`, from `baton-inspector`. Beside the export, `StoreInspector` is a live view of a store for a debug pane: a SwiftUI view in `BatonInspector`, and a Compose one in `baton-inspector`.
