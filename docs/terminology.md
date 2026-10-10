# Terminology

The vocabulary contract: every public concept is named here before it is
named in code, and when a concept is added, renamed or changes meaning, this
file is updated in the same change. Each entry is in parts, in this order.
First the meaning in the literature, under its source (GraphQL, Relay, the
web, Baton, Apollo), and why this word was chosen over the alternatives.
Then *Here*: what the thing is in Baton, in no language's terms, which is
the rule as [the runtime contract](../spec/runtime.md) states it, with a
link to the section that holds it. Then *Swift*: the spelling, the types,
properties, macros, products and modules by which the Swift runtime and its
generated code name it. Then *Kotlin*: the same for the Kotlin runtime and
its generated Kotlin, with what differs from the Swift spelling: a getter
that throws where Swift's accessor throws, a `Result` for `@catch`, a
`Hold` for a retention, a `Flow` for a stream. An entry with nothing to
spell has neither part. Each entry is also marked with its place in the
closed inventory of
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
fragments.
Here: an executable document, carried by a marker in source code or held in
a `.graphql` file. The compiler reads every document of a module beside the
schema, which GraphQL also writes as a document and which is a concept of
its own here.
Swift: the markers are macros, `@Query("…")`, `@Fragment("…")`,
`@Mutation("…")` and `@Subscription("…")`, in Swift source.
Kotlin: the markers are annotations of the same names on the composable,
or the class, that renders, holds or acts, a document with a variable
written in a `$$"""…"""` raw string; nothing of them reaches a class file.
Each repeats, so a host may carry several documents, as a button that stars
and unstars carries two `@Mutation`s.

**Fragment.** *Concept: document.* GraphQL: a named selection on a type.
Relay: the unit of a component's data needs.
Here: declared beside the view that reads it, in source code or a
`.graphql` file; compiles to a [lens](#generated) type.
Swift: declared in Swift source with `@Fragment("…")`.
Kotlin: declared with `@Fragment("…")` on the composable that renders it,
which takes the lens as a parameter.

**Operation.** *Concept: document.* GraphQL: a query, mutation or
subscription.
Here: assembled by the compiler from the fragments spread into it; one per
screen; compiles to a variables type, a root lens, a [plan](#compiler), its
text and a persisted id. The text is printed compact, with Relay's
printer's own option: no newline, indentation or optional space, a comma
between items, strings as they are, the fragments it reaches after it; the
one text is sent, hashed, kept in the persisted file and printed by
`batonc print`
([the decision](decisions/operation-text-is-printed-compact.md);
[the contract](../spec/runtime.md#10-the-environment-and-the-wire)). The
kinds are GraphQL's three, in its words: a query, read through a handle; a
mutation, called as an [action](#generated); a subscription, a stream of
events into the store. Each API takes only its kind.
Swift: the three kinds are three protocols refining `Operation`: `Query`,
`Mutation` and `Subscription`.
Kotlin: `QueryOperation`, `MutationOperation` and `SubscriptionOperation`,
declared with `@Query`, `@Mutation` and `@Subscription`; a composable
resolves a query value with `rememberQuery(operation, fetchPolicy)`, a
subscription value with `rememberSubscription(operation)`, and takes a
mutation's action with `rememberMutation(Companion)`. The companions'
types, `OperationType` and its kinds' `QueryType`, `MutationType` and
`SubscriptionType`, are application API, outside the opt-in; what generated
code alone calls on them is inside it.

**Spread.** *Composition: document, lens.* GraphQL: `...Name` inside a
selection.
Here: compiles to a named accessor on the parent lens that returns the
child fragment's lens, optional when the spread is conditional or deferred.
The default accessor name is derived from the fragment name;
`@alias(as:)` names it verbatim. See
[the contract](../spec/runtime.md#6-the-lens-reads).
Swift: the derived name reads `issue.issueRow`.
Kotlin: the same derived name, `issue.issueRow`, a getter returning the
fragment's lens class, nullable when the spread is conditional, deferred or
bubbles a `@required` field.

**Fragment arguments.** *Concept: directive.* Relay: `@argumentDefinitions`
and `@arguments`.
Here: the same directives. The compiler inlines them in the normalization
plan and the operation text, as Relay does; the spread's accessor binds them
into the child lens's [owner](#generated) over the parent's variables (the
passed literal or variable, else the default, else null), once per parent
owner, and storage keys with fragment variables resolve against that scope.
See [the contract](../spec/runtime.md#6-the-lens-reads).

**Refetchable fragment.** *Composition: document, directive, lens.* Relay:
`@refetchable(queryName:)`, a fragment the compiler generates a query for.
Here: the same; the lens gets a refetch, which runs the generated query
with the lens's variables and the owner's id and updates the records in
place. New variables replace the lens. See
[the contract](../spec/runtime.md#6-the-lens-reads).
Swift: the refetch is `refetch()`.
Kotlin: the refetch is the lens's `suspend fun refetch()`, run through the
environment of the handle the lens was read from; a lens made by hand throws
`EnvironmentError.OutsideEnvironment`.

**Directive.** *Concept: directive.* GraphQL: an annotation on a selection
or definition.
Here: the only way behaviour is attached to data; the set is Relay's
([Relay's words](principles/relays-words.md)), with one exception,
[cache expiration](#documents).

**Cache expiration.** *Concept: directive.* Baton's word. Relay has one
expiration for a whole store, `queryCacheExpirationTime`, and no word for
one query's; nor has the GraphQL specification.
Here: `@cacheExpiration(seconds:)` on a query states how old its data may be
before it reads as stale. The compiler emits it as a constant of the
operation, left out of the text a server receives, and the handle reads it
with the operation's age; an operation that states none takes the store's
default, given when the store is made. Nothing is passed at an attach, and
no timer is armed. See
[the contract](../spec/runtime.md#7-the-lifetime-roots-retention-ages-collection)
and [the decision](decisions/an-operation-states-its-expiration.md).
Swift: the constant is `cacheExpiration`; the store's default is
`Store(cacheExpiration:)`.
Kotlin: the constant is the companion's `cacheExpirationSeconds`, a `Double?`;
the store's default is `Store(cacheExpiration = ...)`, a `Duration?`, null for
none.

**Required.** *Concept: directive.* Relay:
`@required(action: NONE | LOG | THROW)`, a field the view cannot do without.
Here: the field reads non-optional. NONE and LOG bubble at the lens
boundary, as Relay nulls the enclosing object: the accessor that produces
the lens produces nil when a required field in it is null, and LOG logs the
path. THROW makes the field's accessor throw a required-field error. A root
that bubbles fails the operation with a required-field error that names the
operation and the path of the first required field that is null. See
[the contract](../spec/runtime.md#6-the-lens-reads).
Swift: a generated `satisfied` checks the lens; LOG's event is
`requiredFieldMissing`; THROW makes the accessor `get throws`, raising
`RequiredFieldError`; the root's failure is a `RequiredFieldError`, and a
generated `missingRequiredField` finds the path.
Kotlin: the companion's generated `satisfied(anchor)` checks the lens, and a
spread that bubbles reads null; LOG's event is
`LogEvent.RequiredFieldMissing`; THROW makes the field's getter throw
`RequiredFieldError`, since Kotlin has no throwing property; the root's
failure is `Phase.Failed(RequiredFieldError)`, its path found by the
companion's generated `missingRequiredField(anchor)`.

**Catch.** *Concept: directive.* Relay: `@catch(to: RESULT | NULL)`, a field
or aliased spread whose errors the view handles.
Here: RESULT makes the accessor a result whose failure holds the field's
error and every error below it, THROW-required nulls included; NULL keeps
the optional type and reads errors as null. On an aliased spread the errors
are those in the fragment's own selection, whatever the fragment's policy.
See [the contract](../spec/runtime.md#6-the-lens-reads).
Swift: RESULT's accessor is a `Result<T, FieldErrors>`.
Kotlin: RESULT's accessor is a `kotlin.Result<T>` whose failure is a
`FieldErrors`, since Kotlin's `Result` names no error type; a plural link
reads a `Result` of its list and an aliased spread a `Result` of its lens;
NULL keeps the nullable type.

**Throw on field error.** *Concept: directive.* Relay: `@throwOnFieldError`
on a fragment or operation, the policy under which `@semanticNonNull` fields
are typed non-null.
Here: a fragment's spread accessor throws the field errors for an uncaught
error inside; an operation with an uncaught field error in its own
selection, or one its response carried without a field to hold it, is
failed with those errors, with its data in the store. An error inside a
spread is the fragment's to weigh, as in Relay. Semantic non-null fields
read non-optional under either, and inside `@catch`. See
[the contract](../spec/runtime.md#6-the-lens-reads) and
[its verdict](../spec/runtime.md#8-the-handle-policies-phase-fetch).
Swift: the spread accessor is `get throws` and throws `FieldErrors`; the
failed operation is `.failed(FieldErrors)`.
Kotlin: the spread's getter reads through the fragment companion's generated
`throwing(anchor)`, which throws `FieldErrors`, beside `caught(anchor)`, the
same as a `Result`; the failed operation is `Phase.Failed(FieldErrors)`, and
`Environment.fetch`, `commitPayload` and a mutation's action throw it.

**Deferred fragment.** *Composition: document, directive.* GraphQL:
`...F @defer(label:)`, a fragment the server may deliver in a later part.
Here: the spread's accessor is optional and nil until the fragment's fields
are present; the plan marks the deferred fields with the label, the
availability check does not wait for them, and each part is normalized at
the record its path names. A separate check of the deferred parts makes a
`storeOrNetwork` attach fetch the parts the store holds only half or not at
all: a part held half is cleared, so its fragment reads absent rather than
empty, and the rest of the operation renders meanwhile. See
[the contract](../spec/runtime.md#5-the-availability-check-and-hydration)
and [its incremental parts](../spec/runtime.md#3-the-ingest-a-response-to-a-change-set).
Swift: a generated `isPresent` says whether the fields are present.
Kotlin: the companion's generated `isPresent(anchor)` says it, and the
spread's getter is nullable, null until then.

**Inline data fragment.** *Composition: document, directive.* Relay:
`@inline`, a fragment whose data a function outside rendering reads as a
plain value with `readInlineData`; the value is not live.
Here: a fragment so marked compiles to a value of its fields in place of a
lens, a nested value per link, a list per plural link, and a way to build
one from the fields, so a test builds one. The spread's accessor on the
parent's lens builds it from the record when it is called, on the main
thread, and its reads register as a lens's do: for code off the main
thread, for rules tested with values, and for the value as of a tap. A
fragment is a lens or inline, never both, and no API takes the value. An
inline fragment spreads only inline fragments and takes no `@connection`,
`@refetchable` or `@required`, the last by Relay's rule; a non-null mapped
scalar in it reads optional, since a stored property cannot throw, and
under `@throwOnFieldError` a text that does not convert throws at the
spread. Its spread takes what any spread takes; `@catch` has no place on a
spread in Relay's schema, and `... @alias(as:) @catch { ...Value }` reads a
result. A value's field errors include those of the values it spreads, and
a value with `@throwOnFieldError` is not spread inside another value. A
conditional or deferred spread yields an optional value. A view holds a
value only as a parameter of its own initializer, and an operation root
needed as a value spreads one inline fragment. See
[the decision](decisions/a-fragment-has-one-reading.md).
Swift: the value is a `Sendable`, `Hashable` struct, with a nested struct
per link, an array per plural link, and an initializer that takes the
fields; the main thread is the main actor; the caught spread reads a
`Result`.
Kotlin: the value is a `data class`, with a nested data class per link, a
`List` per plural link and a primary constructor that takes the fields;
generated code alone builds one from an anchor, on the store's thread; its
companion has `throwing(anchor)` and `caught(anchor)` as a lens's does, and
the caught spread reads a `Result`.

**Variables.** *Concept: operation value.* GraphQL: an operation's
parameters.
Here: the values an [operation value](#generated) holds. A nullable
variable left unset is absent from the request, or sent as the default the
operation declares for it, never as null.
Swift: the stored properties of the operation value.
Kotlin: the constructor's `val` properties of the operation value, a nullable
one null by default; its `variables` is a `Variables` of `Variable` values,
built with `Variables.of`, which leaves a null out.

## Generated

**Lens.** *Concept: lens.* Baton's word. Relay has two words, fragment
reference and fragment data, for what is one value here; "reader" is
Relay's name for machinery and "view" is SwiftUI's.
Here: the typed, read-only view a fragment or operation root compiles to: a
record reference and a context, its owner, with one accessor per declared
field. An accessor's type follows the schema's: a list whose elements the
schema types nullable reads as a list of optionals, a null element as nil;
a list of non-null elements reports an element it cannot hold, as a scalar
reports a value it cannot hold, and leaves it out; a list of records shows
its records, a null entry having no identity to be keyed by, as a
collection of lenses, and a nullable one as an optional collection, since
the server's null and its empty list differ, with an empty collection for a
view that reads null as empty. See
[the contract](../spec/runtime.md#6-the-lens-reads),
[A fragment is a lens](principles/fragment-is-a-lens.md) and
[A list's null elements are typed as the schema says](decisions/a-lists-null-elements-are-typed.md).
Swift: a list of scalars reads as an array, of optionals where its
elements are nullable; the collection of lenses is `List`, a nullable one
`List?`, and the empty one `List.empty`. A lens is `Equatable` by its
anchor, so a row view whose stored state is a lens conforms in one line and
opts into `.equatable()`.
Kotlin: a `@Stable` class equal by its anchor; a plural link reads as a
`LensList`, a `kotlin.collections.List` that builds each element's lens
from its anchor on access, a nullable one as `LensList?`, and the empty one
`LensList.empty()`. A lazy list keys its items by the record's key, which
every lens carries as `recordID`:
`items(characters, key = { it.recordID.key }) { … }`, so a row keeps its
state while a refetch reorders the list.

**Membership, type condition.** *Composition: plan, record.* Relay: an
inline fragment or spread on an interface or union applies to the records
whose type satisfies it, and a response answers the condition for each
object in an `__isX: __typename` field.
Here: whether a type is a member of a condition is a table by the type's
number, filled from the sets the build compiled and from what responses
say, so a lens tests a record's type with an array load and no hash. A
record of a type the build did not list takes its variant from the answers:
the fields under each condition it satisfies with those every type reads,
settled once per type and per set of conditions; a linked field selected
under two conditions keeps the first's children. The image keeps the
answers for the next launch. A lookup without a type probes the compiled
members. A concrete type's lens under an interface or union sees the
conditions on the interfaces and unions its type satisfies beside it: the
fields `... on Named` selected read through the concrete type's lens as
well, under that condition's `@include` and `@skip`, as Relay's generated
types give each concrete variant every field a matching condition selected;
a type condition nested in the set condition folds in when the concrete
type satisfies it and is left out when it does not, so the fields merge
with the concrete condition's own; the set condition keeps its own lens for
the types the document does not name. See
[the contract](../spec/runtime.md#6-the-lens-reads),
[its resolution](../spec/runtime.md#2-the-plan) and
[its ingest](../spec/runtime.md#3-the-ingest-a-response-to-a-change-set).
Swift: the compiled sets are `Types.Named_possible`; the concrete type's
lens is `asCharacter`, and the set condition's `asNamed`.
Kotlin: the compiled sets are `Types.Named_possible`, a `Members` that
registers its types when the shared file's `Types` is first used and answers
`includes(type)`; the concrete type's lens is `asCharacter`, and the set
condition's `asNamed`.

**Owner.** *Composition: lens, operation value.* Relay: the fragment owner,
the request whose variables a fragment reference is read with.
Here: the scope a lens reads in, one operation's variables or a fragment's
arguments bound over them, carried by the lens's anchor beside its record. A
handle makes one owner and keeps it; a storage key with variables is
resolved once per owner, and a spread with arguments binds its scope once
per owner, so later reads render, hash and allocate nothing. See
[the contract](../spec/runtime.md#6-the-lens-reads).
Kotlin: `Owner`, which settles each key, condition and argument site once
by identity and is read on the store's thread.

**Anchor.** *Composition: lens, record, operation value.* Baton's word.
Relay's fragment reference carries a record id and an owner; an anchor
holds the records themselves.
Here: where a lens reads: its record, its [owner](#generated), and the
record the fragment it is in starts at, its origin, whose id a connection's
pagination and a refetch pass to the fragment's query wherever below it
they read. Two anchors are equal when the three are the same objects. A
handle makes the root anchor its data reads from, as a mutation does for the
data it returns, a fragment spread enters its record as the origin, and
generated accessors derive every anchor below it. Generated code's alone: an
app's code never holds one (see [artifact](#compiler)). See
[the contract](../spec/runtime.md#6-the-lens-reads).
Kotlin: `Anchor`, whose readers generated code calls with a lens's
constructor reference, an enum's `of` and a mapped scalar's converter
where Swift uses static requirements.
Swift: `mutate` makes the anchor of the data it returns.

**Operation value.** *Concept: operation value.*
Here: a value of an operation's variables, compared and hashed by them, the
thing a parent constructs and a navigation path carries. Inside a view a
query value resolves to a handle exposing its phase, its data, a refetch and
a retry, and a subscription value to one exposing its events; the handle
travels with the value its storage hands out. Outside any view the value
is unresolved and reads as loading; in a view outside every environment it
is resolved to no handle and reads as failed with the environment error
that says so, since the absence of an environment is not a session. See
[the contract](../spec/runtime.md#8-the-handle-policies-phase-fetch).
Swift: a `Hashable` struct; the handle exposes `phase`, `data`, `refetch`
and `retry`; the value's `resolution`, generated code's, is a `Resolution`,
unresolved, resolved to the handle, or not injected.
Kotlin: an `@Immutable` class equal and hashed by its variables, a
`QueryOperation`, `MutationOperation` or `SubscriptionOperation`, carrying no
handle; `rememberQuery` resolves it to a `QueryState`, whose `handle` is null
outside every environment and whose `phase`, `fetch`, `refetch()` and
`retry()` read the handle's, and `Environment.handle(operation)` resolves it
outside a composition.

**Operation handle.** *Composition: store, operation value, environment,
phase.* Relay: the query reference a loader hands out, and the request the
environment shares among equal fetches. Relay also calls the code behind
`@connection` and the edge directives handles; here "handle" is only the
operation handle, and an edge directive in a plan is an [edit](#lists).
Here: the live side of a query value, made by the environment and shared by
equal values: a view of its root, which is the store's and holds whether
the data is there, what it deserves and when it was fetched, and of its
[fetch](#runtime), which is the environment's; its [phase](#generated) is
derived from the two, and whether it is refreshing. A subscription's
handle is the same for a subscription: the stream held open as a value,
its events, its last error. See
[the contract](../spec/runtime.md#8-the-handle-policies-phase-fetch),
[the decision](decisions/a-handle-derives-its-phase.md) and
[the verdict's](decisions/the-verdict-is-the-roots.md).
Swift: `OperationHandle`, with `isRefreshing` and `fetchTime`;
`SubscriptionHandle`, whose stream is `stream`.
Kotlin: `OperationHandle<Data>`, whose `phase` and `fetch` are read through
Compose snapshot state, with `isRefreshing`, `isStale`, `fetchTime`, the
suspending `refetch()` and `retry()`; a composable reads the same through
the `QueryState` that `rememberQuery` returns.

**Phase.** *Concept: phase.* Named after `AsyncImagePhase`, the platform's
own word for the same shape.
Here: the state of a resolved operation: loading, ready, or failed. Always
synchronously readable; previous data stays visible while refreshing, and
the handle says a fetch runs behind it: behind ready data, or behind a
failure on field errors or a `@required` null, whose data is in the store,
which a retry leaves in place as a refetch does; after any other failure a
retry shows loading. Derived when it is read and stored nowhere: from the
root, whether the store holds the operation's data and the verdict on it
(what the data deserves by the operation's policies, settled by the store
after a batch that changed a null, a link, an error or a deletion, and when
the data is found or fetched), and from the handle, what the network did,
its [fetch](#runtime). With data the phase reads the verdict and not the
fetch, so a fetch that changed nothing wakes no body that reads it.
Deriving it by a walk at every read was refused on the bench
(`BENCHMARKS.md`, 2026-10-05: 567 µs untracked and 4.56 ms in a body's
tracking scope on the strict fixture); settling the verdict at the commit
and keeping it on the root costs what the stored phase cost. See
[the contract](../spec/runtime.md#8-the-handle-policies-phase-fetch) and
[the decision](decisions/the-verdict-is-the-roots.md), which superseded
[the stored phase](decisions/the-phase-stays-stored.md) in part and
restored [the first decision](decisions/a-handle-derives-its-phase.md) by
another route.
Swift: the handle says it with `isRefreshing`; the retry is `retry()`; the
root's facts are `Store.Root.present` and `verdict`.
Kotlin: the sealed interface `Phase`, `Loading`, `Ready(data)` or
`Failed(error)`, beside the sealed interface `Fetch`; the root's facts are
`Store.Root.present` and `verdict`, snapshot state.

**Action.** *Composition: lens, operation value, environment.* The word
follows SwiftUI's `dismiss` and `openURL`.
Here: a mutation as a callable value: called with one argument per variable
and an optional optimistic response, asynchronous and able to fail, it
returns the mutation's data lens and says whether it is in flight. See
[the contract](../spec/runtime.md#10-the-environment-and-the-wire).
Swift: the arguments are labelled, the optimistic response is
`optimistic:`, the mutation's `OptimisticResponse` builder whose `payload`
the action commits, the call is `async throws`, and `isInFlight` says it is
in flight: `@Mutation("…") var star: StarMutation.Action`. The builder's
own members, `payload` and `variable`, are names a mutation's root field
cannot carry or be aliased to; the compiler refuses the alias at its name,
as it refuses every name generated code reserves.
Kotlin: the action is the runtime's `MutationAction<Op, Data>`, and the call
a generated `suspend operator fun` extension `invoke` on it, one parameter
per variable and `optimistic`, the mutation's `OptimisticResponse`, last
and null by default. A composable takes it from the mutation's companion,
`val rename = rememberMutation(RenameMutation)`, its type inferred: the
companion is a `MutationType<RenameMutation, RenameMutation.Data>`, as a
query's is a `QueryType` and a subscription's a `SubscriptionType`.

## Store

**Record.** *Concept: record.* Relay: a normalized object in the store.
Here: an observable object identified by typename plus key, holding
interned slots and per-field errors. A record of a concrete type the build
never saw takes its variant from the response's own `__isX` answers, as
[membership](#generated) says. Its values are sized by what was written,
not by how many storage keys the type has, and the keys rendered from
variables written to it are kept in a short list apart. A record
`@deleteRecord` removed is *deleted*: links to it read as null, lists skip
it, the bodies that read its fields and those that hold a link to it are
told, and a payload that names it again revives it, told the same way; see
[the contract](../spec/runtime.md#1-types-keys-and-records),
[its deletion](../spec/runtime.md#4-the-commit) and
[A deletion is announced by its commit](decisions/deletion-is-announced-by-its-commit.md).

**Key.** *Composition: schema, record.*
Here: the values of the fields `baton.json` names for the type, after the
typename: `Type:id` by default, `Asset:uuid` for a type configured
otherwise, `Quote:base:quote` for a composite key, each value escaped when
there are several so that no two lists of values meet. The configuration's
`identity` has a `default` list, tried for every object type, and `types`
entries for a type or for an interface, whose implementers take it. A key is
own scalar fields, in order, and does not rename: it is the values at the
write, so a field that changes makes another record; a key through a link
waits for an entity with no scalar key of its own. The compiler selects the
key fields wherever the type is read, as Relay selects `id`, and the plan
names each type's key, so the ingest knows no field by name. Objects whose
fields do not include the key get a path-based client id, as in Relay; under
an interface or union the path ends in the record's concrete type. The
store has no index by id alone, and what names a record by one value, a
lookup without a type (`node(id:)`), `@deleteRecord`, `@deleteEdge` and the
image's forget, reaches single-field keys only: a lookup without a type and
`@deleteRecord` probe `Type:id` for each possible type, and act only when
exactly one live record has the id; an id that names live records of
several types is logged as an ambiguous identity, and nothing is done for
it. A configuration other than the default joins the schema's digest, so an
image keyed another way is a miss and not a merge. See
[the contract](../spec/runtime.md#1-types-keys-and-records) and
[the decision](decisions/identity-is-configured.md).
Swift: the event is `ambiguousIdentity`.
Kotlin: the event is `LogEvent.AmbiguousIdentity`, with the id and the types'
names; a lens carries its record's key as `recordID`.

**Storage key, slot.** *Composition: record, plan.* Relay: a field name plus
its serialized arguments, the key under which a value is stored; an
argument whose value is null is left out, so `notes(first:2)` names the
first page whether or not the document passed `after`.
Here the same: computed by the compiler and emitted as a constant; the
process numbers each key the build names on first use, and a record stores
the value at that number, so a read through a constant hashes nothing. A
key with variables is rendered once per [owner](#generated); the keys a
session renders, one per cursor and per id, are the store's: numbered by
it, apart from the build's, held by the resolutions and scopes that took
them, freed by its collector once nothing can name them and used again, and
forgotten at its end; a record keeps those written to it in a list sorted
by number, so they never widen the records they are not written to. A text
has one slot in a store: a rendering whose text the build names as a
constant takes the constant's slot, and a constant the build names after
the store rendered its text is adopted at the store's next resolution,
check or commit, the two slots becoming twins the store writes together. A
field read through an interface or union reads an *abstract slot*: its
key's slot on each concrete type, resolved on that type's first read. A
report names a slot by its storage key. See
[the contract](../spec/runtime.md#1-types-keys-and-records),
[Slots are numbered by the process](decisions/slots-are-numbered-by-the-process.md)
and [Keys a session produces belong to its store](decisions/session-keys-belong-to-the-store.md).
Swift: the storage key of a slot is `Store.storageKey(of:)`.
Kotlin: a slot is a `Slot`, a type and an index; the build's constants are
`Slots.<Type>.<field>`, interned by `Registry.slot(type, storageKey)`, a key
with variables a `DynamicKey`, and an abstract slot an `AbstractSlot` under
`AbstractSlots`; the storage key of a build's slot is
`Registry.storageKey(slot)`, and one the store numbered is named by the
store's keys.

**Invalidation channel.** *Concept: record.* Baton's word; Relay tells a
fragment's subscribers when a record it read changes.
Here: what a read of a slot registers on and only a change of that slot
notifies, so a body is invalidated by a change to a field it read of a
record it read, and by nothing else. See
[the contract](../spec/runtime.md#6-the-lens-reads) and
[what it leaves to a runtime](../spec/runtime.md#11-what-is-not-the-contract).
Swift: an Observation key path, one per slot index and shared by every
record.
Kotlin: a channel beside the cell, Compose snapshot state made when the
slot is first read and bumped by a write that changes it; a slot nobody
read has none.

**Store.** *Concept: store.* Relay's word.
Here: all records, retained roots and lifetime state; owned by the main
thread; read synchronously; written by atomic commits. See
[the contract](../spec/runtime.md#4-the-commit) and
[The store is the UI's state](principles/store-is-the-ui-state.md).
Swift: the main thread is the main actor, which owns the store.
Kotlin: the store belongs to the thread that made it, and its entry points
check the caller's.

**Commit, change set.** *Composition: store, plan.*
Here: a change set is the output of ingesting one response or applying one
optimistic update: records, slots, references, errors, and the edits the
plan asked for (a connection page's merge, an edge directive's insert or
delete). A commit applies it on the main thread as a *batch*: the
transaction that nets the notifications, the undo log of what changed, and
a kind. A *server* batch is written to the image; an *optimistic* one keeps
its undo with its layer and the image is not told; a *local* one, the
runtime's own writes, a page's loading flag, a lookup's link bound, a link
repaired, a cell filled from the image, neither. Nothing outside a batch
writes a record, edits follow entries, and the observed fields that changed
are notified when the batch ends. See
[the contract](../spec/runtime.md#4-the-commit).
Swift: the commit runs on the main actor.
Kotlin: the commit runs on the store's thread, through the environment's main
dispatcher; the change set and the batch, with its kind, are the runtime's
internal `ChangeSet` and `Store.Batch`, and the log tells a commit as
`LogEvent.Committed`, with its kind and the slots it changed.

**Payload.** *Composition: operation value, plan.* Relay's word, from
`commitPayload`; GraphQL calls the whole a response. The response is the
oracle, and this is the thing a response is.
Here: bytes in a response's shape, the one thing the door from outside the
store takes: a server's response, an optimistic response the generated
builders render, a payload committed by hand. A payload keeps a scalar's
text as written. See
[the contract](../spec/runtime.md#3-the-ingest-a-response-to-a-change-set)
and [the decision](decisions/a-payload-is-bytes-in-a-responses-shape.md).
Swift: `Payload`, over `Data`, with `init(json:)`; `commitPayload` and
`mutate(_:optimistic:)` take one, and a mutation's `OptimisticResponse`
builder renders one as `payload`.
Kotlin: `Payload`, over a `ByteArray`, with a constructor from a JSON
`String`, equal by its bytes; `commitPayload` and `mutate(operation,
optimistic)` take one, and a mutation's `OptimisticResponse` renders one as
`payload`.

**Commit payload.** *Composition: store, plan, operation value,
environment.* Relay: `commitPayload`, writing a response for an operation
that some other road delivered.
Here: a commit payload runs the operation's plan over a payload in a
response's shape, with the ingest, the commit and the image a fetch has,
through the same door: the one way for data from outside the transport, a
REST response, a socket's tick, a preview's fixture, a test's seed. A
payload may carry part of what the operation selects, and it alone writes
[client fields](#compiler). See
[the contract](../spec/runtime.md#3-the-ingest-a-response-to-a-change-set)
and [the decision](decisions/client-data-is-described-and-committed.md).
Swift: `Environment.commitPayload(operation, payload)`.
Kotlin: `Environment.commitPayload(operation, payload)`, a `suspend` function
run on the main dispatcher whatever thread calls it; under
`@throwOnFieldError` it throws `FieldErrors`.

**Root, retain, release buffer.** *Composition: store, operation value,
environment.* Relay's words.
Here: a root is an operation's selection and the record it starts from,
kept by the store with how many hold it; a record lives while a root
reaches it. Retaining a handle returns a *retention*, a token whose end
releases; a view holds one for its life. A released root waits in the
store's release buffer, ten by default, oldest out first, before its
records become collectable; a root pushed out takes its handle and the
fetch it had in flight with it. A completed mutation's payload is a root
apart from the buffer, one per operation value (its name and variables) and
as many as the buffer holds, so mutations push no released query out. The
store collects when a root left or a commit dropped a link, once per turn
of the main thread, and marks from the roots, the optimistic layers and the
image's write queue, and from nothing else. See
[the contract](../spec/runtime.md#7-the-lifetime-roots-retention-ages-collection)
and [the decision](decisions/the-store-owns-roots-and-ages.md).
Swift: `retain()` on a handle returns a `Retention`: `@Query`'s storage
holds one for the view's life, a model or a view controller holds one in a
property and lets it go with itself. The buffer's size is
`Store(releaseBufferSize:)`. The main thread's turn is the main actor's.
Kotlin: `retain()` returns a `Hold` whose `release()` ends it, since
Kotlin has no deinit to end it. The class is not named `Retention`, since
`baton.Retention` would hide `kotlin.annotation.Retention` from every file
that writes `import baton.*`. The buffer's size is the environment's
`releaseBufferSize`, and the turn is the main dispatcher's.
`rememberQuery` holds one while its composable stays and releases it when
the composable leaves or its composition is abandoned.

**Invalidation, TTL.** *Composition: store, operation value, environment.*
Relay's and Apollo's shared words.
Here: an invalidation of the environment marks every fetched operation
stale and refetches the retained ones whose holders allow the network; an
operation's [cache expiration](#documents), or the store's default, does
the same by age. A revalidation of the environment refetches the retained
operations that are stale or whose last fetch failed, where a holder allows
the network, and marks nothing: for an app's return to the foreground or a
connection regained. Stale data stays readable. An invalidation also
forgets the image's fetch times, so it outlives the launch. The age is the
root's, kept by the store and stamped by the commit of every response, a
handle's fetch, a refetch, a page, the environment's own fetch or a commit
payload, whoever asked for it, and persisted as the image's fetch time; a
handle reads it as its fetch time. Data with no known age is stale wherever
an expiration applies, in memory as from the image. See
[the contract](../spec/runtime.md#7-the-lifetime-roots-retention-ages-collection),
[the decision](decisions/the-store-owns-roots-and-ages.md) and
[the revalidation decision](decisions/revalidation-is-the-apps-call.md).
Swift: `Environment.invalidate()` and `Environment.revalidate()`; the
stamping fetches include `Environment.fetch` and `commitPayload`; the
handle reads the age as `fetchTime`.
Kotlin: `Environment.invalidate()` and `Environment.revalidate()`; the
stamping fetches include the suspending `Environment.fetch` and
`commitPayload`; the handle reads the age as `fetchTime`, a `TimeMark?`, and
staleness as `isStale`.

**Persistence, image.** *Concept: store.* Baton's words; Relay's store lives
in memory.
Here: the image is the store's records in one SQLite file, written behind
every commit of server data, off the main thread: a row per record, the
query root a row per field, each operation's fetch time. A row is replaced
by a commit's snapshot of the record when the check has read the row into
memory; the snapshot of a record memory has not read is merged into the
row, so a response with a few of a record's fields leaves the rest for the
next check. Optimistic layers never reach it. It is a cache: an image of
another format, version or protection class and a corrupt one are deleted
and started again; a cell held under a kind the schema since gave its
field another reads as absent and is fetched again, so a schema change
needs no version of its own; one over its size limit evicts the rows of launches
before the last, then the last launch's, and starts again only when nothing
is left to evict ([the decision](decisions/the-image-evicts-by-launch.md));
a record that goes a whole launch unread is dropped at the next, and the
names no row uses go with the rows. An image is made for one store and
lives as long as it: the environment's end closes it and gives the file
back for good, so that nothing the ending store commits or reads after
reaches the file, and the next environment makes its own, on that file or
another; the image that takes a file over counts as a launch, though the
process is the same, so the rows the closed one wrote that it does not read
age out a launch sooner. One image in a process holds a file; a second made
on it runs without it. The file is made with the protection class the
persistence names, or its directory's default, which Apple's SQLite gives
the file and its log. A file that cannot be taken, locked or full, is
waited for, not discarded: the writer keeps its work for the next commit or
read, a read meanwhile misses, and work that outgrows 50,000 rows is
dropped and the image started again. What keeps one account's rows from the
next is the account in the image's path or in its version; removing the
file after the end is hygiene, under a marker that has the next open finish
a deletion a crash interrupts. See
[the contract](../spec/runtime.md#9-the-image),
[the decision](decisions/an-image-belongs-to-one-store.md) and
[the file's](decisions/the-images-file-is-protected-and-waited-for.md).
Swift: `Persistence(url:)` or `Persistence(name:)`, handed to
`Store(persistence:)`; the version is `version`, the protection class
`Persistence(protection:)`, and the removal `removeAll()`.
Kotlin: `Persistence(path)` or `Persistence.named(name)`, handed to
`Store(persistence)`, with `version`, `sizeLimit`, `flush()`, `close()` and
`removeAll()` as in Swift and no protection class.
Kotlin: the image is the same tables and rows written through the AndroidX
SQLite driver API, on the platform's SQLite, or on the JVM the engine that
target bundles.
Kotlin: on Android the runtime holds no `Context`, so an image named is
placed by the app: `Persistence.named(name, directory = cacheDir.path)`;
without a directory the call throws.

**Hydration.** *Composition: store, plan.* The web's word for filling a
client's state from stored data.
Here: the availability check reading from the image what memory lacks, a
record's row once and a root field's row, so an operation an earlier launch
fetched is ready when its handle is made, before the first body. Memory wins
wherever it holds a value. The operation's age comes with its data; data
that needed the image and has no fetch time is stale. See
[the contract](../spec/runtime.md#5-the-availability-check-and-hydration).

**Optimistic layer.** *Composition: store, plan, operation value.* Relay's
optimistic update, applied as a layer that is rebased on each commit.
(Relay says "optimistic update"; the layer is what makes the rebase
explicit.)
Here: a typed optimistic response ingested like a server response and
applied with an undo log; a commit under live layers lifts them, applies
the payload, re-applies them, and notifies only slots whose value differs
in the end. The server's answer replaces the layer; a failure reverts it.
See [the contract](../spec/runtime.md#4-the-commit).
Swift: the typed response is `OptimisticResponse`.
Kotlin: the typed response is `OptimisticResponse`, a class nested per
selection set whose constructor parameters all default to null, an absent
field leaving the store untouched; its `payload` is what the action
commits. The store stages a netted batch's writes and writes into a cell
only the value that differs at the batch's end, since a Compose state
written and written back still tells its readers.

**Mutation root.** *Concept: record.*
Here: the record mutation payloads hang off, `client:root:mutation`, beside
the query root. Entities inside a payload merge into their own records as
always. Its fields are keyed without their arguments, `addNote` rather than
`addNote(text:"…")`, and an aliased one by its alias, `addNote(as:"first")`:
the caller reads a payload once, and a key per input would number a slot
for every call. The three root records are typed `Query`, `Mutation` and
`Subscription` whatever the schema calls its root types, as Relay's root
record is a `__Root` in any schema: the compiler interns a `QueryRoot` or a
`query_root` by the store's name. See
[the contract](../spec/runtime.md#1-types-keys-and-records).

**Abstract selection.** *Composition: schema, document.*
Here: a selection on an interface or union. The compiler adds
`__typename`; the ingest keys the object by the concrete type the payload
names and resolves slots against that type; a lens exposes an accessor per
concrete type and conditional spreads. Relay's rule holds: a spread inside
an inline fragment on an abstract selection carries `@alias`. See
[the contract](../spec/runtime.md#3-the-ingest-a-response-to-a-change-set).
Swift: the accessors are `as<Type>`.
Kotlin: the accessors are `as<Type>`, each a nullable getter of a nested
`As<Type>` lens class, null when the record is of another type.

**Field error.** *Composition: record, plan.* GraphQL: an entry of a
response's `errors` with a `path`.
Here: resolved by the ingest to the record and slot the path names and
stored beside the field, its message and dotted path; a payload that
answers the field clears it; either change notifies the field. Read through
[catch](#documents) and [throw on field error](#documents); a plain read
sees null. A response with errors and no data is a
[request error](#runtime), a failure of the fetch. An error keeps its
`extensions`, as a JSON value beside its message and path, in memory and in
the image, so an app branches on the server's code and never on its
message: see
[the contract](../spec/runtime.md#3-the-ingest-a-response-to-a-change-set)
and [A failure says its kind](decisions/a-failure-says-its-kind.md).
Swift: the stored error is `FieldError`; the fetch's failure is
`GraphQLErrors`; the extensions are a `Variable`.
Kotlin: the stored error is `FieldError`, a data class of `message`, `path`
and `extensions`; the fetch's failure is `GraphQLErrors`; the extensions are a
`Variable`; an uncaught one is logged as `LogEvent.FieldError`.

**Heal.** *Composition: store, operation value, environment.* Baton's word
for the response to missing data: record the event, mark the owning
operation stale, refetch. See [Honest data](principles/honest-data.md).
Here: a read that finds a slot the store never received logs it as missing
and tells its owner's environment, which marks the owner's root stale and
refetches it if a holder allows the network, once per fetch of that root; a
field still missing after the heal's own refetch is logged as unexpected and
healed no further. A lens made by hand has no root and is logged, not
healed. A value the generated type cannot hold, a null in a field typed
non-null or a value of another kind, is logged as unexpected; it is not a
miss, so nothing heals it. See
[the contract](../spec/runtime.md#7-the-lifetime-roots-retention-ages-collection).
Swift: the events are `missing` and `unexpected`.
Kotlin: the events are `LogEvent.Missing` and `LogEvent.Unexpected`, each with
the type and the field; an environment made with `debug = true` prints them
until a log is set, since common Kotlin has no build configuration of its own.

## Compiler

**Schema.** *Concept: schema.* GraphQL: the SDL.
Here: a checked-in file, named in `baton.json`, with the
[identity](#store) configured beside it; the compiler has no introspection
command, and the file is downloaded by the app's own tooling. One schema
family per process: the registry numbers types and slots by name for the
whole process, so two environments over one schema share them, and two
schemas in one process must not give two types one name
([the decision](decisions/slots-are-numbered-by-the-process.md)).

**Client schema extension, client field.** *Concept: schema.* Relay:
`schemaExtensions`, files that give server types client fields or declare
types the server does not have.
Here the same key in `baton.json`, files or directories of `.graphql` beside
it, read with the schema and folded into its digest. A client field is
nullable, since no server promises it; it is written by a
[commit payload](#store) for an operation that selects it and by nothing
else, read by a lens like any field, left out of the text and the id a
server receives, and neither waited for by the availability check nor
healed: the registry marks a client slot, so a lens reads it as absent until
a payload writes it and reports nothing missing. An operation of client
fields alone is refused, since a server answers one field at least. The
plan marks each client field, the origin a walk reads beside the server's
and a `@defer` label's; the check hydrates client fields from the image
without waiting for them. Client records live and reach the image as any
record does. Baton computes none: no resolvers. See
[the contract](../spec/runtime.md#2-the-plan) and
[the decision](decisions/client-data-is-described-and-committed.md).

**Custom scalar, mapped scalar.** *Composition: schema, lens.* GraphQL: a
scalar the schema declares beside the built-in five.
Here: stored as its text, exactly as the server wrote it, and read as a
string; or, mapped under Relay's key `customScalarTypes` to a type of the
app's that conforms to the runtime's mapped scalar, read as that type,
converted from the text at the read and never cached on the record. The
configuration names the host type per language: a value is one type's
name, or an object by language; the plan carries the scalar's name alone,
and each language's writer resolves its type
([the decision](decisions/a-mapped-scalars-host-type-is-named-per-language.md)). The
runtime's decimal, date, URL and UUID conform, each with one format: the
POSIX locale, ISO 8601's internet profile with or without fractional
seconds. The accessor says the conversion can fail: it is optional wherever
the schema puts the field, unless a directive says what a failure does.
`@required` and `@throwOnFieldError` make it non-optional and throwing,
since a value that does not convert has no zero to read as; under
`@required(action: NONE)` or `LOG` the lens is unsatisfied as a null would
leave it. `@catch` makes it a result whose failure carries the conversion's
error, under the field's path. A value that does not convert is reported as
unexpected, never as missing, and never reads as a zero value; an element of
a list that does not convert is reported once, left out of a list of
non-null elements as an element the list cannot hold is, and read as nil in
a list of nullable elements. There is no raw accessor beside the mapped
one. A variable of a mapped type takes the mapped type and is sent as its
text. See [the contract](../spec/runtime.md#6-the-lens-reads),
[the first decision](decisions/a-mapped-scalar-is-a-fallible-read.md) and
[the second](decisions/a-mapped-scalar-converts-at-the-read.md).
Swift: an unmapped scalar reads as a `String`; a mapped one names a Swift
type conforming to `MappedScalar`, which `Decimal`, `Date`, `URL` and
`UUID` do, as the configuration's string or its `swift` entry; `@catch`
makes it a `Result`; a variable takes the Swift type.
Kotlin: a mapped one names, under its `kotlin` entry, the Kotlin type it
reads as and the `object` implementing `ScalarConverter` for it, since the
runtime cannot extend a type it does not own; a variable takes the type and
is sent through the converter.

**Enum.** *Composition: schema, lens.* GraphQL: a type with a closed set of
named values.
Here: stored as its text, as a custom scalar is, and read as an enum
generated for it, with a case per value the build knows and an unknown case
carrying the text for one it does not, so a value the schema gained after
the build reads as itself rather than failing the read; Relay's generated
types carry `%future added value` for the same reason. The conversion
cannot fail, so the accessor keeps the schema's nullability; a null on a
non-null field reads as the unknown case with an empty text and is
reported, as any value a type cannot hold is. A variable of an enum type
takes the enum and is sent as its text. The enum is declared once per
module in the shared file, named as the schema names it; a schema enum
named like a fragment or an operation is a name error at the document. See
[the contract](../spec/runtime.md#6-the-lens-reads) and
[the decision](decisions/an-enum-reads-as-a-generated-enum.md).
Swift: a Swift enum, whose unknown case is `unknown(String)`, a null
reading `unknown("")`; a schema enum named like a shared enum or the
standard library's types takes `Enum` after its name.
Kotlin: a sealed interface with a `data object` per value, keeping the
schema's spelling, and the unknown case `data class Undeclared(scalarText)`,
a null reading `Undeclared("")`; not `Unknown`, which a value `UNKNOWN`
would share a class file with on a file system that ignores case, so a
value spelled `Undeclared` in any case takes an underscore.

**Transient.** *Composition: schema, image.* Not a Relay word, since
Relay's store is not persisted; borrowed from the ordinary sense of what
does not outlive its process, over *ephemeral*, which says short lived
rather than unwritten, and *volatile*, which names a kind of memory.
Here: what never reaches the image, decided at build time in
`baton.json`'s `transient` block like identity and lookups: the records of
the types named (an interface's entry names its implementers), and the
cells, storage keys and fetch stamps of the root fields named,
`Query.search`, since a root field's key carries the arguments it was asked
with and an operation's stamp carries its variables. A record's slot that
links to a transient record is left out of its row, so nothing on disk
names one; the next launch misses on it and fetches, as the owner's rule
has it: a list is never shortened to fit, and a screen that shows transient
records refetches at launch. Memory is unaffected: the store keeps the
records as long as a retention reaches them. The shared file declares the
lists once, and every plan of the module names them, so the registry knows
them before any plan writes a row. The lists join the schema's digest, so
an image written under another list starts again. See
[the contract](../spec/runtime.md#9-the-image) and
[the decision](decisions/what-may-reach-the-image.md).
Swift: the shared file's lists are `Types.transient`.
Kotlin: the shared file's lists are `Types.transient`, a `Transient` whose
construction marks the registry, each type also interned with
`Registry.type(name, transient = true)`; every plan names it, `Plan(root,
transient = Types.transient)`.

**Input object.** *Composition: schema, operation.* GraphQL: a type of
named fields an argument or variable takes.
Here: a value type generated per input object the documents' variables
name, declared once per module in the shared file, with a field per field
typed as the schema types it, a scalar, an enum, a mapped scalar, a nested
input or a list of one, optional unless non-null, built with a value per
field. A variable of the type takes the value, so a misspelled field is a
compile error where it was a server's error before. A field left unset is
absent from the request, as GraphQL distinguishes absent from null; a
document that must send an explicit null for a field writes it as a
constant in the document. The value renders the object the request
carries, as an optimistic response's builder renders itself; it compares
and hashes, since an operation value compares and hashes its variables.
Named as the schema names it. A field whose type contains the input itself,
`input Filter { not: Filter }`, is boxed, since a value type cannot hold
itself; the value reads and writes it as any other field.
Swift: a struct, with a property per field, nil for a field left unset, and
an initializer with a parameter per field; its `variable` is the object the
request carries; it is `Hashable`. One named like a shared enum or a
standard library type takes `Input` after its name, and a field named
`variable` takes an underscore. The box is `Baton.Indirect`.
Kotlin: a `data class` implementing `InputObject`, with a `val` per field,
null by default where the schema allows it, equal by its fields; its
`variable` is the object the request carries. One named like a runtime or
standard library type takes `Input` after its name, and a field named
`variable` or `copy`, `componentN`, or `Variable` or `Variables`, which the
rendering spells, takes an underscore. There is no box: a class holds a
reference to its own type.

**Plan.** *Concept: plan.* Baton's word for the normalization artifact.
Relay's normalization AST, renamed because it is data, not a tree the
runtime walks generically.
Here: the data a response is decoded by and a store is written from, one
per operation, emitted by the compiler and interpreted by the runtime. See
[the contract](../spec/runtime.md#2-the-plan).

**Persisted id.** *Composition: document, transport.* Relay and the GraphQL
community's word for the hash a server accepts in place of operation text.
Here: under Relay's `persistConfig` in `baton.json`, `file` and `algorithm`
(`MD5`, `SHA256` or `SHA1`), an artifact carries the id, the text's hash in
lowercase hexadecimal, and no text, and `batonc generate` writes the file,
Relay's map from id to text with the ids in order, beside the configuration
when run by hand, into the build's output directory under the build
plugin, or where a build names it with `--persisted`; without
`persistConfig` the artifact carries the text and no id. So
the build decides what a request carries, the operation's document says
which, text or id and never both, and no transport has a mode or a
fallback. The standard encoding writes an id as `documentId`, after the
GraphQL over HTTP working group's proposal. See
[the contract](../spec/runtime.md#10-the-environment-and-the-wire) and
[the decision](decisions/an-operation-is-sent-as-text-or-id.md).
Swift: the build plugin is SwiftPM's; the operation's document is
`document`.
Kotlin: the build plugin is Gradle's, `com.shergin.baton`, whose task's
`persisted` property places the file through `--persisted`; the operation's
document is the companion's `document`, a `Document.Id` or a `Document.Text`,
and the standard `Encoding` writes an id as `documentId`.

**Artifact.** *Composition: document, lens, plan.*
Here: everything the compiler emits for one source file: lens types, plans,
ids. It is written against the runtime's interface for generated code:
anchors and owners, the numbers of types and slots, the registry, the plan
types, and the anchor and initializer of every lens. That interface has a
format with a number, which the target's shared file names and the runtime
declares, so generated code of another format fails to compile at that one
line. An app's own files see lenses, handles, the environment, the log,
transports and persistence; records, values, slots and type ids are the
interface's.
Swift: an artifact opens with `@_spi(Generated) import Baton`, which is that
interface; the shared file names the format as `Types.format` and the
runtime declares it as a marker type; an app's own files import `Baton`.
Kotlin: an artifact opens with `@file:OptIn(baton.Generated::class)`, which
is that interface; the Kotlin format has numbers of its own, starting at 1,
and the shared file names it as `Types.format`, the runtime's marker object
`baton.Format2`.

**Report.** *Composition: document, schema.* Baton's word.
Here: what the compiler compiled for one target, written by
`batonc generate --report` as JSON and, under SwiftPM's plugin, into the
build's output directory as `Baton.report.json`: the schema's digest; every
operation with its name, kind, source, id when persisted, variables as the
schema types them, the fragments it reaches directly or through other
fragments, its text and its lens; every fragment with its name, type
condition, source, the operations that reach it, its definition as the
author wrote it, printed before the transforms, and its lens. A lens is
listed as the target's language reads it: each accessor's name, the
response key it reads, and its shape, whether it reads absent, a `@catch`
result, a throwing read or a list, and the nested lens it reads; see
[the lens decision](decisions/the-report-holds-each-lens.md). Deterministic, by name, with
sources relative to the working directory, so the diff of two builds'
reports is the contract's change. `validate`, `print` and
`generate --check` are the same compilation with another output, and
[the command's contract](recipes/batonc.md) states all of them. The
persisted documents file is a second view of the same facts, and a
dependent target's compilation is what the fragment's definition is there
for; see
[the decision](decisions/the-report-is-what-a-dependent-target-reads.md).
Swift: the build plugin is SwiftPM's.
Kotlin: the build plugin is Gradle's, `com.shergin.baton`, whose
`generateBaton` task writes the report through `--report` to its `report`
property, `build/baton/<task>/report.json` by default.

## Runtime

**Log.** *Concept: environment.* Relay's word for the function an
environment is given and calls with each event of its work (`LogEvent`);
#15 asked for it as an event sink.
Here: the environment's log, a function of a value-free event, a set of
names and counts, never a record, a slot, a value, a variable or a response
body, so an app routes it to its logging and metrics without logging
anything a user typed. The cases are the fetch (started, completed with its
duration, failed with its failure's kind), the commit (its kind and the
slots it changed in records that existed), a field error a fetch's response
carried that no `@catch` handled, by operation and response path, the image
(opened, unavailable, written, failed), a deferred part dropped for naming
a place the store or the plan does not have, and missing data (a field read
and never fetched, a value a reader's type cannot hold, an id naming records
of several types, a `@required(action: LOG)` field that is null), each by
type and field name. Debug builds print the missing-data cases until a log
is set; a test sets none. See
[the contract](../spec/runtime.md#10-the-environment-and-the-wire) and
[the decision](decisions/the-environment-logs-value-free-events.md).
Swift: `Environment.log`, a closure of `LogEvent`, a value-free enum; a
test sets `log = nil`.
Kotlin: `Environment.log`, a function of `LogEvent`, a sealed interface of
data classes; nothing is printed until it is set.

**Environment.** *Concept: environment.* Relay's word for store plus network
plus configuration. Chosen over "client" (Apollo's word) by
[Relay's words](principles/relays-words.md).
Here the same, injected through the UI framework's environment. A request
with nothing to send it fails with an environment error, which says what is
missing: the view's environment, the lens's, the one that made a handle and
is gone, or the subscription transport. A view outside every environment
gets no handle and no store stands in for the missing one: its value reads
as failed, and a mutation action in it throws the same error. See
[the contract](../spec/runtime.md#8-the-handle-policies-phase-fetch).
Swift: injected through SwiftUI's environment as `\.baton`; the error is
`EnvironmentError`, and the view's case is `notInjected`.
Kotlin: `Environment`, which commits on a main dispatcher, the store's
thread, and reads responses on an ingest dispatcher, a test passing one
test dispatcher for both; the error is `EnvironmentError`, and the
composable's case is `NotInjected`. A composition reads it from
`LocalBaton`, provided with `CompositionLocalProvider`; on the JVM,
`Environment(url, headers, subscriptions, store)` makes one over an
`HttpTransport`, on the thread its main dispatcher runs.

**Session, end.** *Concept: environment.* The web's word for one identity's
stretch of use; Relay has no word for an environment's end, because
JavaScript collects one nobody holds.
Here a session is the life of one environment, not a type: an environment
pairs a store with the transport that fills it and replaces neither, a
sign-in makes one and a sign-out ends it, and which one is current is the
app's state. Ending the environment ends it, once and for good: it cancels
every fetch and stream the environment started, drops the roots, clears
every record and closes the image, giving its file back. An ended store
commits nothing, checked at the one door a payload takes, so a response
that lands later reaches neither memory nor the image; a handle still held
reads failed with the environment gone and tells its observers, a lens still
held finds its records cleared, and every later call on the environment
fails with the same error. The order of a sign-out is the app's: end the
environment, remove the image, forget the credential last. See
[the contract](../spec/runtime.md#7-the-lifetime-roots-retention-ages-collection)
and [the decision](decisions/the-environment-is-the-session.md).
Swift: the end is `Environment.end()`; a handle still held reads
`.failed(EnvironmentError.gone)`. A store dropped without an end clears its
records when it is deallocated: the net, not the end.
Kotlin: the end is `Environment.end()`, a `suspend` function, and `ended` says
it happened; a handle still held reads `Phase.Failed(EnvironmentError.Gone)`.
Kotlin has no deinit, so there is no net: a store dropped without an end is
the garbage collector's, and only the end closes its image.

**Transport.** *Concept: transport.*
Here: what HTTP, multipart incremental delivery and the socket live behind,
with one verb: a request yielding a stream of payloads, one for a query, the
parts of a deferred response, the events of a subscription, so a wrapper
wraps one method whatever the operation's kind; a second reads the one
payload of a request that answers once. A request says its kind, query,
mutation or subscription, so a wrapper never retries a mutation a server may
have received, and carries the operation's document, text or id. One
function, an encoding, turns a request into the JSON a server receives, for
the HTTP body and the socket's subscribe payload alike; the standard one
writes `operationName`, `variables`, `onError` when set, and `query` for a
text or `documentId` for an id, and a server with another convention
replaces the function on the built-in transports and keeps them. The
built-in transports read credentials per attempt, from a function, so a
rotated token reaches the next request or connection. In Kotlin the socket
transport speaks its protocol over a WebSocket client the platform or an
edge supplies, the JVM's own or OkHttp's through `baton-okhttp`, which
also brings an HTTP transport over OkHttp; the pieces a transport over
another client needs, what a request accepts, the request errors of a
body and the two parsers, are public. The built-in HTTP
transport reads `multipart/mixed` for a deferred response and
`text/event-stream` for a subscription, `graphql-sse` in its
distinct-connections mode, one response per operation whose `next` events
carry payloads and whose `complete` ends it, so the environment's
subscription transport may be an HTTP transport; the socket transport speaks
`graphql-transport-ws` for subscriptions and any operation sent over the
socket; two parsers split the parts and the events. The single-connection
mode of `graphql-sse` waits for a gateway that cannot do HTTP/2. A response
outside 2xx fails with the transport error, its HTTP status and body,
unless its media type is `application/graphql-response+json` and its body
is errors and no data: a server of the GraphQL-over-HTTP specification
answers a [request error](#runtime) so, with a 4xx or 5xx status, and the
transport fails with that request error instead; a socket that closed
under a subscription, a recorded transport with nothing recorded and a
transport that delivers no payload fail with one of status 0, which says
what went wrong. That error stays the built-in transports'
error, and is carried unchanged inside the transport's kind of
[failure](#runtime), as the platform's URL error or an app's own
transport's error is. What a production endpoint needs beyond the built-in
transports, one replay of an authorization challenge, a bounded retry with
backoff, a deadline across the attempts, is a wrapper over the one verb the
app owns, not a library type; [the exchange recipe](recipes/exchange.md)
walks through the one the GitHub sample sends through. See
[the contract](../spec/runtime.md#10-the-environment-and-the-wire).
Swift: the `Transport` protocol, whose verb is `send` and whose `payload`
reads the one payload; the request is a `Request`, the encoding an
`Encoding`, the credentials a closure. `URLSessionTransport` speaks HTTP;
`GraphQLTransportWebSocket` speaks `graphql-transport-ws`;
`MultipartParser` splits the parts and `EventStreamParser` the events. The
environment's subscription transport is `subscriptions`. The transport
error is `TransportError`, and the platform's URL error `URLError`.
Kotlin: the `Transport` interface, whose `send` returns a `Flow<ByteArray>`
and whose `payload` reads its one element; `Request`, `Encoding` and
`TransportError` as in Swift, and the test transports `ScriptedTransport`,
`RecordedTransport` and `SilentTransport` in the module `baton-testing`.
`MultipartParser` and `EventStreamParser` are common; `HttpTransport`
speaks HTTP over `java.net.HttpURLConnection`, which Android shares; and
`GraphQLTransportWebSocket` speaks `graphql-transport-ws` over the JVM's
`java.net.http.WebSocket`, which Android's platform lacks, so there the
socket is the app's own transport.

**Inspector.** *Composition: store, record.* Baton's word.
Here: the view a debug build presents over an environment's store: its
counts, its records by type, each record's slots with their values and field
errors, and an export in the dump format `spec/` freezes, so a bug report
can become a fixture. It reads and never writes: no provenance per slot, no
action that evicts. It lives in a product of its own, so a release build
need not link it.
Swift: `StoreInspector`, in the product `BatonInspector`; the export is
`StoreExport.text(of:)`.
Kotlin: the composable `StoreInspector(environment)`, in the module
`baton-inspector`; the export is `StoreExport.text(store)`. It is live: it
reads the store's revision, snapshot state that moves with every batch and
collection, and the records' cells, so a commit recomposes it.

**Recorded transport, scripted transport.** *Concept: transport.* Baton's
words.
Here: a recorded transport answers from recorded responses by operation
name, or from a function of the whole request, and keeps the requests it
was sent; for previews, tests and benchmarks. A scripted transport does the
same and more for an app's tests: it holds a mutation, or any operation the
test names, until the test replies or refuses, so the window between an
optimistic apply and the server's answer can be observed; it drives a
subscription's events by hand, delivering, completing or failing; and it
lists its requests by kind. An operation with no answer scripted fails with
a status 0 that says so. Beside them, a silent transport never answers, for
a first body with no network behind it, and a wait waits for a handle or a
store to settle. Not mocks: each is a transport like any other, and nothing
behind it can tell. All live in a product of the package that an app's
tests and previews import and its shipping binary does not; see
[the decision](decisions/one-runtime-module.md).
Swift: `RecordedTransport`, `ScriptedTransport` and `SilentTransport`; the
wait is `wait(until:)`; the product is `BatonTesting`.
Kotlin: `RecordedTransport`, `ScriptedTransport` and `SilentTransport`, in the
package `baton.testing`; a scripted transport's `hold` and `drive` name the
operations it holds and drives, `held` lists what `respond` or `refuse`
answers, `driven` what `send`, `complete` or `fail` delivers, and
`requests(kind)` lists its requests by kind; the wait is the suspending
`wait(until, timeout)`; the module is `baton-testing`, for the JVM and
Android.

**Subscription.** *Composition: store, operation value, transport.*
GraphQL: an operation whose events arrive over time.
Here: a view's subscription is open while the view lives and closed when it
goes; the handle exposes its events, the latest, the error, the count of
resumptions and the stream, the stream as a value: idle, or parked while the
environment is inactive; connecting until the first event; open; waiting to
reconnect, until the instant the handle opens it again after a
[failure](#runtime), by a fixed backoff, a step doubling from one second to
thirty and jittered to between half and the whole of it, reset by an event;
or ended, by the server's completion, by a request error (the server's
refusal of the operation, which a retry would repeat) or by the
environment's end. It is active when connecting or open; a retry opens a
waiting or ended stream at once. The resumptions count the stream's
reopenings, after a failure's wait or the environment's inactivity, since
events may have been missed across each: an owner observes the count and
refetches its baseline, with no callback. The environment's active flag,
set by the app, parks every retained subscription while false and resumes
them when true. Not a phase: a subscription has no data of its own to wait
for, so it has no loading. Each event is normalized at the subscription
root (`client:root:subscription`) and committed, so edge directives on its
payload work. The environment's subscription transport carries them,
through the one verb every [transport](#runtime) has. See
[the contract](../spec/runtime.md#8-the-handle-policies-phase-fetch).
Swift: `@Subscription("…")` expands like `@Query`: its storage subscribes
while the view lives and closes the stream when it goes. The handle exposes
`events`, `latest`, `error`, `resumptions` and `stream`; `isActive` is
connecting or open; `retry()` opens the stream. The environment's
`isActive` is set from the app's scene phase; its `subscriptions`
transport carries the events, and `GraphQLTransportWebSocket` speaks
`graphql-transport-ws`.
Kotlin: `Environment.subscriptionHandle(operation)` returns a
`SubscriptionHandle<Data>` whose `events`, `latest`, `error`,
`resumptions` and `stream` are snapshot state, the stream a sealed
interface `Stream` (`Idle`, `Connecting`, `Open`, `Waiting(until)`,
`Ended(failure)`), and whose `retain()` opens it; a composable holds it
with `rememberSubscription(operation)`, whose `subscription` is the handle.

**Error behavior.** *Composition: schema, lens, transport.* The GraphQL
spec's `onError` request parameter (`PROPAGATE`, `NULL`, `ABORT`).
Here: `"onError"` in `baton.json`, decided at compile time and sent with
every operation the target compiles; never inferred. Under `NULL` an error
nulls a field in place, so the compiler types the fields the schema calls
non-null by their semantic nullability: non-optional under
`@throwOnFieldError` and inside `@catch`, optional elsewhere. See
[the contract](../spec/runtime.md#10-the-environment-and-the-wire).

**Request error.** *Composition: transport, phase.* GraphQL's word for an
error raised before execution begins, which leaves the response no data;
beside it the specification names the [field error](#store).
Here: a response of errors and no data fails its fetch with the server's
errors, each with its message, path and `extensions`: the request kind of a
[failure](#runtime). It is the same whatever its HTTP status: a server of
the GraphQL-over-HTTP specification sends it with a 4xx or 5xx status as
`application/graphql-response+json`, and the built-in HTTP transport fails
with it rather than with the transport's error, so a subscription it
refuses ends instead of reconnecting. See
[the contract](../spec/runtime.md#3-the-ingest-a-response-to-a-change-set)
and [the decision](decisions/a-failure-says-its-kind.md).
Swift: the failure is `GraphQLErrors`, whose `errors` keep each error.
Kotlin: the failure is `GraphQLErrors`, whose `errors` keep each error as a
`FieldError` and whose `messages` list their messages, carried as
`Failure.Request`; `requestErrors(body)` is public, so a transport over
another HTTP client reads a body as the built-in one does.

**Ingest.** *Composition: store, plan.*
Here: the stage off the main thread that decodes response bytes straight
into a change set by following a plan. A change set holds what the store
writes and nothing else; what the first part of an incremental response
announces, and whether more parts follow, are read beside it, and the parts
that follow are assembled into change sets at the records their paths name
by the environment's delivery. See
[the contract](../spec/runtime.md#3-the-ingest-a-response-to-a-change-set).
Swift: off the main thread is off the main actor.
Kotlin: off the store's thread is the environment's `ingestDispatcher`,
`Dispatchers.Default` unless given; a response the plan cannot read throws
`IngestError`, carried as `Failure.Malformed`.

**Preload.** *Composition: operation value, environment.* Relay: starting a
request on user intent, before the destination renders.
Here: a preload of an operation value; the destination's handle dedupes
against it. See
[the contract](../spec/runtime.md#8-the-handle-policies-phase-fetch).
Swift: `preload(operationValue)`.
Kotlin: `Environment.preload(operation, fetchPolicy)`, which returns the
handle the destination's `rememberQuery` then shares.

**Fetch.** *Composition: operation value, environment, transport.* Relay's
word: `fetchQuery`, and the fetch policies that say when one is made.
Here: one request for an operation's data, from the transport through the
ingest to the commit. A handle shows its last fetch as a value: idle, in
flight, or failed with the [failure](#runtime) and when it failed, an
instant of the monotonic clock; the operation value reads it beside its
phase. Not a phase: the phase is what the data deserves, and the fetch is
what the network did, so a fetch that fails behind data leaves the phase
ready and is read here until the next response, and refreshing is data
present and a fetch in flight. See
[the contract](../spec/runtime.md#8-the-handle-policies-phase-fetch) and
[the decision](decisions/a-handle-derives-its-phase.md).
Swift: the value is `Fetch`, the instant a `ContinuousClock.Instant`; the
operation value reads it as `fetch`, beside `phase`; refreshing is
`isRefreshing`.
Kotlin: the value is the sealed interface `Fetch`, `Idle`, `InFlight` or
`Failed(failure, at)`, the instant a `TimeMark` of the monotonic clock; the
handle and the `QueryState` read it as `fetch`, beside `phase`, as snapshot
state; refreshing is `isRefreshing`.

**Failure.** *Composition: transport, environment, phase.* A plain English
word: GraphQL has *request error* and *field error* for the server's part
and no word for the client's.
Here: what a fetch or a stream that did not deliver says, in one of a
closed set of kinds: the transport's, a [request error](#runtime), a
malformed response, the environment's. The transport's kind carries what
the transport threw, unchanged, and the error as thrown is read whatever
the kind. A field error is not a kind: under `@throwOnFieldError` it fails
the phase, as a `@required` field that bubbled does, but it is a fact about
the data. A handle's [fetch](#runtime) carries it, a subscription's stream
ends with it, and the [log](#runtime)'s events name its kind. What the
phase's failed case and a refetch carry stays the error as thrown, which the
decision leaves open. See
[the contract](../spec/runtime.md#8-the-handle-policies-phase-fetch) and
[the decision](decisions/a-failure-says-its-kind.md).
Swift: `Failure`, whose `error` is the error as thrown; the phase's failed
case and `refetch()` carry `any Error`.
Kotlin: the sealed class `Failure`, `Transport`, `Request`, `Malformed` or
`Environment`, whose `error` is the error as thrown and whose `of` classifies
one; the phase's `Failed` holds a `Throwable`, `refetch()` throws it, a
subscription's stream ends with `Stream.Ended(failure)`, and the log names the
kind.

**Fetch policy.** *Composition: store, operation value, environment.*
Relay's four.
Here: `storeOrNetwork`, the default, `storeAndNetwork`, `networkOnly`,
`storeOnly`; decided on attach over the availability check and staleness.
The policy is the holder's: it stays with the retention the attach makes, so
a fetch the runtime starts later, for an invalidation, a revalidation or a
heal, asks whether any holder allows the network, and a `storeOnly` holder
is fetched for by none of them. See
[the contract](../spec/runtime.md#8-the-handle-policies-phase-fetch) and
[the decision](decisions/revalidation-is-the-apps-call.md).
Swift: given as `@Query("…", fetchPolicy:)`; the default is
`FetchPolicy.default`.
Kotlin: given as `rememberQuery(operation, fetchPolicy)`; the default is
`FetchPolicy.Default`.

**Lookup.** *Composition: schema, store, plan.* Baton's word.
Here: a root field configured in `baton.json` as returning an entity by its
arguments, so a cached entity satisfies the field before it was fetched: one
argument (`argument`) for a type keyed by one field, or one per field of a
composite key in the key's order (`arguments`), composed into the record's
key as the ingest composes it. A lookup without a type finds an id among the
field's types that one value keys. See
[the contract](../spec/runtime.md#5-the-availability-check-and-hydration),
[the decision](decisions/lookups-bind-in-the-check.md), which superseded
[the first one](decisions/lookups.md), and
[the identity decision](decisions/identity-is-configured.md), which answered
the first one's reopening line.

## Lists

**Connection, edge, node.** *Concept: connection.* The Relay cursor
connections specification.
Here: a field with `@connection(key:)` is read through Relay's handle key
(`__<key>_connection(filters)`), a client record on the parent that every
page merges into: a page without a cursor replaces, one after a cursor
appends, one before a cursor prepends, edges deduplicate by node,
`pageInfo` merges per direction. The lens exposes the selection plus its
nodes (Baton's one convenience, Relay leaves it to the product), whether
there is a next and a previous page, whether either is loading, and the
connection id. See
[the contract](../spec/runtime.md#4-the-commit),
[its keys](../spec/runtime.md#1-types-keys-and-records) and
[the decision](decisions/connections-own-their-edges.md).
Swift: `nodes`, `hasNext`, `hasPrevious`, `isLoadingNext`,
`isLoadingPrevious` and `connectionID`.
Kotlin: the same properties, with `loadNext` and `loadPrevious` as
`suspend` functions that page through the environment of the handle the
lens was read from.

**Connection id.** *Concept: connection.* Relay's
`ConnectionHandler.getConnectionID`.
Here: the connection record's key, passed in the `connections` variable of
the edge directives. See
[the contract](../spec/runtime.md#4-the-commit).
Swift: read as `connectionID`.
Kotlin: read as `connectionID`, a `String`, passed as the action's
`connections: List<String>`.

**Pagination.** *Composition: directive, lens, connection.* Relay:
`usePaginationFragment` over a `@refetchable` fragment whose connection
takes `first`/`after` (or `last`/`before`) from `@argumentDefinitions`.
Here: loading the next or the previous page on the connection lens, running
the fragment's refetch query with the lens's variables, the merged cursor
and the owner's id; the fetch has no handle and no root, the connection owns
the pages; the loading flags are client fields on the connection record
(`__isLoadingNext`, `__isLoadingPrevious`). See
[the contract](../spec/runtime.md#6-the-lens-reads).
Swift: `loadNext(_:)` and `loadPrevious(_:)`.
Kotlin: `loadNext(count)` and `loadPrevious(count)`, `suspend` functions, the
count defaulting to the argument's default; a lens made by hand throws
`EnvironmentError.OutsideEnvironment`.

**Edge directives.** *Concept: directive.* Relay's declarative mutation
directives: `@appendEdge`, `@prependEdge`, `@appendNode`, `@prependNode`
(with `edgeTypeName`), `@deleteEdge`, `@deleteRecord`.
Here: the same, on mutation payload fields, applied as commit edits inside
the transaction, so optimistic responses carry them and revert them. A plan
spells each as an edit on its field, which the ingest turns into the change
set's edit. Inserted edges are copied into records the connection owns,
numbered by Relay's `__connection_next_edge_index`. A commit edits a
connection by the slots its plans resolved, which the registry keeps under
the connection's type, so it looks no key up by name; a record no
connection field made, or an edge of another type than the connection's, is
left alone. See [the contract](../spec/runtime.md#4-the-commit).
Swift: the plan's edit is `Edit`, the change set's `ChangeSet.Edit`.
Kotlin: the plan's edit is `Edit`, with an `Edit.Kind` per directive and its
connections an `Edit.Connections`; the change set's is the runtime's internal
`ChangeSet.Edit`.

**Page.** *Composition: lens, operation value.*
Here: a list fetched by page number or offset, as the sample API does. Not a
connection; composed in the UI from plain operations until the watch list
promotes a directive for it.
