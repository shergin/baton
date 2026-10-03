# Terminology

The vocabulary contract: every public concept is named here before it is
named in code, and when a concept is added, renamed or changes meaning, this
file is updated in the same change. Each entry gives the meaning in the
literature, why this word, and what it maps to here. Entries marked
*(planned)* do not exist in code yet.

Design arguments live in [vision](vision.md) and [principles](principles/).
Where Relay or the GraphQL specification has a word, it is used
([Relay's words](principles/relays-words.md)).

## Documents

**Fragment.** GraphQL: a named selection on a type. Relay: the unit of a
component's data needs. Here: declared beside the view that reads it, in
Swift source or a `.graphql` file; compiles to a [lens](#generated) type.

**Operation.** GraphQL: a query, mutation or subscription. Here: assembled by
the compiler from the fragments spread into it; one per screen; compiles to a
variables type, a root lens, a [plan](#compiler) and a persisted id.

**Spread.** GraphQL: `...Name` inside a selection. Here: compiles to a named
accessor on the parent lens that returns the child fragment's lens, optional
when the spread is conditional or deferred. The default accessor name is
derived from the fragment name; `@alias` renames it.

**Fragment arguments.** Relay: `@argumentDefinitions` and `@arguments`. Here:
the same directives; applied by the compiler per unique argument set for the
plan and operation text, bound at run time for reading. *(planned)*

**Directive.** GraphQL: an annotation on a selection or definition. Here:
the only way behaviour is attached to data; the set is Relay's
([Relay's words](principles/relays-words.md)).

**Variables.** GraphQL: an operation's parameters. Here: the stored
properties of an [operation value](#generated).

## Generated

**Lens.** Baton's word. The typed, read-only view a fragment or operation
root compiles to: a record reference (and a context when variables are
involved) with one accessor per declared field. Relay has two words,
fragment reference and fragment data, for what is one value here; "reader"
is Relay's name for machinery and "view" is SwiftUI's. See
[A fragment is a lens](principles/fragment-is-a-lens.md).

**Operation value.** A `Hashable` struct of an operation's variables, the
thing a parent constructs and a navigation path carries. Inside a view it
resolves to a handle exposing `phase`, `data`, `refetch`, `retry`.

**Phase.** The state of a resolved operation: loading, ready (with
`isRefreshing`), or failed. Always synchronously readable; previous data
stays visible while refreshing. Named after `AsyncImagePhase`, the platform's
own word for the same shape.

**Action.** A mutation as a callable value, after SwiftUI's `dismiss` and
`openURL`: called with variables and an optional optimistic response, exposes
`isInFlight`. *(planned)*

## Store

**Record.** Relay: a normalized object in the store. Here: an observable
object identified by typename plus key, holding interned slots, per-field
errors and type-membership bits.

**Key.** The configured identity fields of a type (default `id`), combined
with the typename. Objects without a key get a path-based client id, as in
Relay.

**Storage key, slot.** Relay: a field name plus its serialized arguments,
the key under which a value is stored. Here: interned by the compiler to an
integer slot, so the runtime never hashes a name.

**Store.** Relay's word. All records, retained roots and lifetime state;
owned by the main actor; read synchronously; written by atomic commits. See
[The store is the UI's state](principles/store-is-the-ui-state.md).

**Commit, change set.** A change set is the output of ingesting one response
or applying one optimistic update: records, slots, references, errors. A
commit applies it on the main actor and notifies the observed fields that
changed.

**Root, retain, release buffer.** Relay's words. An operation whose handle is
alive retains its records; a released root waits in a buffer (default ten)
before its records become collectable. *(planned)*

**Invalidation, TTL.** Relay's and Apollo's shared words. A record or the
store marked stale forces the next read policy to refetch; a time-to-live
does the same by age. *(planned)*

**Optimistic overlay.** Relay: optimistic updates applied in a layer that is
rebased on each commit. Here: the same, applied on a scratch overlay so only
the net difference reaches the visible records. *(planned)*

**Heal.** Baton's word for the response to missing data: record the event,
mark the owning operation stale, refetch. See
[Honest data](principles/honest-data.md). *(planned)*

## Compiler

**Schema.** GraphQL: the SDL. Here: a checked-in file plus identity
configuration; introspection download is a CLI command.

**Plan.** Baton's word for the normalization artifact: the data a response is
decoded by and a store is written from, one per operation, emitted by the
compiler and interpreted by the runtime. Relay's normalization AST, renamed
because it is data, not a tree the runtime walks generically.

**Persisted id.** Relay and the GraphQL community's word for the hash a
server accepts in place of operation text. Here: emitted for every operation
by default.

**Artifact.** Everything the compiler emits for one source file: lens types,
plans, ids.

## Runtime

**Environment.** Relay's word for store plus network plus configuration.
Here the same, injected through SwiftUI's environment as `\.baton`. Chosen
over "client" (Apollo's word) by [Relay's words](principles/relays-words.md).

**Transport.** The protocol behind which HTTP, WebSocket and multipart
incremental delivery live; URLSession implements it.

**Ingest.** The off-main-actor stage that decodes response bytes straight into
a change set by following a plan.

**Preload.** Relay: starting a request on user intent, before the destination
renders. Here: `preload(operationValue)`; the destination's handle dedupes
against it.

**Fetch policy.** Relay's four: store-or-network, store-and-network,
network-only, store-only, decided over an availability check. *(planned)*

**Lookup.** Baton's word for a root field configured in `baton.json` as
returning an entity by one of its arguments, so a cached entity satisfies the
field before it was fetched. See [the decision](decisions/lookups.md).

## Lists

**Connection, edge, node.** The Relay cursor connections specification.
Here: `@connection` merges pages into one stored list exposing `nodes`,
`hasNext`, `loadNext`, `isLoadingNext`; the state lives in the store as
client fields. *(planned)*

**Page.** A list fetched by page number or offset, as the sample API does. Not
a connection; composed in the UI from plain operations until the watch list
promotes a directive for it.
