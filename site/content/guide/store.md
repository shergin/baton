# The store

The store is the UI's state. Every response becomes records keyed by type and id; records are observable objects; a view body that read a field is invalidated when that field of that record changes, and at no other time. This chapter follows a record from the bytes to the body, then to the disk and the next launch.

## Records and keys

A record is `Type:id` by default. `baton.json` configures identity for types keyed otherwise, by one field, by several, or for an interface whose implementers share a key; the compiler selects the key fields wherever the type is read, so a response always carries what the ingest needs. An object without a key gets a client id from its path, `client:root:characters(page:1)`, as in Relay.

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

A field is stored under its name, or under its name and its arguments when it has any: `notes(first:2)` and `notes(after:"c2",first:2)` are two slots of one record, and an argument whose value is null is left out, so the same page is the same slot whether or not the document mentioned `after`. The compiler computes every storage key without a variable in it and emits a constant, which the process numbers on first use; a key with variables is rendered once per owner and numbered by the store; a read hashes nothing.

{{normalize spec/rickandmorty/character-header-9 | A response and its records, linked both ways. The root record holds the query's root fields under their storage keys; a nested object with an id became a record of its own.}}

## The commit

A response's bytes are decoded straight into record slots, off the main actor, by the plan the compiler emitted, with no model tree in between: that is the ingest. What it produces is a change set, and the commit applies it on the main actor as one batch: a write of each slot that changed, nothing for a slot whose value is equal, and a notification for each observed field that changed, once, when the batch ends. A view never sees half a response.

{{script notifications steps=1,2,3,5,6 | What each commit notifies. The same response again notifies nothing; a rename notifies one slot; a response that carries errors for three fields notifies those three; a response that answers them notifies the three again.}}

Three kinds of batch: a server batch, which is written to the image; an optimistic one, which keeps its undo log with its layer and is never written to the image; a local one, the runtime's own writes, a page's loading flag or a lookup's link bound, which never reaches the image.

## What a view observes

Each record carries the UI framework's registrar, Observation's in Swift and a snapshot-state channel per slot in Kotlin, and each lens accessor registers the read of one field of one record. So the framework knows exactly which bodies depend on which slots, and the commit tells it which slots changed. There are no subscriptions of Baton's own, no snapshots to diff, and no watcher that re-executes a query.

{{stage characters CharactersQuery spec/rickandmorty/characters-page-1.store.json rows=4 | Four rows over real records. Change a row's field and that row's body runs; change the list and the screen's body runs; answer with the same data and nothing runs.}}

A commit is ordinary main-actor state mutation, so a data-driven change animates like any other state change in the framework, with nothing of Baton's in the way.

## Roots, retention, collection

A record lives while a root reaches it. A root is an operation's selection and the record it starts from; a view holds a retention on its handle for its life, and when the last retention ends the root waits in a release buffer, ten by default, before its records become collectable, so going back to a screen just left is free. The store collects once per turn of the main thread after a root left or a commit dropped a link, marking from the roots, the optimistic layers and the image's write queue.

{{script lifetime steps=3,4,5,9 | The specification's lifetime script, with a release buffer of one. Three handles hold five records; releasing one changes nothing while the buffer holds its root; releasing a second pushes the first out and its character goes; releasing the last pushes the second out, and the last's own records stay while its root waits in the buffer, one of them held by a mutation's payload as well.}}

The consequence for a scrolling list: memory plateaus, since the store releases what no view holds, and a page scrolled far out of view is a page that can go.

## Ages and staleness

The store stamps each root with the time of its last commit. A query's `@cacheExpiration(seconds:)`, or the store's default, says how old its data may be before it reads as stale; `environment.invalidate()` marks everything stale and refetches what is retained; `environment.revalidate()` refetches what is stale or failed, for a return to the foreground or a connection regained. Stale data stays readable, and the age survives a launch, because the image keeps it.

{{script ages steps=10,11,13,14,15,16 | An invalidation marks both handles stale and refetches them; after a relaunch a handle attached over the image reads ready and, when the clock passes the store's default expiration of a minute, stale.}}

## The image

Every server batch is written behind to an image, one SQLite file, off the main actor: a row per record, a row per root field, each operation's fetch time. When a handle is made, the availability check reads from the image whatever memory lacks, so an operation an earlier launch fetched is ready before the first body, and the screen the user left is the screen they get back.

```swift tab
Store(persistence: Persistence(name: "App", version: Types.schemaDigest))
```

```kotlin tab
Store(persistence = Persistence.named("App", version = Types.schemaDigest, directory = cacheDir.path))
```

{{script check steps=1,2,3,4,5,7 | A commit, a check answered from memory, a check for data nobody fetched, a relaunch, the first check answered from the image, and the miss still a miss.}}

The image is a cache and nothing more. One written under another schema digest, another format or another identity configuration starts again rather than migrating; a record that goes a whole launch unread is dropped at the next; an image over its size limit evicts the rows of older launches first; optimistic layers never reach it. Types and root fields that must never touch the disk are named in `baton.json` under `transient`, and the lists join the schema's digest.

## Client fields

A field the server does not have, a pin or a draft, is described in a client schema extension named in `baton.json` and written by a payload committed by hand, `environment.commitPayload(operation, payload)`, for an operation that selects it. It reads through a lens like any field, is left out of the text a server receives, and reaches the image like any record. There are no resolvers; a client field is data, described and committed.

```graphql
extend type Character {
  """Whether the app pinned the character; the device's alone."""
  isPinned: Boolean
}
```

## Looking inside

`StoreExport.text(of: environment.store)`, from `BatonInspector`, writes the store in the dump format every plate on this site uses: every record by key, sorted, one a line. A dump from a debug menu is a fixture a test can start from, and a diff of two dumps is a reviewable change to identity or layout. In Kotlin the same text is `StoreExport.text(environment.store)`, from `baton-inspector`. Beside the export, `StoreInspector` is a live view of a store for a debug pane, a SwiftUI view in `BatonInspector` and a Compose one in `baton-inspector`.
