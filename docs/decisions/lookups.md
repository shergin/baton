# Lookups satisfy root fields from cached entities

Status: superseded, 2026-10-03, by
[A lookup binds in the availability check, never in a read](lookups-bind-in-the-check.md);
accepted, 2026-10-02. Serves
[The store is the UI's state](../principles/store-is-the-ui-state.md) and
[Relay's words](../principles/relays-words.md). Reopen when a schema needs an
entity resolved by more than one argument, or by a field below the root; the
remedy is to widen the configuration, not to add a runtime hook.

## Context

A detail screen asks for `character(id: $id)`. The list that led there fetched
the same character under `characters(page: 1).results[3]`, so the entity
`Character:4` is in the store, but the root link `character(id:"4")` was never
written. Relay solves this with a missing-field handler for `node(id:)`,
registered in code at run time, and relies on the `Node` interface. The sample
API has no `Node`, and the store takes no runtime policy objects.

## Decision

`baton.json` names root fields that return an entity by one of their
arguments:

```json
"lookups": [{ "field": "Query.character", "type": "Character", "argument": "id" }]
```

The compiler bakes the lookup into the operation's plan. When the availability
check or a lens read finds the root link missing, it looks for `Type:value`
with the argument's value, uses the entity if present, and writes the link so
later reads are direct. Nothing is configured at run time.

## Evidence

- The spine's first-body test (2026-10-02): the detail handle is `.ready` on
  creation with the lookup and `.loading` without it; the lens read of
  `character(id: "3")` returns the cached "Summer Smith" and leaves the link
  written.
- Relay's compiler already treats `Node` as feature-scoped (refetchable
  fragments also accept `Query`, `Viewer` and `@fetchable` types); a
  configured lookup is the same idea with the schema's own root fields.

## Not chosen

- Requiring `Node` and `node(id:)`: the sample API and many real schemas lack
  them.
- A runtime missing-field handler registered on the environment: a policy
  object, decided late, invisible to the compiler.
- Keying root fields by their arguments automatically: guesses wrong whenever
  an argument is a filter rather than a key.
