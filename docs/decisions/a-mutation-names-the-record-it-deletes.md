# A mutation names the record it deletes when its payload does not

Status: accepted, 2026-10-18; answers
[#50](https://github.com/shergin/baton/issues/50). Serves
[What earns a concept](../principles/what-earns-a-concept.md),
[Relay's words](../principles/relays-words.md) and
[The store is the UI's state](../principles/store-is-the-ui-state.md).
Reopen if Relay or the GraphQL specification gains a word for it, which
then replaces ours; or if a real screen must delete a record keyed by
several fields, or several records from one variable, which widens the
directive rather than adding a mechanism.

## Context

Relay's `@deleteRecord` deletes the record whose id the payload field it
sits on returns. Many servers answer a delete with less: AniList's
`DeleteMediaListEntry(id: Int)` returns `Deleted { deleted: Boolean }`.
The adopter refetches the list after the write: a request the rate limit
charges for, and a visible gap between the layer's revert and the
refetch's commit. The issue's other half, `ToggleFavourite`, changes
`Media.isFavourite` on a record its payload does not reach.

The id is in the request already, as a variable. Relay's answer is an
updater, runtime code that calls `store.delete(dataID)`; Baton has none,
and [#13](https://github.com/shergin/baton/issues/13) refused a second way
to write. The GraphQL specification has no word. One adopter has asked,
for two mutations in one app; a delete answered with a boolean is the norm
on servers that did not grow up on Relay's conventions, Baton's second
audience.

## Decision

A mutation names a record it deletes by its type and the variable its key
is passed as, with a directive of Baton's own:

```graphql
mutation DeleteEntry($id: Int!) @deletes(type: "MediaList", id: $id) {
  DeleteMediaListEntry(id: $id) { deleted }
}
```

- It sits on a mutation operation, not on a field, since it reads nothing
  of the payload. `type` is a string constant naming an object type keyed
  by one field. `id` is a variable of that key field's named type (`Int`
  here, `ID` on most schemas, `String` for a `uuid`), not a list, and one
  a field of the mutation also passes, since a server refuses a variable
  its operation does not use. It may repeat, one record each.
- The compiler takes it off the document before Relay's front end builds
  it, since Relay checks a variable against one declared type and the
  key's type is each record type's own. The compiler checks the type, its
  key and the variable itself, and reports at the directive's position in
  the host file. A server never sees it.
- The plan carries the type and the variable. Each run renders the exact
  key `Type:value` from the variable's value, as a lookup composes its
  key; an unset or null variable names nothing. No type is probed and
  nothing is ambiguous, unlike `@deleteRecord`'s bare id.
- The deletion is an edit of the commit, as the edge directives' are: an
  optimistic response carries it, so the row is gone in the turn of the
  call; a refusal reverts it with the layer; the server's response, or a
  payload committed for the mutation through `commitPayload`, makes it.
  The record is deleted as `@deleteRecord` deletes one: values cleared,
  links null, lists skipping it, its holders told
  ([the deletion decision](deletion-is-announced-by-its-commit.md)), a
  payload naming it again reviving it. A record memory does not hold is
  forgotten in the image by its key.
- The payload does not gate it. Relay's `@deleteRecord` acts only when its
  field is non-null, and an updater can read `deleted` first; a mutation
  that says `@deletes` accepts that `deleted: false` without an error does
  not stop it. An error response reverts the layer, as for any edit.
- Delete only. A directive that set a field from the document would be
  local state written by the compiler, which the README declines. The
  favourite's composition exists: after the mutation, commit a payload for
  a query that selects `Media(id:) { isFavourite }`, which
  [the client-data decision](client-data-is-described-and-committed.md)
  sanctions as data learned outside the transport. Its optimism stays the
  app's.
- It is the second directive that is not Relay's.
  [`@cacheExpiration`](an-operation-states-its-expiration.md) put in the
  document what Relay does with runtime configuration; this puts there
  what Relay does with runtime code. As it is being built, the plan JSON
  carries `"deletes": [{"type": "MediaList", "variable": "id"}]`, and the
  generated-code format rises to 20 in Swift and 4 in Kotlin.

## Evidence

- Relay v21.0.1, the revision the compiler pins, read 2026-10-18. Of its
  six declarative mutation directives (`relay-extensions.graphql` in
  `compiler/crates/relay-schema/src`, lines 257-307), `@deleteRecord`
  takes no arguments; the others take `connections: [ID!]!`, the node
  forms `edgeTypeName: String!` too. A variable feeds only the connection
  ids; the record deleted or inserted comes from the field. `@deleteRecord`
  requires an `ID` field (`relay-transforms/src/declarative_connection.rs`,
  line 137; the error at 397-404), so Relay's front end, which Baton runs,
  would refuse AniList's `Int` id even in a payload that carried it.
- The legacy `NODE_DELETE` and `RANGE_DELETE`
  (`packages/relay-runtime/mutations/RelayDeclarativeMutationConfig.js`)
  read the deleted ids from the payload through `deletedIDFieldName`; the
  caller's `parentID` and `connectionKeys` name a connection's owner, never
  the record removed. Their documentation left relay.dev in October 2024.
- [Relay's guide](https://relay.dev/docs/guided-tour/updating-data/imperatively-modifying-store-data/)
  lists deleting nodes among what only an updater does. A handle field's
  arguments reach its handler resolved from the variables
  (`store/RelayResponseNormalizer.js`, lines 299-313), but the built-in
  handlers ignore them, and a handler of one's own, registered at run
  time, is a runtime policy object Baton refuses.
- Baton as built: `@deleteEdge`'s edit already reads a variable
  (`EditPlan.connections`, `compiler/src/pipeline/plan.rs`); a lookup
  composes a key from a variable's value (`Record.keyValue`,
  [the lookup decision](lookups-bind-in-the-check.md)); the commit's pass
  that tells a deleted record's holders is built.
- The watch list's trigger for imperative updaters, "a real write that
  neither a directive nor a payload can express", is not met: a directive
  expresses this one.
- Nothing new is measured: the deletion is `@deleteRecord`'s, whose pass
  the deletion decision benched, and its key reads one variable.

## Not chosen

- The issue's second option, a client field `Deleted.deletedId` filled by
  the optimistic payload and carrying `@deleteRecord`. A client field is
  left out of the text a server receives, so the server's response never
  carries it, the server's commit never deletes, and the layer is reverted
  when the answer arrives. Keeping an optimistic value past the server's
  answer would be invented data.
- `@deleteRecord` with new arguments: Relay's word with another meaning,
  since Relay's reads the field's value.
- An updater closure, or `commitLocalUpdate`: a second way to write,
  refused in #13.
- A directive that sets a field: local state written by the compiler.
- A form gated by a Boolean on a payload field: it ties the directive to
  one payload's shape, and a mutation that returns an object with an `Int`
  id, or nothing useful, needs it as much.
- A refetch recipe alone, the issue's third option: the request and the
  gap between the layer's revert and the refetch's commit are what the
  store's one change set exists to remove.
