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
Relay's ([Relay's words](principles/relays-words.md)), with one exception,
[cache expiration](#documents).

**Cache expiration.** *Concept: directive.* Baton's word. Relay has one
expiration for a whole store, `queryCacheExpirationTime`, and no word for
one query's; nor has the GraphQL specification. Here:
`@cacheExpiration(seconds:)` on a query states how old its data may be
before it reads as stale. The compiler emits it as a constant of the
operation, `cacheExpiration`, left out of the text a server receives, and
the handle reads it with the operation's age; an operation that states
none takes `Store(cacheExpiration:)`, the default given when the store is
made. Nothing is passed at an attach, and no timer is armed. See
[the decision](decisions/an-operation-states-its-expiration.md).

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

**Inline data fragment.** *Composition: document, directive.* Relay:
`@inline`, a fragment whose data a function outside rendering reads as a
plain value with `readInlineData`; the value is not live. Here:
*(planned)*, and until then the compiler rejects the directive. A fragment
so marked compiles to a `Sendable` value of its fields in place of a lens,
read out by the spread's accessor on the parent's lens: for code off the
main actor, and for rules tested with values. A fragment is a lens or
inline, never both, and no API takes the value. See
[the decision](decisions/a-fragment-has-one-reading.md).

**Variables.** *Concept: operation value.* GraphQL: an operation's
parameters. Here: the stored properties of an [operation value](#generated).

## Generated

**Lens.** *Concept: lens.* Baton's word. The typed, read-only view a
fragment or operation root compiles to: a record reference and a context,
its owner, with one accessor per declared field. Relay has two words,
fragment reference and fragment data, for what is one value here; "reader"
is Relay's name for machinery and "view" is SwiftUI's. An accessor's type
follows the schema's: a list whose elements the schema types nullable reads
as an array of optionals, a null element as nil; a list of non-null elements
reports an element it cannot hold, as a scalar reports a value it cannot
hold, and leaves it out; a list of records shows its records, a null entry
having no identity to be keyed by. See
[A fragment is a lens](principles/fragment-is-a-lens.md) and
[A list's null elements are typed as the schema says](decisions/a-lists-null-elements-are-typed.md).

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
its phase, its [fetch](#runtime) as a value, `isRefreshing`, `fetchTime`,
and its place among the store's roots while retained or in the release
buffer. `SubscriptionHandle` is the same for a subscription: the stream
held open as a value, `stream`, its events, its last error. See
[the decision](decisions/a-handle-derives-its-phase.md). Relay also calls
the code behind `@connection` and the edge directives handles; here "handle"
is only the operation handle, and an edge directive in a plan is an
[edit](#lists).

**Phase.** *Concept: phase.* The state of a resolved operation: loading,
ready, or failed. Always synchronously readable; previous data stays visible
while refreshing, and `isRefreshing` says a fetch runs behind it: behind
ready data, or behind a failure on field errors or a `@required` null, whose
data is in the store, which `retry()` leaves in place as a refetch does;
after any other failure a retry shows loading. Named after
`AsyncImagePhase`, the platform's own word for the same shape. Stored on the
handle and settled after each commit. Deriving it when it is read, from
what the store holds and from the handle's [fetch](#runtime), was decided
behind a gate, and the gate failed on the bench (`BENCHMARKS.md`,
2026-10-05: the verdict costs 567 µs untracked and 4.56 ms in a body's
tracking scope on the strict fixture, against the 50 µs the gate allowed),
so the phase stays stored and a fetch's failure is read beside it as the
fetch's value. See [the decision](decisions/a-handle-derives-its-phase.md).

**Action.** *Composition: lens, operation value, environment.* A mutation as
a callable value, after SwiftUI's `dismiss` and `openURL`: called with one
labelled argument per variable and an optional `optimistic:` response,
`async throws`, returns the mutation's data lens, exposes `isInFlight`.
`@Mutation("…") var star: StarMutation.Action`.

## Store

**Record.** *Concept: record.* Relay: a normalized object in the store.
Here: an observable object identified by typename plus key, holding interned
slots and per-field errors. Type-membership bits, so that a record of a
concrete type the build never saw takes its variant from the response's own
`__isX` answers, are *(planned)*. Its values are sized by
what was written, not by how many storage keys the type has, and the keys
rendered from variables written to it are kept in a short list apart. A
record `@deleteRecord` removed is *deleted*: links to it read as null, lists
skip it, the bodies that read its fields and those that hold a link to it
are told, and a payload that names it again revives it, told the same way;
see
[A deletion is announced by its commit](decisions/deletion-is-announced-by-its-commit.md).

**Key.** *Composition: schema, record.* The field named `id`, combined with
the typename: `Type:id`. Identity configured per type in `baton.json`, as
Relay's `nodeInterfaceIdField` and beyond it, is *(planned)*. Objects without
a key get a path-based client id, as in Relay; under an interface or union
the path ends in the record's concrete type. The store has no index by id
alone: a lookup without a type (`node(id:)`) and `@deleteRecord` probe
`Type:id` for each possible type, and act only when exactly one live record
has the id; an id that names live records of several types is reported
through `Store.reportAmbiguousIdentity`, and nothing is done for it.

**Storage key, slot.** *Composition: record, plan.* Relay: a field name plus
its serialized arguments, the key under which a value is stored; an
argument whose value is null is left out, so `notes(first:2)` names the
first page whether or not the document passed `after`. Here the same:
computed by the compiler and emitted as a constant; the process numbers each
key the build names on first use, and a record stores the value at that
number, so a read through a constant hashes nothing. A key with variables is
rendered once per [owner](#generated); the keys a session renders, one per
cursor and per id, are the store's: numbered by it, apart from the build's,
held by the resolutions and scopes that took them, freed by its collector
once nothing can name them and used again, and forgotten at its end; a
record keeps those written to it in a list sorted by number, so they never
widen the records they are not written to. A text has one slot in a
store: a rendering whose text the build names as a constant takes the
constant's slot, and a constant the build names after the store rendered
its text is adopted at the store's next resolution, check or commit, the
two slots becoming twins the store writes together. A field read through
an interface or union reads an
*abstract slot*: its key's slot on each concrete type, resolved on that
type's first read. A report names a slot through `Store.storageKey(of:)`.
See [Slots are numbered by the process](decisions/slots-are-numbered-by-the-process.md)
and [Keys a session produces belong to its store](decisions/session-keys-belong-to-the-store.md).

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
the main actor as a *batch*: the transaction that nets the notifications,
the undo log of what changed, and a kind. A *server* batch is written to
the image; an *optimistic* one keeps its undo with its layer and the image
is not told; a *local* one, the runtime's own writes, a page's loading
flag, a lookup's link bound, a link repaired, a cell filled from the image,
neither. Nothing outside a batch writes a record, edits follow entries, and
the observed fields that changed are notified when the batch ends.

**Commit payload.** *Composition: store, plan, operation value,
environment.* Relay: `commitPayload`, writing a response for an operation
that some other road delivered. Here: `Environment.commitPayload(operation,
payload)` runs the operation's plan over a payload in a response's shape,
with the ingest, the commit and the image a fetch has, through the same
door: the one way for data from outside the transport, a REST response, a
socket's tick, a preview's fixture, a test's seed. A payload may carry part
of what the operation selects. Client fields it alone writes are
*(planned)*. See
[the decision](decisions/client-data-is-described-and-committed.md).

**Root, retain, release buffer.** *Composition: store, operation value,
environment.* Relay's words. A root is an operation's selection and the
record it starts from, kept by the store with how many hold it; a record
lives while a root reaches it. `retain()` on a handle returns a
*retention*, `Retention`, a token whose end releases: `@Query`'s storage
holds one for the view's life, a model or a view controller holds one in a
property and lets it go with itself. A released root waits in the store's
release buffer (`Store(releaseBufferSize:)`, default ten), oldest out first,
before its records become collectable; a root pushed out takes its handle
and the fetch it had in flight with it. A completed mutation's payload is a
root apart from the buffer, one per operation value (its name and
variables) and as many as the buffer holds, so mutations push no released
query out. The store collects when a root left or a commit dropped a link,
once per turn of the main actor, and marks from the roots, the optimistic
layers and the image's write queue, and from nothing else. See
[the decision](decisions/the-store-owns-roots-and-ages.md).

**Invalidation, TTL.** *Composition: store, operation value, environment.*
Relay's and Apollo's shared words. `Environment.invalidate()` marks every
fetched operation stale and refetches the retained ones whose holders allow
the network; an operation's [cache expiration](#documents), or the store's
default, does the same by age. `Environment.revalidate()` refetches the
retained operations that are stale or whose last fetch failed, where a
holder allows the network, and marks nothing: for an app's return to the
foreground or a connection regained. Stale data stays readable. An
invalidation also forgets the image's fetch times, so it outlives the
launch. The age is the root's, kept by the store and stamped by the commit
of every response, a handle's fetch, a refetch, a page, `Environment.fetch`
or `commitPayload`, whoever asked for it, and persisted as the image's fetch
time; a handle reads it as `fetchTime`. Data with no known age is stale
wherever an expiration applies, in memory as from the image. See
[the decision](decisions/the-store-owns-roots-and-ages.md).

**Persistence, image.** *Concept: store.* Baton's words; Relay's store lives
in memory. The image is the store's records in one SQLite file, written
behind every commit of server data, off the main actor: a row per record,
the query root a row per field, each operation's fetch time. Optimistic
layers never reach it. `Persistence(url:)` or `Persistence(name:)`, handed
to `Store(persistence:)`. It is a cache: an image of another format,
`version` or protection class, a corrupt one and one over its size limit are
deleted and started again, a record that goes a whole launch unread is
dropped at the next, and the names no row uses go with the rows.
An image is made for one store and lives as long as it: the environment's
end closes it and gives the file back, and the next environment makes its
own, on that file or another; the image that takes a file over counts as a
launch, though the process is the same, so the rows the closed one wrote
that it does not read age out a launch sooner. One image in a process holds
a file; a second made on it runs without it. The file is made with the
protection class `Persistence(protection:)` names, or its directory's
default, which Apple's SQLite gives the file and its log. A file that cannot
be taken, locked or full, is waited for, not discarded: the writer keeps its
work for the next commit or read, a read meanwhile misses, and work that
outgrows 50,000 rows is dropped and the image started again. What keeps one
account's rows from the next is the account in the image's path or in its
`version`; `removeAll()`, deleting the file after the end, is hygiene, under
a marker that has the next open finish a deletion a crash interrupts. See
[the decision](decisions/an-image-belongs-to-one-store.md) and
[the file's](decisions/the-images-file-is-protected-and-waited-for.md).

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
errors and no data is a [request error](#runtime), a `GraphQLErrors`
failure of the fetch. An error keeps its `extensions`, as a JSON value
(`Variable`) beside its message and path, in memory and in the image, so
an app branches on the server's code and never on its message: see
[A failure says its kind](decisions/a-failure-says-its-kind.md).

**Heal.** *Composition: store, operation value, environment.* Baton's word
for the response to missing data: record the event, mark the owning
operation stale, refetch. See [Honest data](principles/honest-data.md). A
read that finds a slot the store never received reports it through
`Store.reportMissing` and tells its owner's environment, which marks the
owner's root stale and refetches it if a holder allows the network, once per
fetch of that root; a field still missing after the heal's own refetch is
reported through `Store.reportUnexpected` and healed no further. A lens made
by hand has no root and is reported, not healed. A value the generated type
cannot hold, a null in a field typed non-null or a value of another kind, is
reported through `Store.reportUnexpected`; it is not a miss, so nothing
heals it.

## Compiler

**Schema.** *Concept: schema.* GraphQL: the SDL. Here: a checked-in file,
named in `baton.json`. Identity configured beside it is *(planned)*; the
compiler has no introspection command, and the file is downloaded by the
app's own tooling.

**Client schema extension, client field.** *Concept: schema.* Relay:
`schemaExtensions`, files that give server types client fields or declare
types the server does not have. Here: *(planned)*; the compiler passes
Relay's front end no extensions today, and the only client data is the
runtime's own, a connection's record and the three roots. A client field
will be written by a [commit payload](#store) for an operation that selects
it and by nothing else, read by a lens like any field, and left out of the
text a server receives. Baton computes none: no resolvers. See
[the decision](decisions/client-data-is-described-and-committed.md).

**Custom scalar.** *Composition: schema, lens.* GraphQL: a scalar the
schema declares beside the built-in five. Here: stored as its text, exactly
as the server wrote it, and read as a `String`. A mapping to a Swift type
at the lens, under Relay's key `customScalarTypes`, is *(planned)*: the
accessor converts on read and is optional unless `@required`, `@catch` or
`@throwOnFieldError` covers it, because the schema promises the text and
not the conversion. A value that does not convert is reported as
unexpected and never reads as a zero value. See
[the decision](decisions/a-mapped-scalar-is-a-fallible-read.md).

**Plan.** *Concept: plan.* Baton's word for the normalization artifact: the
data a response is decoded by and a store is written from, one per
operation, emitted by the compiler and interpreted by the runtime. Relay's
normalization AST, renamed because it is data, not a tree the runtime walks
generically.

**Persisted id.** *Composition: document, transport.* Relay and the GraphQL
community's word for the hash a server accepts in place of operation text.
Here: emitted for every operation by default, an MD5 of its text, and sent
by no built-in transport. Sending it is *(planned)*: under Relay's
`persistConfig` an artifact carries the id and no text, without it the text
and no id, so the build decides which a request carries and no transport
has a mode. See
[the decision](decisions/an-operation-is-sent-as-text-or-id.md).

**Artifact.** *Composition: document, lens, plan.* Everything the compiler
emits for one source file: lens types, plans, ids. It opens with
`@_spi(Generated) import Baton`, the runtime's interface for generated code:
anchors and owners, the numbers of types and slots, the registry, the plan
types, and the anchor and initializer of every lens. That interface has a
format with a number, which the target's shared file names as
`Types.format` and the runtime declares as a marker type, so generated code
of another format fails to compile at that one line. An app's own files
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

**Session, end.** *Concept: environment.* The web's word for one identity's
stretch of use; Relay has no word for an environment's end, because
JavaScript collects one nobody holds. Here a session is the life of one
environment, not a type: an environment pairs a store with the transport
that fills it and replaces neither, a sign-in makes one and a sign-out ends
it, and which one is current is the app's state. `Environment.end()` ends
it, once and for good: it cancels every fetch and stream the environment
started, drops the roots, clears every record and closes the image, giving
its file back. An ended store commits nothing, checked at the one door a
payload takes, so a response that lands later reaches neither memory nor
the image; a handle still held reads `.failed(EnvironmentError.gone)` and
tells its observers, a lens still held finds its records cleared, and
every later call on the environment fails with the same error. A store
dropped without an end clears its records when it is deallocated: the net,
not the end. The order of a sign-out is the app's: end the environment,
remove the image, forget the credential last. See
[the decision](decisions/the-environment-is-the-session.md).

**Transport.** *Concept: transport.* The protocol behind which HTTP and
multipart incremental delivery live: `execute` answers once, `stream` yields
the parts of a deferred response. `URLSessionTransport` implements both;
`MultipartParser` splits the parts. A response outside 2xx fails with
`TransportError`, its HTTP status and body; a socket that closed under a
subscription and a recorded transport with nothing recorded fail with one of
status 0, which says what went wrong. `TransportError` stays the built-in
transports' error, and is carried unchanged inside the transport's kind of
[failure](#runtime), as a `URLError` or an app's own transport's error is.

**Recorded transport.** *Concept: transport.* Baton's word.
`RecordedTransport` answers from recorded responses by operation name, or
from a function of the whole request, and keeps the requests it was sent;
for previews, tests and benchmarks. Not a mock: it is a transport like any
other, and nothing behind it can tell. Beside it, `SilentTransport` never
answers, for a first body with no network behind it. Both live in
`BatonTesting`, a product of the package that an app's tests and previews
import and its shipping binary does not; see
[the decision](decisions/one-runtime-module.md).

**Subscription.** *Composition: store, operation value, transport.* GraphQL:
an operation whose events arrive over time. Here: `@Subscription("…")`
expands like `@Query`: the storage subscribes while the view lives and
closes the stream when it goes; the handle exposes `events`, `latest`,
`error`, and `stream`, the stream as a value: idle, connecting until the
first event, open, or ended, by the server's completion or by a
[failure](#runtime); `isActive` is connecting or open. Not a phase: a
subscription has no data of its own to wait for, so it has no loading. Each
event is normalized at the subscription root
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

**Request error.** *Composition: transport, phase.* GraphQL's word for an
error raised before execution begins, which leaves the response no data;
beside it the specification names the [field error](#store). Here: a
response of errors and no data fails its fetch with `GraphQLErrors`, whose
`errors` keep each error's message, path and `extensions`: the request
kind of a [failure](#runtime). See
[the decision](decisions/a-failure-says-its-kind.md).

**Ingest.** *Composition: store, plan.* The off-main-actor stage that
decodes response bytes straight into a change set by following a plan. A
change set holds what the store writes and nothing else; what the first
part of an incremental response announces, and whether more parts follow,
are read beside it, and the parts that follow are assembled into change
sets at the records their paths name by the environment's delivery.

**Preload.** *Composition: operation value, environment.* Relay: starting a
request on user intent, before the destination renders. Here:
`preload(operationValue)`; the destination's handle dedupes against it.

**Fetch.** *Composition: operation value, environment, transport.* Relay's
word: `fetchQuery`, and the fetch policies that say when one is made. Here:
one request for an operation's data, from the transport through the ingest
to the commit. A handle shows its last fetch as a value, `Fetch`: idle, in
flight, or failed with the [failure](#runtime) and when it failed, a
`ContinuousClock.Instant`; the operation value reads it as `fetch`, beside
`phase`. Not a phase: the phase is what the data deserves, and the fetch is
what the network did, so a fetch that fails behind data leaves the phase
ready and is read here until the next response, and `isRefreshing` is data
present and a fetch in flight. See
[the decision](decisions/a-handle-derives-its-phase.md).

**Failure.** *Composition: transport, environment, phase.* A plain English
word: GraphQL has *request error* and *field error* for the server's part
and no word for the client's. Here: `Failure`, what a fetch or a stream
that did not deliver says, in one of a closed set of kinds: the
transport's, a [request error](#runtime), a malformed response, the
environment's. The transport's kind carries what the transport threw,
unchanged, and `error` is the error as thrown whatever the kind. A field
error is not a kind: under `@throwOnFieldError` it fails the phase, as a
`@required` field that bubbled does, but it is a fact about the data. A
handle's [fetch](#runtime) carries it; a stream's end *(planned)* and the
events the runtime reports, proposed apart, classify by it. What the phase's
failed case and `refetch()` carry stays `any Error`, the error as thrown,
which the decision leaves open. See
[the decision](decisions/a-failure-says-its-kind.md).

**Fetch policy.** *Composition: store, operation value, environment.*
Relay's four, as `@Query("…", fetchPolicy:)`: `storeOrNetwork`
(`FetchPolicy.default`), `storeAndNetwork`, `networkOnly`, `storeOnly`;
decided on attach over the availability check and staleness. The policy is
the holder's: it stays with the retention the attach makes, so a fetch the
runtime starts later, for an invalidation, a revalidation or a heal, asks
whether any holder allows the network, and a `storeOnly` holder is fetched
for by none of them.

**Lookup.** *Composition: schema, store, plan.* Baton's word for a root
field configured in `baton.json` as returning an entity by one of its
arguments, so a cached entity satisfies the field before it was fetched. See
[the decision](decisions/lookups-bind-in-the-check.md), which superseded
[the first one](decisions/lookups.md).

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