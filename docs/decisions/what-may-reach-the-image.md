# What may reach the image is a property of types and root fields

Status: accepted, 2026-10-11. Answers
[#20](https://github.com/shergin/baton/issues/20). Serves
[The compiler decides](../principles/compiler-decides.md) and
[The store is the UI's state](../principles/store-is-the-ui-state.md).
Reopen if a product needs a field below the root kept off the image while
its record stays on it, or a per-record switch; the remedy is to widen the
configuration to such fields, never a runtime policy.

## Context

Every record a server's payload changed reached the image, whatever it held.
What stayed out was by role: optimistic layers, the mutation and
subscription roots, a connection's loading flags, a lookup's back-link. An
app with content that must not outlive the process, message bodies, private
previews, had file protection and a purge at sign-out, both weaker than
never writing. The issue asked for a per-type list. The owner's review
found the hole in a type list alone: a storage key carries its argument
values and the query root is stored a row per field under the key's text, a
`names` table interns every storage key, and an operation's fetch time is
stored under its name and variables, so a private search string reaches the
disk whatever its result's type.

## Decision

- `baton.json` names what never reaches the image, in a `transient` block
  with `types` and `fields`. A type's records are never written; an
  interface named applies to its implementers. A root field named, as
  `Query.search`, has no cell written, so the storage key carrying its
  arguments is never interned, and an operation selecting it leaves no
  fetch stamp, which would carry its variables.
- A record's slot that links to a transient record is left out of its row,
  and a root cell linking to one is not written. Nothing on disk names a
  transient record. At the next launch the availability check misses on
  the slot and the operation fetches: a screen that shows transient
  records refetches at launch; one that does not is unaffected. A
  connection holding transient nodes is not shortened to fit; its edges'
  node slots are left out and the check misses on them.
- Memory is unaffected: the store is the UI's state, and the records live
  as long as a retention reaches them.
- The lists join the schema's digest the generated code passes as the
  image's version, so an image written under another list starts again.
  Rows written before a type was named are gone with the version.
- The compiler decides it: the plan marks the root fields, the shared file
  tells the registry the types and fields, and the writer asks the registry
  per row, per link cell and per root cell. No runtime switch, as with
  identity and lookups.

## Evidence

- The fixtures `spec/tests/secrets.json` and `character-secret.json`: with
  `Secret` and `Query.secrets` transient, a flushed image holds no `Secret`
  row, no name beginning `secrets(`, no fetch stamp for the operation, and
  `Character:1`'s row without its `secret` slot; memory reads all of it,
  and a relaunch misses and fetches.
- The owner's review of #20 (2026-10-04): the three other paths a value
  reaches the disk by, and the refusal of a connection kept whole with its
  transient edges dropped.

## Not chosen

- A per-fragment or per-record switch: whether a value reached the disk
  would depend on fetch order and which screen wrote first.
- Keeping a connection's non-transient edges across a relaunch: a list
  shorter than the server's that reads as whole is invented data.
- Deleting rows of newly transient types at open as the main mechanism: the
  digest covers it; a safety net at open may follow with the report.
- A word of Relay's: Relay's store is not persisted and has none.
