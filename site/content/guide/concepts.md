# The twelve words

Baton's vocabulary is closed. A feature is a composition of these twelve concepts, or a Relay directive the compiler understands, or it does not ship. That is the rule that keeps a screen one request, a view one fragment, and a change one re-render, and it is why the whole thing fits on a page. Each word below has its contract in [the terminology](../../terminology/), where the Swift and Kotlin spellings are, and one plate here to make it concrete.

## Schema

The server's menu: every type, every field, whether each can be null. A checked-in SDL file the compiler reads at build time, named in `baton.json`, with identity configured beside it. The runtime never introspects; what it knows of the schema it knows from the compiler. One schema family per process. [In the terminology.](../../terminology/#term-schema)

{{source spec/rickandmorty/schema.graphql lines=7-32 | The root type and one object type of the Rick and Morty schema. `episode: [Episode]!` is a non-null list of nullable episodes, and the lens types follow that exactly.}}

## Document

A query, a mutation, a subscription or a fragment, carried by a marker in source code or held in a `.graphql` file. A fragment is a view's needs with a name; an operation is assembled by the compiler from the fragments spread into it, one per screen, and compiles to a variables type, a root lens, a plan, its text and a persisted id. [In the terminology.](../../terminology/#term-document)

{{host issues | A fragment and a query, each in the marker that carries it. The Kotlin marker stands on the composable; the Swift marker on the stored property.}}

## Directive

The only way behaviour attaches to data. The set is Relay's: `@connection`, `@refetchable`, `@argumentDefinitions`, `@arguments`, `@alias`, `@required`, `@catch`, `@throwOnFieldError`, `@defer`, `@inline`, `@include`, `@skip`, and the edge directives `@appendEdge`, `@prependEdge`, `@appendNode`, `@prependNode`, `@deleteEdge` and `@deleteRecord`; the one exception, which Relay has no word for, is `@cacheExpiration(seconds:)`. Nothing is configured by an object at run time. [In the terminology.](../../terminology/#term-directive)

{{host comments | Four directives in one figure: a refetchable connection with its argument definitions, and a mutation whose payload edge is appended to that connection.}}

## Lens

Baton's word for what Relay calls a fragment reference and fragment data, which are one value here: a typed, read-only view over one record, with one accessor per declared field. A parent passes a child its lens through a spread's accessor and cannot read through it. A lens is valid on the main thread, where the store lives; equal by its record, its owner and its origin. [In the terminology.](../../terminology/#term-lens)

{{lens issue-list IssueList_repository | A lens over a connection: `issues` reads a nested lens whose `edges` are a list, each edge's `node` a lens that spreads the row's fragment, and `cursor` and `pageInfo`, which the compiler added for the connection. Nothing else appears.}}

## Record

An observable object identified by typename plus key, `Character:9`, holding interned slots and per-field errors. Each slot is an invalidation channel: a body that read it is invalidated when it changes, and at no other time. Objects without a key get a client id from their path, as in Relay. [In the terminology.](../../terminology/#term-record)

{{records spec/rickandmorty/character-header-9.store.json | The three records one response made. A link is a slot holding another record's key.}}

## Store

All records, retained roots and lifetime state, owned by the main thread, read synchronously, written by atomic commits. A commit is a batch: the transaction that nets the notifications, an undo log, and a kind, server, optimistic or local. Only a server batch reaches the image on disk. [In the terminology.](../../terminology/#term-store)

{{script notifications steps=2,3 | Two commits: one that changes nothing and notifies nothing, one that changes a name and notifies the one slot.}}

## Plan

How a response becomes records: the normalization artifact the compiler emits per operation, as data the runtime walks. The ingest follows the plan through the bytes, keys each object by the type's key fields, and writes slots by their numbers; it knows no field by name. Both runtimes interpret the same plans. [In the terminology.](../../terminology/#term-plan)

{{generated issues IssuesScreen | The plan is the data table in an operation's generated code, before its data lens: one selection per distinct selection set, each field with its storage key and kind.}}

## Operation value

A value of an operation's variables, compared and hashed by them: the thing a parent constructs, `IssuesQuery(owner:name:)`, and a navigation path carries. Inside a view it resolves to a handle, which exposes the phase, the data, a refetch and a retry; outside any view it reads as loading. [In the terminology.](../../terminology/#term-operation-value)

{{operation issues IssuesQuery | What one operation value stands for on the wire: the text, its two variables, and the id it is registered under.}}

## Connection

A list that pages: Relay's connection specification, on a fragment marked `@refetchable`, under `@connection(key:)`. The store merges each page into one list under the key; the lens reads `nodes`, `hasNext` and `isLoadingNext`, pages with `loadNext`, and names the list with `connectionID` for an edge directive. [In the terminology.](../../terminology/#term-connection)

{{script connections steps=2 | The second page committed: the connection record under the key now links both pages' edges, and the lens reads four notes in order.}}

## Environment

The session: one store, one transport, and the door everything from outside comes through. It fetches, commits, applies optimistic layers, hydrates from the image, logs, and ends. Signing out is ending it and making another. Injected once at the root of the app. [In the terminology.](../../terminology/#term-environment)

{{script end steps=4 | The environment ends: every handle reads as gone, the records are cleared, and nothing is logged.}}

## Transport

A protocol with one verb, `send`, which takes a request and yields a stream of payloads: one for a query, several for a deferred response, many for a subscription. The built-in transports are the platform's HTTP and sockets; everything a production endpoint needs beyond that, a retry, a challenge, a deadline, is a transport that wraps a transport, which the app owns. [In the terminology.](../../terminology/#term-transport)

{{script transport steps=1 | What the transport is handed: the standard encoding of one request, the operation's text and its variables, compared byte for byte.}}

## Phase

The state of a resolved operation, named after `AsyncImagePhase`: loading, ready, or failed, always synchronously readable, with `isRefreshing` and `isStale` beside it. Previous data stays visible while a refresh runs; a fetch that changed nothing wakes no body. Derived from the root's verdict and the fetch, stored nowhere. [In the terminology.](../../terminology/#term-phase)

{{script phase steps=1,2,12,13,14 | A handle loading, then ready; a handle whose fetch fails reads as failed; a retry reads as loading; a malformed answer fails it again.}}

## What is not a word

A view model, a cache policy, a type policy, a merge function, a query file for a screen, a cache updater, a resolver, a runtime GraphQL parser. Each was asked for by some screen somewhere, and each is answered by a composition of the twelve above or refused with a reason in [the decisions](../../decisions/). [What earns a concept](../../principles/what-earns-a-concept/) is the test a thirteenth word would have to pass.
