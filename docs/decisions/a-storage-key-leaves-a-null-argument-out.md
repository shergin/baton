# A storage key leaves a null argument out

Status: accepted, 2026-10-08. Serves
[Relay's words](../principles/relays-words.md) and
[The response is the oracle](../principles/response-is-the-oracle.md).
Reopen if a server distinguishes an argument passed as null from one not
passed, in a way a cache key must keep apart; GraphQL's coercion makes the
two the same for a nullable argument without a default, and Relay's key
treats them so.

## Context

A storage key is the field's name and its arguments in sorted order, the
key under which a record stores the field's value. Baton rendered every
argument, a null one as `null`: the first page of a connection fetched
with `after: $after` and no cursor was stored under
`notes(after:null,first:2)`, and the same page fetched by a document that
passes no `after` under `notes(first:2)`, two keys for one field. Relay's
`getStorageKey` leaves an argument out when its value is null or
undefined. The plan now carries the key as a name and arguments, and
either rule moves keys on disk, so the choice is made here, once.

## Decision

- An argument whose value is null is left out of the storage key: a
  constant `null` in the document by the compiler, a variable given null
  or nothing by the runtime when it renders the key. An argument that is
  an object or a list keeps the nulls inside it, as Relay's JSON of the
  value does.
- The key's text is otherwise unchanged: the name, then `name:value` in
  the arguments' sorted order, in parentheses, values as JSON with sorted
  object keys.
- The image's format is 5, so an image of format 4, whose rows carry the
  old keys, is a miss and starts again.

## Evidence

- The store dumps under `spec/` for the notes pages and the recent notes:
  the first page's key reads `notes(first:2)` where it read
  `notes(after:null,first:2)`, and the connection's merged record is
  unchanged.
- Relay's `RelayStoreUtils.formatStorageKey`, which skips a value that is
  `== null`.

## Not chosen

- Rendering the null, as built: two keys for one field, and a cache miss
  for a document that spells the argument out against one that does not.
- Leaving nulls out inside objects and lists too: Relay keeps them, and a
  value's JSON is the oracle of its spelling.
