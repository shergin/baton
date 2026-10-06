# Keys a session produces belong to its store

Status: accepted, 2026-10-04; the mechanism, left open here, was chosen on
2026-10-07 in
[The store numbers what its session renders](the-store-numbers-what-it-renders.md).
Serves
[The store is the UI's state](../principles/store-is-the-ui-state.md) and
[The compiler decides](../principles/compiler-decides.md). Reopen if the
spike finds no rule that keeps one slot for a key's text at today's cost of
a read and a commit.

## Context

A storage key gets its number from a table of the process the first time
it is met ([Slots are numbered by the process](slots-are-numbered-by-the-process.md)).
A key the compiler emitted as a constant is numbered densely. A key
rendered from variables, such as `character(id:"4")` or a page's cursor, is
numbered apart and kept in a record's sorted list. The table only grows,
and four things follow.

- Memory grows with the session, not with what is on screen. The bench's
  long session takes the keys on `Query` from 169 to 2,372, "for the life
  of the process", and an invalidation channel is kept for each.
- A session's data outlives the session. The texts hold ids, cursors and
  search strings, and stay after an environment's end and after
  `removeAll()`.
- The root record keeps an entry for every such key after its target is
  collected: the collector blanks the value and keeps the key.
- The image's table of names only grows too, and an image past 65,536
  names is discarded at its next open.

The first answer on the retention issue
([#16](https://github.com/shergin/baton/issues/16)) named the growth and
asked for a design. What makes one hard is a rule that must hold: a key's
text has one slot, or two operations write one field to two places. Today
whichever of a constant, a rendering or the image meets a text first
decides its kind.

## Decision

The process numbers what the build contains. A store numbers what its
session produces. This is *(planned)*.

- A key without arguments is the build's, bounded by the documents, and
  stays numbered as decided.
- A key with arguments that a session produces is the store's: numbered by
  it, dropped at its end, freed by its collector. So it lives while a
  retained or recently released operation uses it. Nothing a session
  produces is kept in a table of the process.
- There is no cache of keys beside that. A key's number is an address:
  records, resolved plans, owners, channels and the image's rows hold it.
  What frees an address is that nothing reaches it, and the release buffer
  is the one rule by recency the store has.
- The mechanism is not chosen. A spike with benches chooses the rule that
  keeps one slot for a text. Preferred: by shape, where every key with
  arguments is the store's, whether a literal or a variable wrote them, if
  a layout of the record brings its cost back to today's numbers.
  Otherwise constants stay dense and only rendered keys move, with a way to
  adopt a constant that arrives late.
- The spike also settles the table's use off the main actor, where plans
  are resolved and responses read; when a number may be used again, since
  owners and resolved plans remember it; the channels of such keys; and the
  image's names, collected with the rows that use them, which ends the
  limit of 65,536.
- Two steps need no design and go first: the collector removes the root's
  blanked entries, and the long-session bench reports how the table grows
  over 50,000 lookups.
- The mechanism's own record will supersede part of
  [Slots are numbered by the process](slots-are-numbered-by-the-process.md).

## Evidence

- [`BENCHMARKS.md`](../../BENCHMARKS.md), 2026-10-04 at `2ba3d18`, an M1
  Pro. A row with three fields under keys like `labels` or
  `labels(first: 3)` costs 356 bytes; under `labels(first: $count)`, 452.
  Five thousand such rows go into an empty store in 4.03 ms against
  4.65 ms, at best. A root field with a variable argument reads in 31.6 ns
  at the median, against 28.1 ns when every key was dense; a session's
  newest one reads in 37.0 ns at its start and in 55.7 ns after 2,000
  lookups and 500 pages. The first two are what "by shape" costs constants
  with arguments in today's layout.
- As built, by reading: the registry is one locked table that nothing
  removes from; `prune` blanks a swept link and keeps its key; the image
  throws an open of more than 65,536 names away; and the image already
  decides a name's kind by shape, taking one with arguments as rendered.
- Nothing new is measured. This record sets a direction and the questions
  the spike answers.

## Not chosen

- The process's table for every key, as built: it grows with the session
  and outlives it.
- A table per store for every key, or a table reset at sign-out: generated
  code holds a field's slot as a constant of the process, and a second
  store shares it.
- A least-recently-used cache of keys. A screen that has not drawn for a
  while still uses its keys; dropping their numbers would blank a field on
  screen, and using a number again would read an old value as a new key's.
- The mechanism chosen now. By shape has a cost measured today, and keeping
  constants dense has a migration nobody has built.
- A key with arguments kept under its text in each record: a hash, or a
  comparison of strings, on a path a view takes more than once.
