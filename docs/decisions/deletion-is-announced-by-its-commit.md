# A deletion is announced by its commit, not tracked by readers

Status: accepted, 2026-10-03. Serves
[The store is the UI's state](../principles/store-is-the-ui-state.md).
Reopen if the commit-side pass, once measured, costs more than a frame at a
store size the project supports, or if deletions stop being rare (bulk
deletes delivered as a stream).

## Context

`@deleteRecord` marks a record deleted: links to it read as null and lists
skip it. The slot that holds the link does not change, so nothing tells the
body that read the list. At 0.6.0 the commit notifies only the deleted
record's own fields; a list is redrawn only when the same mutation also
edits it with `@deleteEdge`.

Something has to tell the holders. Either every reader of a link registers an
interest in its target being alive, or the commit that deletes finds the
slots that hold the link. A review of 0.6.0 proposed the first.

## Decision

Readers do not track whether a linked record is alive. Link, list and
connection accessors check the flag without registering the check. The commit
that changes a record's deleted flag, in either direction, notifies every
slot that links to the record, after the batch, for the flags the batch
changed on balance. The record's own values are cleared through the same
batch, which is what tells the bodies that read its fields.

## Evidence

- `BatonBenchmarks` (`BENCHMARKS.md`): a field read inside an observation
  scope costs 544 ns against 28 ns outside one (0.6.0), and `nodes` over a
  connection of 2,100 edges costs 124 µs untracked against 1.11 ms tracked,
  at one access per edge and per node (0.4.0). A tracked liveness check adds
  an access per link read and per list element to every body, for an event
  most sessions see a handful of times.
- The commit-side pass is one scan of the store's values in a commit that
  deletes or revives, and nothing in any other commit. `BatonBenchmarks`,
  2026-10-03 (M1 Pro, macOS 26.5.2): a commit whose only edit is one
  `@deleteRecord`, in a store of 8,965 records, costs 2.2 ms best, against
  7 µs before the pass. That is within a frame on that machine; a phone's
  number at the same store size is the reopening condition. No iPhone
  12-class device was at hand on 2026-10-05, when the plan's ground step
  asked for it; the condition stands until one is.

## Not chosen

- A deletion channel per record that readers register with: precise, and
  paid on every list read whether or not anything is ever deleted.
- One deletion channel for the whole store: one access per read, but any
  deletion re-runs every body that read a link or a list.
- A reverse index from a record to the slots that hold it: makes the pass
  free and taxes every link write of every commit.
- Keeping a deleted record's values behind the flag: a payload that names the
  record again would bring back values the server deleted, and the
  availability check would pass on them.
