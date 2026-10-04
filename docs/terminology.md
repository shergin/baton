# Terminology

The vocabulary contract: every public concept is named here before it is
named in code, and when a concept is added, renamed or changes meaning, this
file is updated in the same change. Each entry gives the meaning in the
literature, why this word, and what it maps to here. Entries marked
*(planned)* do not exist in code yet. Each entry is also marked with its
place in the closed inventory of
[What earns a concept](principles/what-earns-a-concept.md): schema,
document, directive, lens, record, store, plan, operation value, connection,
environment, transport, phase. *Concept* names the one the entry is, or is a
form of, as a fragment is a document; *Composition* names the ones it is
made of, as an owner is made of a lens and an operation value.

Design arguments live in [vision](vision.md) and [principles](principles/).
Where Relay or the GraphQL specification has a word, it is used
([Relay's words](principles/relays-words.md)).

## Documents

**Document.** *Concept: document.* GraphQL: the text a request or a file
holds, a list of definitions; an executable document defines operations and
fragments. Here: an executable document, carried by a marker macro
(`@Query("…")`, `@Fragment("…")`, `@Mutation("…")`, `@Subscription("…")`) in
Swift source or held in a `.graphql` file. The compiler reads every document
of a module beside the schema, which GraphQL also writes as a document and
which is a concept of its own here.

**Fragment.** *Concept: document.* GraphQL: a named selection on a type.
Relay: the unit of a component's data needs. Here: declared beside the view
that reads it, in Swift source or a `.graphql` file; compiles to a
[lens](#generated) type.

**Operation.** *Concept: document.* GraphQL: a query, mutation or
subscription. Here: assembled by the compiler from the fragments spread into
it; one per screen; compiles to a variables type, a root lens, a
[plan](#compiler) and a persisted id. The three kinds are three protocols
refining `Operation`, in GraphQL's words: `Query`, read through a handle;
`Mutation`, called as an [action](#generated); `Subscription`, a stream of
events into the store. Each API takes only its kind.

**Spread.** *Composition: document, lens.* GraphQL: `...Name` inside a
selection. Here: compiles to a named accessor on the parent lens that
returns the child fragment's lens, optional when the spread is conditional
or deferred. The default accessor name is derived from the fragment name
(`issue.issueRow`); `@alias(as:)` names it verbatim.

**Fragment arguments.** *Concept: directive.* Relay: `@argumentDefinitions`
and `@arguments`. Here: the same directives. The compiler inlines them in
the normalization plan and the operation text, as Relay does; the spread's
accessor binds them into the child lens's [owner](#generated) over the
parent's variables (the passed literal or variable, else the default, else
null), once per parent owner, and storage keys with fragment variables
resolve against that scope.

**Refetchable fragment.** *Composition: document, directive, lens.* Relay:
`@refetchable(queryName:)`, a fragment the compiler generates a query for.
Here: the same; the lens gets `refetch()`, which runs the generated query
with the lens's variables and the owner's id and updates the records in
place. New variables replace the lens.

**Directive.** *Concept: directive.* GraphQL: an annotation on a selection
or definition. Here: the only way behaviour is attached to data; the set is
Relay's ([Relay's words](principles/relays-words.md)).

**Required.** *Concept: directive.* Relay:
`@required(action: NONE | LOG | THROW)`, a field the view cannot do without.
Here: the field reads non-optional. NONE and LOG bubble at the lens
boundary, as Relay nulls the enclosing object: the accessor that produces
the lens produces nil when a required field in it is null (a generated
`satisfied` checks), and LOG reports the path through
`Environment.requiredFieldMissing`. THROW makes the field's accessor
`get throws`, raising `RequiredFieldError`. A root that bubbles fails the
operation with a `RequiredFieldError` that names the operation and the path
of the first required field that is null (a generated
`missingRequiredField` finds it).

**Catch.** *Concept: directive.* Relay: `@catch(to: RESULT | NULL)`, a field
or aliased spread whose errors the view handles. Here: RESULT makes the
accessor a `Result<T, FieldErrors>` whose failure holds the field's error
and every error below it, THROW-required nulls included; NULL keeps the
optional type and reads errors as null. On an aliased spread the errors are
those in the fragment's own selection, whatever the fragment's policy.

**Throw on field error.** *Concept: directive.* Relay: `@throwOnFieldError`
on a fragment or operation, the policy under which `@semanticNonNull` fields
are typed non-null. Here: a fragment's spread accessor is `get throws` and
throws `FieldErrors` for an uncaught error inside; an operation with an
uncaught field error in its own selection, or one its response carried
without a field to hold it, is `.failed(FieldErrors)` with its data in the
store. An error inside a spread is the fragment's to weigh, as in Relay.
Semantic non-null fields read non-optional under either, and inside
`@catch`.

**Deferred fragment.** *Composition: document, directive.* GraphQL:
`...F @defer(label:)`, a fragment the server may deliver in a later part.
Here: the spread's accessor is optional and nil until the fragment's fields
are present (a generated `isPresent`); the plan marks the deferred fields
with the label, the availability check does not wait for them, and each part
is normalized at the record its path names. A separate check of the deferred
parts makes a `storeOrNetwork` attach fetch the parts the store holds only
half or not at all: a part held half is cleared, so its fragment reads
absent rather than empty, and the rest of the operation renders meanwhile.

**Variables.** *Concept: operation value.* GraphQL: an operation's
parameters. Here: the stored properties of an [operation value](#generated).

## Generated

**Lens.** *Concept: lens.* Baton's word. The typed, read-only view a
fragment or operation root compiles to: a record reference and a context,
its owner, with one accessor per declared field. Relay has two words,
fragment reference and fragment data, for what is one value here; "reader"
is Relay's name for machinery and "view" is SwiftUI's. See
[A fragment is a lens](principles/fragment-is-a-lens.md).

**Owner.** *Composition: lens, operation value.* Relay: the fragment owner,
the request whose variables a fragment reference is read with. Here: the
scope a lens reads in, one operation's variables or a fragment's arguments
bound over them, carried by the lens's anchor beside its record. A handle
makes one owner and keeps it; a storage key with variables is resolved once
per owner, and a spread with arguments binds its scope once per owner, so
later reads render, hash and allocate nothing.

**Anchor.** *Composition: lens, record, operation value.* Baton's word.
Where a lens reads: its record, its [owner](#generated), and the record it
was reached through, which a connection needs for its owner's id. Relay's
fragment reference carries a record id and an owner; an anchor holds the
record itself. Two anchors are equal when the three are the same objects. A
handle makes the root anchor its data reads from, as `mutate` does for the
data it returns, and generated accessors derive every anchor below it.
Generated code's alone: an app's code never holds one (see
[artifact](#compiler)).

**Operation value.** *Concept: operation value.* A `Hashable` struct of an
operation's variables, the thing a parent constructs and a navigation path
carries. Inside a view a query value resolves to a handle exposing `phase`,
`data`, `refetch`, `retry`, and a subscription value to one exposing its
events; the handle travels with the value its storage hands out.

**Operation handle.** *Composition: store, operation value, environment,
phase.* Relay: the query reference a loader hands out, and the request the
environment shares among equal fetches. Here: `OperationHandle`, the live
side of a query value, made by the environment and shared by equal values:
its phase, the fetch in flight, `isRefreshing`, `fetchTime`, and its place
among the store's roots while retained or in the release buffer.
`SubscriptionHandle` is the same for a subscription: the stream held open,
its events, its last error. Relay also calls the code behind `@connection`
and the edge directives handles; here "handle" is only the operation handle,
and an edge directive in a plan is an [edit](#lists).

**Phase.** *Concept: phase.* The state of a resolved operation: loading,
ready, or failed. Always synchronously readable; previous data stays visible
while refreshing, and `isRefreshing` says a fetch runs behind it: behind
ready data, or behind a failure on field errors or a `@required` null, whose
data is in the store. Named after `AsyncImagePhase`, the platform's own word
for the same shape.

**Action.** *Composition: lens, operation value, environment.* A mutation as
a callable value, after SwiftUI's `dismiss` and `openURL`: called with one
labelled argument per variable and an optional `optimistic:` response,
`async throws`, returns the mutation's data lens, exposes `isInFlight`.
`@Mutation("…") var star: StarMutation.Action`.

## Store

**Record.** *Concept: record.* Relay: a normalized object in the store.
Here: an observable object identified by typename plus key, holding interned
slots, per-field errors and type-membership bits. Its values are sized by
what was written, not by how many storage keys the type has, and the keys
rendered from variables written to it are kept in a short list apart. A
record `@deleteRecord` removed is *deleted*: links to it read as null, lists
skip it, the bodies that read its fields and those that hold a link to it
are told, and a payload that names it again revives it, told the same way;
see
[A deletion is announced by its commit](decisions/deletion-is-announced-by-its-commit.md).

**Key.** *Composition: schema, record.* The configured identity fields of a
type (default `id`), combined with the typename: `Type:id`. Objects without
a key get a path-based client id, as in Relay; under an interface or union
the path ends in the record's concrete type. The store has no index by id
alone: a lookup without a type (`node(id:)`) and `@deleteRecord` probe
`Type:id` for each possible type, and act only when exactly one live record
has the id.

**Storage key, slot.** *Composition: record, plan.* Relay: a field name plus
its serialized arguments, the key under which a value is stored. Here:
computed by the compiler and emitted as a constant; the process numbers each
key on first use, and a record stores the value at that number, so a read
through a constant hashes nothing. A key with variables is rendered once
per [owner](#generated); the keys a session renders, one per cursor and per
id, are numbered apart from the constants, with arguments or without, and a
record keeps those written to it in a list sorted by number, so they never
widen the records they are not written to. A key keeps the kind it is first
met as, and its text one slot. A field read through an interface or union
reads an *abstract slot*: its key's slot on each concrete type, resolved on
that type's first read. See
[Slots are numbered by the process](decisions/slots-are-numbered-by-the-process.md).

**Invalidation channel.** *Concept: record.* Baton's word; Relay tells a
fragment's subscribers when a record it read changes. Here: the Observation
key path a read of a slot registers on and only a change of that slot
notifies, one per slot index and shared by every record, so a body is
invalidated by a change to a field it read of a record it read, and by
nothing else.

**Store.** *Concept: store.* Relay's word. All records, retained roots and
lifetime state; owned by the main actor; read synchronously; written by
atomic commits. See
[The store is the UI's state](principles/store-is-the-ui-state.md).

**Commit, change set.** *Composition: store, plan.* A change set is the
output of ingesting one response or applying one optimistic update: records,
slots, references, errors, and the edits the plan asked for (a connection
page's merge, an edge directive's insert or delete). A commit applies it on
the main actor, edits after entries, and notifies the observed fields that
changed.

**Root, retain, release buffer.** *Composition: store, operation value,
environment.* Relay's words. An operation whose handle is alive retains its
records; a released root waits in a buffer (default ten) before its records
become collectable. A completed mutation's payload is a root apart from the
buffer, one per operation value (its name and variables) and as many as the
buffer holds, so mutations push no released query out.

**Invalidation, TTL.** *Composition: store, operation value, environment.*
Relay's and Apollo's shared words. `Environment.invalidate()` marks every
fetched operation stale and refetches the retained ones;
`queryCacheExpiration` does the same by age. Stale data stays readable. An
invalidation also forgets the image's fetch times, so it outlives the
launch.

**Persistence, image.** *Concept: store.* Baton's words; Relay's store lives
in memory. The image is the store's records in one SQLite file, written
behind every commit of server data, off the main actor: a row per record,
the query root a row per field, each operation's fetch time. Optimistic
layers never reach it. `Persistence(url:)` or `Persistence(name:)`, handed
to `Store(persistence:)`. It is a cache: an image of another format or
`version`, a corrupt one and one over its size limit are deleted and started
again, and a record that goes a whole launch unread is dropped at the next.
One image in a process holds a file; a second made on it runs without it,
and `close()` hands it over.

**Hydration.** *Composition: store, plan.* The web's word for filling a
client's state from stored data. Here: the availability check reading from
the image what memory lacks, a record's row once and a root field's row, so
an operation an earlier launch fetched is ready when its handle is made,
before the first body. Memory wins wherever it holds a value. The
operation's age comes with its data; data that needed the image and has no
fetch time is stale.

**Optimistic layer.** *Composition: store, plan, operation value.* Relay's
optimistic update, applied as a layer that is rebased on each commit. Here:
a typed `OptimisticResponse` ingested like a server response and applied
with an undo log; a commit under live layers lifts them, applies the
payload, re-applies them, and notifies only slots whose value differs in the
end. The server's answer replaces the layer; a failure reverts it. (Relay
says "optimistic update"; the layer is what makes the rebase explicit.)

**Mutation root.** *Concept: record.* The record mutation payloads hang off,
`client:root:mutation`, beside the query root. Entities inside a payload
merge into their own records as always. Its fields are keyed without their
arguments, `addNote` rather than `addNote(text:"…")`, and an aliased one by
its alias, `addNote(as:"first")`: the caller reads a payload once, and a key
per input would number a slot for every call. The three root records are
typed `Query`, `Mutation` and `Subscription` whatever the schema calls its
root types, as Relay's root record is a `__Root` in any schema: the compiler
interns a `QueryRoot` or a `query_root` by the store's name.

**Abstract selection.** *Composition: schema, document.* A selection on an
interface or union. The compiler adds `__typename`; the ingest keys the
object by the concrete type the payload names and resolves slots against
that type; a lens exposes `as<Type>` accessors and conditional spreads.
Relay's rule holds: a spread inside an inline fragment on an abstract
selection carries `@alias`.

**Field error.** *Composition: record, plan.* GraphQL: an entry of a
response's `errors` with a `path`. Here: resolved by the ingest to the
record and slot the path names and stored beside the field (`FieldError`:
message and dotted path); a payload that answers the field clears it; either
change notifies the field. Read through [catch](#documents) and
[throw on field error](#documents); a plain read sees null. A response with
errors and no data is a `GraphQLErrors` failure of the fetch.

**Heal.** *Composition: store, operation value, environment.* Baton's word
for the response to missing data: record the event, mark the owning
operation stale, refetch. See [Honest data](principles/honest-data.md).
Today: `Store.reportMissing` is called; the refetch is *(planned)*. A value
the generated type cannot hold, a null in a field typed non-null or a value
of another kind, is reported through `Store.reportUnexpected`; it is not a
miss, so nothing heals it.

## Compiler

**Schema.** *Concept: schema.* GraphQL: the SDL. Here: a checked-in file
plus identity configuration; introspection download is a CLI command.

**Plan.** *Concept: plan.* Baton's word for the normalization artifact: the
data a response is decoded by and a store is written from, one per
operation, emitted by the compiler and interpreted by the runtime. Relay's
normalization AST, renamed because it is data, not a tree the runtime walks
generically.

**Persisted id.** *Composition: document, transport.* Relay and the GraphQL
community's word for the hash a server accepts in place of operation text.
Here: emitted for every operation by default.

**Artifact.** *Composition: document, lens, plan.* Everything the compiler
emits for one source file: lens types, plans, ids. It opens with
`@_spi(Generated) import Baton`, the runtime's interface for generated code:
anchors and owners, the numbers of types and slots, the registry, the plan
types, and the anchor and initializer of every lens. An app's own files
import `Baton` and see lenses, handles, the environment, transports and
persistence.

## Runtime

**Environment.** *Concept: environment.* Relay's word for store plus network
plus configuration. Here the same, injected through SwiftUI's environment as
`\.baton`. Chosen over "client" (Apollo's word) by
[Relay's words](principles/relays-words.md). A request with nothing to send
it fails with `EnvironmentError`, which says what is missing: the view's
environment, the lens's, the one that made a handle and is gone, or the
subscription transport.

**Transport.** *Concept: transport.* The protocol behind which HTTP and
multipart incremental delivery live: `execute` answers once, `stream` yields
the parts of a deferred response. `URLSessionTransport` implements both;
`MultipartParser` splits the parts. A response outside 2xx fails with
`TransportError`, its HTTP status and body; a socket that closed under a
subscription and a recorded transport with nothing recorded fail with one of
status 0, which says what went wrong.

**Recorded transport.** *Concept: transport.* Baton's word.
`RecordedTransport` answers from recorded responses by operation name, or
from a function of the whole request, and keeps the requests it was sent;
for previews, tests and benchmarks. Not a mock: it is a transport like any
other, and nothing behind it can tell.

**Subscription.** *Composition: store, operation value, transport.* GraphQL:
an operation whose events arrive over time. Here: `@Subscription("…")`
expands like `@Query`: the storage subscribes while the view lives and
closes the stream when it goes; the handle exposes `events`, `latest`,
`error`, `isActive`. Each event is normalized at the subscription root
(`client:root:subscription`) and committed, so edge directives on its
payload work. `SubscriptionTransport` is the protocol;
`GraphQLTransportWebSocket` speaks `graphql-transport-ws`.

**Error behavior.** *Composition: schema, lens, transport.* The GraphQL
spec's `onError` request parameter (`PROPAGATE`, `NULL`, `ABORT`). Here:
`"onError"` in `baton.json`, decided at compile time and sent with every
operation the target compiles; never inferred. Under `NULL` an error nulls a
field in place, so the compiler types the fields the schema calls non-null
by their semantic nullability: non-optional under `@throwOnFieldError` and
inside `@catch`, optional elsewhere.

**Ingest.** *Composition: store, plan.* The off-main-actor stage that
decodes response bytes straight into a change set by following a plan.

**Preload.** *Composition: operation value, environment.* Relay: starting a
request on user intent, before the destination renders. Here:
`preload(operationValue)`; the destination's handle dedupes against it.

**Fetch policy.** *Composition: store, operation value, environment.*
Relay's four, as `@Query("…", fetchPolicy:)`: `storeOrNetwork`
(`FetchPolicy.default`), `storeAndNetwork`, `networkOnly`, `storeOnly`;
decided on attach over the availability check and staleness.

**Lookup.** *Composition: schema, store, plan.* Baton's word for a root
field configured in `baton.json` as returning an entity by one of its
arguments, so a cached entity satisfies the field before it was fetched. See
[the decision](decisions/lookups.md).

## Lists

**Connection, edge, node.** *Concept: connection.* The Relay cursor
connections specification. Here: a field with `@connection(key:)` is read
through Relay's handle key (`__<key>_connection(filters)`), a client record
on the parent that every page merges into: a page without a cursor replaces,
one after a cursor appends, one before a cursor prepends, edges deduplicate
by node, `pageInfo` merges per direction. The lens exposes the selection
plus `nodes` (Baton's one convenience, Relay leaves it to the product),
`hasNext`, `hasPrevious`, `isLoadingNext`, `isLoadingPrevious` and
`connectionID`. See
[the decision](decisions/connections-own-their-edges.md).

**Connection id.** *Concept: connection.* Relay's
`ConnectionHandler.getConnectionID`. Here: the connection record's key, read
as `connectionID`, passed in the `connections` variable of the edge
directives.

**Pagination.** *Composition: directive, lens, connection.* Relay:
`usePaginationFragment` over a `@refetchable` fragment whose connection
takes `first`/`after` (or `last`/`before`) from `@argumentDefinitions`.
Here: `loadNext(_:)` and `loadPrevious(_:)` on the connection lens, running
the fragment's refetch query with the lens's variables, the merged cursor
and the owner's id; the fetch has no handle and no root, the connection owns
the pages; the loading flags are client fields on the connection record
(`__isLoadingNext`, `__isLoadingPrevious`).

**Edge directives.** *Concept: directive.* Relay's declarative mutation
directives: `@appendEdge`, `@prependEdge`, `@appendNode`, `@prependNode`
(with `edgeTypeName`), `@deleteEdge`, `@deleteRecord`. Here: the same, on
mutation payload fields, applied as commit edits inside the transaction, so
optimistic responses carry them and revert them. A plan spells each as an
`Edit` on its field, which the ingest turns into the change set's
`ChangeSet.Edit`. Inserted edges are copied into records the connection
owns, numbered by Relay's `__connection_next_edge_index`. A commit edits a
connection by the slots its plans resolved, which the registry keeps under
the connection's type, so it looks no key up by name; a record no connection
field made, or an edge of another type than the connection's, is left alone.

**Page.** *Composition: lens, operation value.* A list fetched by page
number or offset, as the sample API does. Not a connection; composed in the
UI from plain operations until the watch list promotes a directive for it. 