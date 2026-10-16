# The twelve words

Baton's vocabulary is twelve words, and it is closed. A feature is those words put together, or a Relay directive the compiler understands, or it does not ship. That rule keeps a screen to one request, a view to one fragment, and a change to one re-render. It is also why the whole thing fits on a page. Each word below has its contract in [the terminology](../../terminology/), where the Swift and Kotlin spellings are, and one plate here so you can see it.

## Schema

The schema is the server's menu: every type, every field, and whether each can be null. It is a checked-in SDL file the compiler reads at build time, named in `baton.json`, with identity configured beside it. The runtime never introspects. What it knows of the schema, it knows from the compiler. One schema family per process. [In the terminology.](../../terminology/#term-schema)

{{source spec/rickandmorty/schema.graphql lines=7-32 | The root type and one object type of the Rick and Morty schema. `episode: [Episode]!` is a non-null list of episodes that may be null. The lens types follow that exactly.}}

## Document

A document is a query, a mutation, a subscription, or a fragment. A marker in your source carries it, or a `.graphql` file holds it. A fragment is a view's needs, with a name. An operation is what the compiler assembles from the fragments spread into it, one per screen. It compiles to a variables type, a root lens, a plan, its text, and a persisted id. [In the terminology.](../../terminology/#term-document)

{{host issues | A fragment and a query, each in the marker that carries it. The Kotlin marker stands on the composable. The Swift marker stands on the stored property.}}

## Directive

A directive is the only way behaviour attaches to data. The set is Relay's: `@connection`, `@refetchable`, `@argumentDefinitions`, `@arguments`, `@alias`, `@required`, `@catch`, `@throwOnFieldError`, `@defer`, `@stream`, `@stream_connection`, `@inline`, `@include`, `@skip`, and the edge directives `@appendEdge`, `@prependEdge`, `@appendNode`, `@prependNode`, `@deleteEdge` and `@deleteRecord`. The one exception, which Relay has no word for, is `@cacheExpiration(seconds:)`. Nothing is configured by an object at run time. [In the terminology.](../../terminology/#term-directive)

{{host comments | Four directives in one figure. A refetchable connection with its argument definitions, and a mutation whose payload edge is appended to that connection.}}

## Lens

A lens is Baton's word for what Relay calls a fragment reference and fragment data. Here they are one value. A lens is a typed, read-only window onto one record. You get one accessor per field you asked for, and no accessor for anything else. A parent passes a child its lens through a spread's accessor, and cannot read through it. A lens is valid on the main thread, where the store lives. It is equal by its record, its owner, and its origin. [In the terminology.](../../terminology/#term-lens)

{{lens issue-list IssueList_repository | A lens over a connection. `issues` reads a nested lens whose `edges` are a list. Each edge's `node` is a lens that spreads the row's fragment. `cursor` and `pageInfo` are there because the compiler added them for the connection. Nothing else appears.}}

## Record

A record is an observable object identified by typename plus key, `Character:9`. It holds interned slots and per-field errors. Each slot is an invalidation channel. A body that read it is invalidated when it changes, and at no other time. An object without a key gets a client id from its path, as in Relay. [In the terminology.](../../terminology/#term-record)

{{records spec/rickandmorty/character-header-9.store.json | The three records one response made. A link is a slot holding another record's key.}}

## Store

The store is every record, the retained roots, and the lifetime state. The main thread owns it. Reads are synchronous. Writes are atomic commits. A commit is a batch: the transaction that nets the notifications, an undo log, and a kind, server, optimistic, or local. Only a server batch reaches the image on disk. [In the terminology.](../../terminology/#term-store)

{{script notifications steps=2,3 | Two commits. One changes nothing and notifies nothing. One changes a name and notifies the one slot.}}

## Plan

A plan is how a response becomes records. It is the normalization artifact the compiler emits per operation, as data the runtime walks. The ingest follows the plan through the bytes. It keys each object by the type's key fields, and it writes slots by their numbers. It knows no field by name. Both runtimes interpret the same plans. [In the terminology.](../../terminology/#term-plan)

{{generated issues IssuesScreen | The plan is the data table in an operation's generated code, before its data lens. One selection per distinct selection set. Each field has its storage key and its kind.}}

## Operation value

An operation value is an operation's variables, compared and hashed by them. A parent constructs it, `IssuesQuery(owner:name:)`, and a navigation path carries it. Inside a view it resolves to a handle, which exposes the phase, the data, a refetch, and a retry. Outside any view it reads as loading. [In the terminology.](../../terminology/#term-operation-value)

{{operation issues IssuesQuery | What one operation value stands for on the wire. The text, its two variables, and the id it is registered under.}}

## Connection

A connection is a list that pages. It is Relay's connection specification, on a fragment marked `@refetchable`, under `@connection(key:)`. The store merges each page into one list under the key. The lens reads `nodes`, `hasNext`, and `isLoadingNext`. You page with `loadNext`, and `connectionID` names the list for an edge directive. [In the terminology.](../../terminology/#term-connection)

{{script connections steps=2 | The second page committed. The connection record under the key now links both pages' edges, and the lens reads four notes in order.}}

## Environment

The environment is the session: one store, one transport, and the door everything from outside comes through. It fetches, commits, applies optimistic layers, hydrates from the image, logs, and ends. Signing out is ending it and making another. You inject it once at the root of the app. [In the terminology.](../../terminology/#term-environment)

{{script end steps=4 | The environment ends. Every handle reads as gone, the records are cleared, and nothing is logged.}}

## Transport

A transport is a protocol with one verb, `send`. It takes a request and yields a stream of payloads: one for a query, several for an incremental response, many for a subscription. The built-in transports are the platform's HTTP and sockets. A retry, a challenge, or a deadline is a transport that wraps a transport, and the app owns that wrapper. [In the terminology.](../../terminology/#term-transport)

{{script transport steps=1 | What the transport is handed. The standard encoding of one request, the operation's text and its variables, compared byte for byte.}}

## Phase

The phase is the state of a resolved operation, named after `AsyncImagePhase`: loading, ready, or failed. You can always read it synchronously. `isRefreshing` and `isStale` sit beside it. Previous data stays visible while a refresh runs. A fetch that changed nothing wakes no body. It is derived from the root's verdict and the fetch, and it is stored nowhere. [In the terminology.](../../terminology/#term-phase)

{{script phase steps=1,2,12,13,14 | A handle loading, then ready. A handle whose fetch fails reads as failed. A retry reads as loading. A malformed answer fails it again.}}

## What is not a word

A view model, a cache policy, a type policy, a merge function, a query file for a screen, a cache updater, a resolver, a runtime GraphQL parser. Some screen asked for each of these. Each is answered by the twelve words above, put together, or refused with a reason in [the decisions](../../decisions/). [What earns a concept](../../principles/what-earns-a-concept/) is the test a thirteenth word would have to pass.
