# The image is the system's SQLite

Status: accepted, 2026-10-03. Serves
[The store is the UI's state](../principles/store-is-the-ui-state.md) and
[Two runtimes, one compiler](../principles/two-runtimes-one-compiler.md).
Reopen if a measurement on a phone shows the engine, not the records, keeping
a cached screen out of its first frame; or if a second process (an extension,
a widget) has to share the image. No iPhone 12-class device was at hand on 2026-10-05, when the plan's
ground step asked for the number; the line stands until one is.

## Context

The store had to outlive the process, so that a launch draws the screens it
showed last time before the network answers. What it needs from a disk is
small: put a batch of records, get a record by key, drop what has gone
unused. No queries. The question was whether an engine without SQL (a
memory-mapped B-tree, a log-structured store, a file format of our own) would
serve better than the SQLite every device already has, and how much of the
store's shape the disk should know.

The owner's rule for the choice: a Mac's numbers are not a phone's, so they
can only show whether engines differ radically, and unless they do, the
simplest one wins.

## Decision

- SQLite through the system library, one file, opened off the main actor
  when the image is created. Nothing is vendored and no package is added.
- The image is the store's records and nothing derived from them: a row per
  record keyed by the record's key, the query root a row per field because
  it is a directory of entry points and not an entity, the time each
  operation last fetched, and a table of names, because slot numbers belong
  to a process. Rows are binary; a link is its target's type and key.
- Writing is behind the commit: the main actor hands over a snapshot of each
  changed record, and one writer encodes and commits them. WAL,
  `synchronous=NORMAL`, no forced flush at a checkpoint: a crash may lose the
  last moments and never the file's consistency.
- Reading is the availability check: when memory cannot answer, the walk
  runs again with the connection at hand, inside one read transaction, and
  fills what memory lacks. There is no other read path, no preload and no
  second connection; a read waits for a write in flight.
- A file that cannot be read is deleted and started again. Rows age out by
  launch: one whole launch unread, then gone.
- Added 2026-10-06: a record's row is replaced by its snapshot only when
  memory holds everything the image does, that is, when the check has read
  the record's row. The snapshot of a record memory has not read holds what
  this launch's responses wrote and nothing of what the image held; the
  writer merges it into the row, its own cells first and then the row's
  cells it does not write, inside the same transaction. A deleted record
  replaces its row, and a deleted row's cells are not merged into a record
  a payload names again, as hydration reads none of them. Without this a
  response with a few of a record's fields, a header before a screen,
  emptied the row of everything else and the next check missed.

## Evidence

- `BatonBenchmarks`, 2026-10-03, an M1 Pro with a warm page cache
  (`BENCHMARKS.md`, 0.6.0): the check reads 898 rows into an empty store in
  1.72 ms, against 1.37 ms to commit the same records from a response, so
  the image's own share of a screen's hydration is about a third of a
  millisecond over what any source of those records would cost. A launch in
  a new process has the fixture in the store 1.78 ms after its handle asks
  when the file opened off the main actor, and 4.68 ms after when the main
  actor waited for the open. Keeping the image costs a commit 0.12 ms on the
  main actor and 1.16 ms off it; the file is 168 KB for a 686 KB response.
- The persistence tests: a second store over the same file renders the
  fixture with a transport that never answers and agrees with the response
  field by field; a mutation's answer survives and an optimistic response
  does not; field errors, a connection's merged pages, a deletion and an
  operation's age survive; garbage, another version and another format are
  misses; a database that is not an image is left untouched.
- The Rick and Morty sample against the public API: the first launch wrote
  41 rows, the second read all 41 before its refetch landed.

## Not chosen

- A memory-mapped B-tree (LMDB and its descendants). It would shorten the
  part of hydration that is already the smaller part, and it costs vendored C
  that the project would then own, a license notice in every binary, I/O
  errors that arrive as signals, and on Apple platforms a full flush per
  commit unless durability is switched off by hand.
- A file format of our own. The fastest to read and the least code to look
  at, but a changed record then needs a log and its compaction, or a
  rewritten file, and crash consistency becomes ours to prove.
- Raw responses, replayed through the ingest at launch. Simpler still, and
  it forgets every mutation: a screen would show its pre-edit data until its
  refetch landed.
- Integer row ids with links stored as ids. Faster lookups and smaller rows,
  for a second index and a mutable id on every record.
- Size-ordered eviction, a preload off the main actor, a second connection
  for reads, merging a row with fields only the image holds. Each waits for a
  measurement on a device that asks for it. The merge was taken up on
  2026-10-06 on evidence of another kind: the persistence test of a check
  that fills a record a reader holds failed on CI whenever the writer landed
  before the check, since the row had lost the fields the response did not
  carry. The addition to the decision above records it.
