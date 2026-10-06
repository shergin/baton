# The store numbers what its session renders

Status: accepted, 2026-10-07. Chooses the mechanism
[Keys a session produces belong to its store](session-keys-belong-to-the-store.md)
left open, and supersedes
[Slots are numbered by the process](slots-are-numbered-by-the-process.md)
for the keys a session renders; the build's keys stay the process's. Serves
[The store is the UI's state](../principles/store-is-the-ui-state.md) and
[What earns a concept](../principles/what-earns-a-concept.md). Reopen if an
adopter shows two stores that must share a rendering's number, or if the
bench shows a read through a key the store numbered or a commit of a lookup
above the gates below.

## Context

A key rendered from variables, one per id looked up and per cursor paged
past, was numbered by the process the first time it was met and kept for
the process's life, with its text, its channel and its entry in the root
record. The bench's long session took the keys on `Query` from 469 to
50,672, and the image's table of names grew the same way, to a limit of
65,536 past which the file was discarded. The direction was decided: the
process numbers what the build contains, a store what its session
produces. The mechanism waited for a spike with kill gates: a read through
a store-numbered key at 31.6 ns or less, a commit of a lookup of a new id
at 2.04 us or less, by shape only if a record's layout brought a row with
three keys with constant arguments back to 356 bytes and 5,000 rows to
4.10 ms, and a table the size it was at the start once a long session's
roots were released and collected.

## Decision

- The registry numbers the keys the build names, constants with arguments
  or without, densely and for the process. `Keys`, one table per store,
  numbers what the session renders, apart, as `~n`; a record keeps those
  written to it in its sorted list, as before. A plan is resolved for a
  store, and a change set made from it is committed into that store.
- A text has one slot in a store. A rendering whose text the build names
  takes the constant's slot. A constant the build names after the store
  rendered its text is adopted at the store's next resolution, check or
  commit: the two slots become twins, the records' values are copied
  across, and every write to either lands in both.
- A resolution and a lens's scope hold the numbers they took while they
  live. After its sweep, the collector frees every number nothing holds,
  but for an optimistic layer's and a row's waiting for the image: the
  text goes, records drop their entries, the image forgets the name, and
  the number is used again by the next rendering, lowest first. The table
  ends at its highest number in use.
- A key a record's row was read under is held by the image for the image's
  life, as the record reads its row once; a root field's is freed with the
  rest and read from the image again.
- The image sweeps its names with its rows: at a launch's first batch,
  after the rows that aged out go, the names no row uses are deleted and
  their ids used again. The limit of 65,536 ends; the format is 4.
- A subscription root's field stays keyed by its arguments and is freed
  with its subscription.
- By shape is not chosen. Every key with arguments as the store's would put
  a constant's field in the sorted list, +96 bytes a row for three such
  fields and 15% on 5,000 rows, and no layout of the record recovers it: a
  dense index is the process's, because generated code holds it as a
  constant, and a second dense array per record costs its header.

## Evidence

- [`BENCHMARKS.md`](../../BENCHMARKS.md), the keys step, 2026-10-07 at
  `fcec2ce` against `f1c1fdf` the same evening, an M1 Pro under load: a
  read through a key the store numbered did not move against the baseline
  (32.8 ns against 31.5 best, 33.1 against 32.8 at the median, where the
  gate's 31.6 was set on a quiet machine); a commit of a lookup of a new id
  is 1.33 µs against 1.88 at the session's start and 2.12 against 2.25 at
  its end; the keys on `Query` go 0, 50,202, 0 over the session and the
  collection that follows it, where they went 469 to 50,672 and stayed. A
  resolution costs 200 ns more; a pass over 300 roots 4 µs more; a
  launch's first write-behind a quarter of a millisecond for the aging
  and the names sweep over 898 rows.
- By shape's cost, measured on 2026-10-04 and again here under both
  definitions of the rows bench: 96 bytes a row and 15% on 5,000 rows.
- The tests: two stores number the same rendering apart and the process
  numbers nothing for it; a key has one slot whichever way it is met, and
  the adoption of a late constant in both directions, through a commit and
  through hydration; a lookup's key is freed when its root has left the
  buffer and a collection runs, a retained one's stays, and a freed number
  is used again by the next rendering; a key in a row the image has not
  written yet is kept through a collection; an optimistic layer's keys stay
  while it is applied; a subscription root's field is freed with its
  subscription; a row written under a freed number is named by the new
  key; after an environment's end its store keeps no key its session
  rendered; names no row uses are swept and their ids used again.

## Not chosen

- By shape, as measured above.
- A table of the process for the texts stores numbered apart, to tell a
  late constant: the decision forbids a session's texts in the process.
- Re-resolving roots and resetting owners when a constant is adopted:
  twins keep every holder right without reaching them.
- A count of records per number kept on the write path: the collector's
  pass enumerates the survivors instead, where it already visits them.
- A names sweep gated by a threshold: unconditional, proportional to the
  rows, measured, and free of a number to defend.
