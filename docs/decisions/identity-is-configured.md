# Identity is the fields the configuration names

Status: accepted, 2026-10-10. Answers the reopening line of
[Lookups satisfy root fields from cached entities](lookups.md), an entity
resolved by more than one argument. Serves
[The compiler decides](../principles/compiler-decides.md) and
[The store is the UI's state](../principles/store-is-the-ui-state.md).
Reopen when a schema shows an entity with no scalar key of its own, whose
key is a field through a link; the remedy is to widen the configuration to
a path, not to add a runtime hook.

## Context

Identity was the field named `id`: the compiler selected it where a type had
it, the ingest keyed a record by it, and a type keyed on anything else never
normalized, so two screens fetching the same entity by different paths held
two records, and a mutation's payload did not update the list beside it
(#10). Production schemas show three shapes: the identifier is a field with
another name (`uuid`, `code`, `handle`); both `id` and `uuid` exist, `id` a
global id other systems do not speak and `uuid` the one the product passes
around and its lookups take; and a composite identity, a quote by `(base,
quote)`, a membership by `(user, group)`. The first lookups record said a
root field resolved by more than one argument would reopen it.

## Decision

`baton.json` names the fields that identify a record of each type:

```json
"identity": {
  "default": ["id"],
  "types": { "Asset": ["uuid"], "Quote": ["base", "quote"], "Node": ["id"] }
}
```

- `default` is the list tried for every object type; unwritten, it is
  `["id"]`, today's behaviour. A type whose fields do not include it is keyed
  by its path, as before.
- `types` overrides per type. An interface's entry applies to every
  implementer without an entry of its own; an object implementing two
  interfaces whose entries differ names its own. An entry naming a field
  the type lacks, a list, a linked field, a `Float` or a `Boolean` is an
  error at the configuration.
- A key is own scalar fields, in order. A key through a link is refused for
  now: the ingest's look-ahead and the rule for which selections the
  compiler extends both widen for it, and no schema has yet shown an entity
  with no scalar key of its own.
- A key does not rename. It is the values of its fields at the write; a
  later payload with another value is another record, and the first stays
  as it was. Key fields must be immutable, which usually rules out a slug.
- The compiler selects the key fields wherever the type is read, as Relay
  selects `id`, and the plan names each type's key, so the runtime knows no
  field by name. Under an interface or union each member's key is selected
  under its own type condition, or on the abstract type itself when it
  declares the fields and every keyed member shares them.
- The record key is `Type:value` for one field and `Type:a:b` for several,
  each value escaped (`\` as `\\`, `:` as `\:`) so that no two lists of
  values meet; one value is written raw, as it always was, so existing
  images keep their keys.
- What names a record by one bare value reaches single-field keys only:
  `@deleteRecord`, `@deleteEdge`, a lookup without a type and the image's
  forget. A composite-keyed root field is satisfied by a lookup with several
  arguments, in the order of the type's key fields.
- A configuration other than the default joins the schema's digest the
  generated code passes as the image's version, so an image keyed the old
  way is a miss and not a merge of two keyings.

## Evidence

- The fixtures `spec/tests/asset-list.json` and `asset-by-uuid.json`: an
  `Asset` keyed by `uuid`, fetched by a list and by a root field, is one
  record `Asset:a1`, with the key arriving after a link in the second.
- `spec/tests/quote-list.json` and `quote-by-pair.json`: a `Quote` keyed by
  `(base, quote)` is `Quote:BTC:USD` from both; a value holding the
  separator is `Quote:A\:B:C\\D`.
- The owner's review of #10 (2026-10-04): no by-id index exists to extend;
  the plan carried a boolean and the name `id` was spelled in the compiler
  and five layers of the runtime, which the plan naming the key field
  ended first.

## Not chosen

- Apollo's `@typePolicy` or a key function at run time: a policy object
  decided late, invisible to the compiler.
- Keys through links in this change: possible, since the look-ahead already
  reads past a link, but unasked for by any schema at hand.
- Escaping the single value as well: it would change every existing key and
  so every image for a case that cannot collide.
