# The availability check and collection run on the main actor

Status: accepted, 2026-10-03; supersedes the planning log's concurrency
posture where it put collection's mark and the availability checks of
preloads off the main actor. Serves
[The store is the UI's state](../principles/store-is-the-ui-state.md).
Reopen if, on an iPhone 12-class device, a collection pass over the
lifetime bench's 9,000 records, or hydration of the fixture's 898 rows,
takes longer than a frame (16.7 ms), or if the two together miss a frame
on a screen the bench suite models. No iPhone 12-class device was at hand on 2026-10-05, when the plan's
ground step asked for the number; the line stands until one is.

## Context

The posture written before the store existed was that the main actor does
slot reads and commits and nothing else: decoding, normalization, the
image's writes, collection's mark and the checks of preloads would run off
it, against snapshots. As built, the ingest and the image's writes run off
the main actor, and three more things run on it: the availability check,
which reads the image when memory lacks a record (hydration); collection,
both the mark and the sweep; and, at a launch that asks the store before
the image has opened, the wait for the open. A mutation's optimistic
response is normalized on it too, through the same ingest. The vision, the
principle and the README still said that collection ran off it, and that
all normalization did.

## Decision

The main actor does slot reads, commits, the availability check with
hydration, collection, and the normalization of an optimistic response.
Decoding and normalizing a response run in the fetch's own task, the image
is written behind on its own queue, and the image opens off the main actor
when the app makes its environment before its first view.

Records are the main actor's state: observable objects whose slots bodies
read synchronously. A check on another actor could neither bind a lookup
nor fill a record from the image without coming back to the main actor
before the handle could be ready, and a ready that waits is the
asynchronous read path rule 2 forbids. A mark from a snapshot would copy
every reachable record's links for each pass, more work than the mark it
moves, and the sweep must clear records on the main actor anyway, because
bodies read them there. An optimistic response is a value the call site
passes, a payload's worth of fields; normalized on another actor, its layer
would wait for the hop back, and a frame could render without it.

## Evidence

From [`BENCHMARKS.md`](../../BENCHMARKS.md), Apple M1 Pro, release builds:

- Collection pass over about 9,000 records, marked from 10 roots, sweeping
  about 900: best 0.24 ms, median 3.8 ms, worst 4.6 ms (0.4.0).
- Hydration: the check reads the fixture's 898 rows into an empty store in
  1.72 ms best, 1.78 ms median; the same check with the records in memory
  takes 105 µs (0.6.0).
- A launch in a new process that asks the store the moment the image's
  handle exists: 4.68 ms best, the main actor waiting for the open; one
  that asks after the image has opened: 1.78 ms (0.6.0).

Each is under a third of a frame on that machine, and hydration is the
price of a first frame with data instead of a loading one.

## Not chosen

- A mark against a snapshot on another actor: a copy of every record's
  links per pass, and a sweep that still runs on the main actor.
- A budgeted, incremental sweep: not needed below a frame; the median
  above is the trigger.
- Hydration on another actor with a ready that arrives later: a warm launch
  would show a loading frame, which is what Baton exists to remove.
