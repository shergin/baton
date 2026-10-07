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
[plan](#compiler), its text and a persisted id. The text is printed
compact, with Relay's printer's own option: no newline, indentation or
optional space, a comma between items, strings as they are, the fragments
it reaches after it; the one text is sent, hashed, kept in the persisted
file and printed by `batonc print`
([the decision](decisions/operation-text-is-printed-compact.md)). The three
kinds are three protocols refining `Operation`, in GraphQL's words:
`Query`, read through a handle; `Mutation`, called as an
[action](#generated); `Subscription`, a stream of events into the store.
Each API takes only its kind.

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
`satisfied` checks), and LOG logs the path as a `requiredFieldMissing`
event. THROW makes the field's accessor
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
having no identity to be keyed by, as `List`, a collection of lenses, and a
nullable one as `List?`, since the server's null and its empty list differ,
with `List.empty` for a view that reads null as empty. See
[A fragment is a lens](principles/fragment-is-a-lens.md) and
[A list's null elements are typed as the schema says](decisions/a-lists-null-elements-are-typed.md).

**Membership, type condition.** *Composition: plan, record.* Relay: an
inline fragment or spread on an interface or union applies to the records
whose type satisfies it, and a response answers the condition for each
object in an `__isX: __typename` field. Here: whether a type is a member of
a condition is a table by the type's number, filled from the sets the build
compiled, `Types.Named_possible`, and from what responses say, so a lens
tests a record's type with an array load and no hash. A record of a type
the build did not list takes its variant from the answers: the fields
under each condition it satisfies with those every type reads, settled once
per type and per set of conditions; a linked field selected under two
conditions keeps the first's children. The image keeps the answers for the
next launch. A lookup without a type probes the compiled members. A
concrete type's lens under an interface or union, `asCharacter`, sees the
conditions on the interfaces and unions its type satisfies beside it: the
fields `... on Named` selected read through `asCharacter` as well, under
that condition's `@include` and `@skip`, as Relay's generated types give
each concrete variant every field a matching condition selected; a type
condition nested in the set condition folds in when the concrete type
satisfies it and is left out when it does not, so the fields merge with the
concrete condition's own; the set condition keeps its own lens, `asNamed`,
for the types the document does not name.

**Owner.** *Composition: lens, operation value.* Relay: the fragment owner,
the request whose variables a fragment reference is read with. Here: the
scope a lens reads in, one operation's variables or a fragment's arguments
bound over them, carried by the lens's anchor beside its record. A handle
makes one owner and keeps it; a storage key with variables is resolved once
per owner, and a spread with arguments binds its scope once per owner, so
later reads render, hash and allocate nothing.

**Anchor.** *Composition: lens, record, operation value.* Baton's word.
Where a lens reads: its record, its [owner](#generated), and the record the
fragment it is in starts at, its origin, whose id a connection's pagination
and a refetch pass to the fragment's query wherever below it they read.
Relay's fragment reference carries a record id and an owner; an anchor
holds the records themselves. Two anchors are equal when the three are the
same objects. A handle makes the root anchor its data reads from, as
`mutate` does for the data it returns, a fragment spread enters its record
as the origin, and generated accessors derive every anchor below it.
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
fetch's value. See [the decision](decisions/the-phase-stays-stored.md),
which superseded [the first one](decisions/a-handle-derives-its-phase.md)
on that point.

**Action.** *Composition: lens, operation value, environment.* A mutation as
a callable value, after SwiftUI's `dismiss` and `openURL`: called with one
labelled argument per variable and an optional `optimistic:` response,
`async throws`, returns the mutation's data lens, exposes `isInFlight`.
`@Mutation("…") var star: StarMutation.Action`.

## Store

**Record.** *Concept: record.* Relay: a normalized object in the store.
Here: an observable object identified by typename plus key, holding interned
slots and per-field errors. A record of a concrete type the build never
saw takes its variant from the response's own `__isX` answers, as
[membership](#generated) says. Its values are sized by
what was written, not by how many storage keys the type has, and the keys
rendered from variables written to it are kept in a short list apart. A
record `@deleteRecord` removed is *deleted*: links to it read as null, lists
skip it, the bodies that read its fields and those that hold a link to it
are told, and a payload that names it again revives it, told the same way;
see
[A deletion is announced by its commit](decisions/deletion-is-announced-by-its-commit.md).

**Key.** *Composition: schema, record.* The values of the fields
`baton.json` names for the type, after the typename: `Type:id` by default,
`Asset:uuid` for a type configured otherwise, `Quote:base:quote` for a
composite key, each value escaped when there are several so that no two
lists of values meet. The configuration's `identity` has a `default` list,
tried for every object type, and `types` entries for a type or for an
interface, whose implementers take it. A key is own scalar fields, in order,
and does not rename: it is the values at the write, so a field that changes
makes another record; a key through a link waits for an entity with no
scalar key of its own. The compiler selects the key fields wherever the type
is read, as Relay selects `id`, and the plan names each type's key, so the
ingest knows no field by name. Objects whose fields do not include the key
get a path-based client id, as in Relay; under an interface or union the
path ends in the record's concrete type. The store has no index by id alone,
and what names a record by one value, a lookup without a type (`node(id:)`),
`@deleteRecord`, `@deleteEdge` and the image's forget, reaches single-field
keys only: a lookup without a type and `@deleteRecord` probe `Type:id` for
each possible type, and act only when exactly one live record has the id; an
id that names live records of several types is logged as an
`ambiguousIdentity` event, and nothing is done for it. A configuration
other than the default joins the schema's digest, so an image keyed another
way is a miss and not a merge. See
[the decision](decisions/identity-is-configured.md).

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
of what the operation selects, and it alone writes
[client fields](#compiler). See
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
[the decision](decisions/the-store-owns-roots-and-ages.md) and
[the revalidation decision](decisions/revalidation-is-the-apps-call.md).

**Persistence, image.** *Concept: store.* Baton's words; Relay's store lives
in memory. The image is the store's records in one SQLite file, written
behind every commit of server data, off the main actor: a row per record,
the query root a row per field, each operation's fetch time. A row is
replaced by a commit's snapshot of the record when the check has read the
row into memory; the snapshot of a record memory has not read is merged
into the row, so a response with a few of a record's fields leaves the rest
for the next check. Optimistic layers never reach it. `Persistence(url:)`
or `Persistence(name:)`, handed to `Store(persistence:)`. It is a cache: an
image of another format,
`version` or protection class and a corrupt one are deleted and started
again; one over its size limit evicts the rows of launches before the last,
then the last launch's, and starts again only when nothing is left to evict
([the decision](decisions/the-image-evicts-by-launch.md)); a record that
goes a whole launch unread is dropped at the next, and the names no row
uses go with the rows.
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
read that finds a slot the store never received logs it as a `missing`
event and tells its owner's environment, which marks the owner's root stale
and refetches it if a holder allows the network, once per fetch of that
root; a field still missing after the heal's own refetch is logged as
`unexpected` and healed no further. A lens made by hand has no root and is
logged, not healed. A value the generated type cannot hold, a null in a
field typed non-null or a value of another kind, is logged as `unexpected`;
it is not a miss, so nothing heals it.

## Compiler

**Schema.** *Concept: schema.* GraphQL: the SDL. Here: a checked-in file,
named in `baton.json`, with the [identity](#store) configured beside it;
the compiler has no introspection command, and the file is downloaded by the
app's own tooling.

**Client schema extension, client field.** *Concept: schema.* Relay:
`schemaExtensions`, files that give server types client fields or declare
types the server does not have. Here the same key in `baton.json`, files or
directories of `.graphql` beside it, read with the schema and folded into
its digest. A client field is nullable, since no server promises it; it is
written by a [commit payload](#store) for an operation that selects it and
by nothing else, read by a lens like any field, left out of the text and
the id a server receives, and neither waited for by the availability check
nor healed: the registry marks a client slot, so a lens reads it as absent
until a payload writes it and reports nothing missing. An operation of
client fields alone is refused, since a server answers one field at least.
The plan marks each client field, the origin a walk reads beside the
server's and a `@defer` label's; the check hydrates client fields from the
image without waiting for them. Client records live and reach the image as
any record does. Baton computes none: no resolvers. See
[the decision](decisions/client-data-is-described-and-committed.md).

**Custom scalar, mapped scalar.** *Composition: schema, lens.* GraphQL: a
scalar the schema declares beside the built-in five. Here: stored as its
text, exactly as the server wrote it, and read as a `String`; or, mapped
under Relay's key `customScalarTypes` to a Swift type conforming to
`MappedScalar` (`Decimal`, `Date`, `URL` and `UUID` conform, each with one
format: the POSIX locale, ISO 8601's internet profile with or without
fractional seconds), read as that type, converted from the text at the
read and never cached on the record. The accessor says the conversion can
fail: it is optional wherever the schema puts the field, unless a
directive says what a failure does. `@required` and `@throwOnFieldError`
make it non-optional and throwing, since a value that does not convert
has no zero to read as; under `@required(action: NONE)` or `LOG` the lens
is unsatisfied as a null would leave it. `@catch` makes it a `Result`
whose failure carries the conversion's error, under the field's path. A
value that does not convert is reported as unexpected, never as missing,
and never reads as a zero value; an element of a list that does not
convert is reported once, left out of a list of non-null elements as an
element the list cannot hold is, and read as nil in a list of nullable
elements. There is no raw accessor beside the mapped one. A variable of
a mapped type takes the Swift type and is sent as its text. See
[the first decision](decisions/a-mapped-scalar-is-a-fallible-read.md) and
[the second](decisions/a-mapped-scalar-converts-at-the-read.md).

**Enum.** *Composition: schema, lens.* GraphQL: a type with a closed set of
named values. Here: stored as its text, as a custom scalar is, and read as
a Swift enum generated for it, with a case per value the build knows and
`unknown(String)` for one it does not, so a value the schema gained after
the build reads as itself rather than failing the read; Relay's generated
types carry `%future added value` for the same reason. The conversion
cannot fail, so the accessor keeps the schema's nullability; a null on a
non-null field reads as `unknown("")` and is reported, as any value a type
cannot hold is. A variable of an enum type takes the enum and is sent as
its text. The enum is declared once per module in the shared file, named
as the schema names it; a schema enum named like a fragment or an operation
is a name error at the document, and one named like a shared enum or the
standard library's types takes `Enum` after its name. See
[the decision](decisions/an-enum-reads-as-a-generated-enum.md).

**Transient.** *Composition: schema, image.* What never reaches the image,
decided at build time in `baton.json`'s `transient` block like identity and
lookups: the records of the types named (an interface's entry names its
implementers), and the cells, storage keys and fetch stamps of the root
fields named, `Query.search`, since a root field's key carries the arguments
it was asked with and an operation's stamp carries its variables. A record's
slot that links to a transient record is left out of its row, so nothing on
disk names one; the next launch misses on it and fetches, as the owner's rule
has it: a list is never shortened to fit, and a screen that shows transient
records refetches at launch. Memory is unaffected: the store keeps the
records as long as a retention reaches them. The shared file declares the
lists once, as `Types.transient`, and every plan of the module names it, so
the registry knows them before any plan writes a row. The lists join the
schema's digest, so an image written under another list starts again. Not a
Relay word, since Relay's store is not persisted; borrowed from the ordinary sense
of what does not outlive its process, over *ephemeral*, which says short
lived rather than unwritten, and *volatile*, which names a kind of memory.
See [the decision](decisions/what-may-reach-the-image.md).

**Input object.** *Composition: schema, operation.* GraphQL: a type of
named fields an argument or variable takes. Here: a Swift struct generated
per input object the documents' variables name, declared once per module in
the shared file, with a property per field typed as the schema types it, a
scalar, an enum, a mapped scalar, a nested input or a list of one, optional
unless non-null, and an initializer with a parameter per field. A variable
of the type takes the struct, so a misspelled field is a compile error where
it was a server's error before. A field left nil is absent from the request,
as GraphQL distinguishes absent from null; a document that must send an
explicit null for a field writes it as a constant in the document. The
struct's `variable` is the object the request carries, as an optimistic
response's builder renders itself; the struct is `Hashable`, since an
operation value compares and hashes its variables. Named as the schema names it; one named
like a shared enum or a standard library type takes `Input` after its name,
and a field named `variable` takes an underscore. A field whose type contains
the input itself, `input Filter { not: Filter }`, is boxed by `Baton.Indirect`,
since a value type cannot hold itself; the struct reads and writes it as any
other field.

**Plan.** *Concept: plan.* Baton's word for the normalization artifact: the
data a response is decoded by and a store is written from, one per
operation, emitted by the compiler and interpreted by the runtime. Relay's
normalization AST, renamed because it is data, not a tree the runtime walks
generically.

**Persisted id.** *Composition: document, transport.* Relay and the GraphQL
community's word for the hash a server accepts in place of operation text.
Here: under Relay's `persistConfig` in `baton.json`, `file` and `algorithm`
(`MD5`, `SHA256` or `SHA1`), an artifact carries the id, the text's hash in
lowercase hexadecimal, and no text, and `batonc generate` writes the file,
Relay's map from id to text with the ids in order, beside the configuration
when run by hand and into the build's output directory under the SwiftPM
plugin; without `persistConfig` the artifact carries the text and no id. So
the build decides what a request carries, the operation's `document` says
which, text or id and never both, and no transport has a mode or a fallback.
The standard encoding writes an id as `documentId`, after the GraphQL over
HTTP working group's proposal. See
[the decision](decisions/an-operation-is-sent-as-text-or-id.md).

**Artifact.** *Composition: document, lens, plan.* Everything the compiler
emits for one source file: lens types, plans, ids. It opens with
`@_spi(Generated) import Baton`, the runtime's interface for generated code:
anchors and owners, the numbers of types and slots, the registry, the plan
types, and the anchor and initializer of every lens. That interface has a
format with a number, which the target's shared file names as
`Types.format` and the runtime declares as a marker type, so generated code
of another format fails to compile at that one line. An app's own files
import `Baton` and see lenses, handles, the environment, the log, transports
and persistence; records, values, slots and type ids are the interface's.

**Report.** *Composition: document, schema.* Baton's word for what the
compiler compiled for one target, written by `batonc generate --report` as
JSON and, under the SwiftPM plugin, into the build's output directory as
`Baton.report.json`: the schema's digest; every operation with its name,
kind, source, id when persisted, variables as the schema types them, the
fragments it reaches directly or through other fragments, and its text;
every fragment with its name, type condition, source, the operations that
reach it, and its definition as the author wrote it, printed before the
transforms. Deterministic, by
name, with sources relative to the working directory, so the diff of two
builds' reports is the contract's change. `validate`, `print` and
`generate --check` are the same compilation with another output, and
[the command's contract](recipes/batonc.md) states all of them. The
persisted documents file is a second view of the same facts, and a dependent target's compilation is what
the fragment's definition is there for; see
[the decision](decisions/the-report-is-what-a-dependent-target-reads.md).

## Runtime

**Log.** *Concept: environment.* Relay's word for the function an
environment is given and calls with each event of its work (`LogEvent`); #15
asked for it as an event sink. Here: `Environment.log`, a closure of
`LogEvent`, a value-free enum of names and counts, never a record, a slot, a
value, a variable or a response body, so an app routes it to its logging and
metrics without logging anything a user typed. The cases are the fetch
(started, completed with its duration, failed with its failure's kind), the
commit (its kind and the slots it changed in records that existed), a field
error a fetch's response carried that no `@catch` handled, by operation and
response path, the image (opened, unavailable, written, failed), a deferred part dropped for
naming a place the store or the plan does not have, and missing data (a
field read and never fetched, a value a reader's type cannot hold,
an id naming records of several types, a `@required(action: LOG)` field that
is null), each by type and field name. Debug builds print the missing-data
cases until `log` is set; a test sets `log = nil`. See [the
decision](decisions/the-environment-logs-value-free-events.md).

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

**Transport.** *Concept: transport.* The protocol behind which HTTP,
multipart incremental delivery and the socket live, with one verb: `send`,
a request yielding a stream of payloads, one for a query, the parts of a
deferred response, the events of a subscription, so a wrapper wraps one
method whatever the operation's kind; `payload` reads the one payload of a
request that answers once. A `Request` says its kind, query, mutation or
subscription, so a wrapper never retries a mutation a server may have
received, and carries the operation's `document`, text or id. One function,
an `Encoding`, turns a request into the JSON a server receives, for the
HTTP body and the socket's subscribe payload alike; the standard one writes
`operationName`, `variables`, `onError` when set, and `query` for a text or
`documentId` for an id, and a server with another convention replaces the
function on the built-in transports and keeps them. The built-in transports
read credentials per attempt, from a closure, so a rotated token reaches the
next request or connection. `URLSessionTransport` speaks HTTP, reads
`multipart/mixed` for a deferred response and `text/event-stream` for a
subscription, `graphql-sse` in its distinct-connections mode, one response
per operation whose `next` events carry payloads and whose `complete` ends
it, so the environment's `subscriptions` may be an HTTP transport;
`GraphQLTransportWebSocket` speaks `graphql-transport-ws` for subscriptions
and any operation sent over the socket; `MultipartParser` splits the parts
and `EventStreamParser` the events. The single-connection mode of
`graphql-sse` waits for a gateway that cannot do HTTP/2. A response outside
2xx fails with `TransportError`, its HTTP status and body; a socket that closed under a subscription, a recorded
transport with nothing recorded and a transport that delivers no payload
fail with one of status 0, which says what went wrong. `TransportError`
stays the built-in transports' error, and is carried unchanged inside the
transport's kind of [failure](#runtime), as a `URLError` or an app's own
transport's error is. What a production endpoint needs beyond the built-in
transports, one replay of an authorization challenge, a bounded retry with
backoff, a deadline across the attempts, is a wrapper over the one verb the
app owns, not a library type; [the exchange recipe](recipes/exchange.md)
walks through the one the GitHub sample sends through.

**Inspector.** *Composition: store, record.* Baton's word for the view a
debug build presents over an environment's store: its counts, its records
by type, each record's slots with their values and field errors, and an
export in the dump format `spec/` freezes, `StoreExport.text(of:)`, so a
bug report can become a fixture. It reads and never writes: no provenance
per slot, no action that evicts. `StoreInspector` lives in `BatonInspector`,
a product of its own, so a release build need not link it.

**Recorded transport, scripted transport.** *Concept: transport.* Baton's
words. `RecordedTransport` answers from recorded responses by operation
name, or from a function of the whole request, and keeps the requests it
was sent; for previews, tests and benchmarks. `ScriptedTransport` does the
same and more for an app's tests: it holds a mutation, or any operation the
test names, until the test replies or refuses, so the window between an
optimistic apply and the server's answer can be observed; it drives a
subscription's events by hand, delivering, completing or failing; and it
lists its requests by kind. An operation with no answer scripted fails with
a status 0 that says so. Beside them, `SilentTransport` never answers, for a
first body with no network behind it, and `wait(until:)` waits for a handle
or a store to settle. Not mocks: each is a transport like any other, and
nothing behind it can tell. All live in `BatonTesting`, a product of the
package that an app's tests and previews import and its shipping binary
does not; see [the decision](decisions/one-runtime-module.md).

**Subscription.** *Composition: store, operation value, transport.* GraphQL:
an operation whose events arrive over time. Here: `@Subscription("…")`
expands like `@Query`: the storage subscribes while the view lives and
closes the stream when it goes; the handle exposes `events`, `latest`,
`error`, `resumptions` and `stream`, the stream as a value: idle, or parked
while the environment is inactive; connecting until the first event; open;
waiting to reconnect, until the instant the handle opens it again after a
[failure](#runtime), by a fixed backoff, a step doubling from one second to
thirty and jittered to between half and the whole of it, reset by an event;
or ended, by the server's completion, by a request error (the server's
refusal of the operation, which a retry would repeat) or by the environment's
end. `isActive` is connecting or open; `retry()` opens a waiting or ended
stream at once.
`resumptions` counts the stream's reopenings, after a failure's wait or the
environment's inactivity, since events may have been missed across each: an
owner observes the count and refetches its baseline, with no callback. The
environment's `isActive`, set by the app from its scene phase, parks every
retained subscription while false and resumes them when true. Not a phase: a
subscription has no data of its own to wait for, so it has no loading. Each
event is normalized at the subscription root
(`client:root:subscription`) and committed, so edge directives on its
payload work. The environment's `subscriptions` transport carries them,
through the one verb every [transport](#runtime) has;
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
handle's [fetch](#runtime) carries it, a subscription's stream ends with
it, and the [log](#runtime)'s events name its kind. What the phase's
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
for by none of them. See
[the decision](decisions/revalidation-is-the-apps-call.md).

**Lookup.** *Composition: schema, store, plan.* Baton's word for a root
field configured in `baton.json` as returning an entity by its arguments,
so a cached entity satisfies the field before it was fetched: one argument
(`argument`) for a type keyed by one field, or one per field of a composite
key in the key's order (`arguments`), composed into the record's key as the
ingest composes it. A lookup without a type finds an id among the field's
types that one value keys. See
[the decision](decisions/lookups-bind-in-the-check.md), which superseded
[the first one](decisions/lookups.md), and
[the identity decision](decisions/identity-is-configured.md), which answered
the first one's reopening line.

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