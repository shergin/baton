# The image evicts by launch before it starts over

Status: accepted, 2026-10-11. Answers
[#16](https://github.com/shergin/baton/issues/16)'s eviction and the
plan's D-N19. Serves [The store is the UI's state](../principles/store-is-the-ui-state.md).
Reopen the granularity when an app shows an image whose one launch's rows
outgrow the limit and must keep part of them; reopen a rule per type never.

## Context

An image over its size limit was deleted at open and started again: a cold
start, with every launch's rows gone, for a file that was mostly rows no
recent launch had read. The rows already record the generation, a launch
counter, that last used them, and the writer's first batch of a launch
drops the rows no launch has used since the one before last. #16 asked for
eviction by recency under a budget, and for a budget per type.

## Decision

At open, a file over its limit evicts before anything else: first the rows
last used before the previous launch, the ones the writer's first batch
would drop, then the previous launch's, rebuilding the file after each so
the size checked is the rows that remain. Only a file still over the limit
with nothing left to evict starts again. Recency is the launch's, since
that is what the rows record, and there is no rule per type: a type's rows
are as recent as their reads.

## Evidence

The measurement is in `BENCHMARKS.md`: an image written past a small limit
over two launches, opened a third time, keeps the last launch's rows and
opens in the time the row below records, where the start over kept nothing.
A test holds the file over the limit with rows from two launches and reads
the last launch's rows after the open; another, with a limit below what an
empty file takes, finds nothing left to evict and the file made again.

## Not chosen

- Recency per read. A write per read, on the main actor's path, for a
  granularity no app has asked for.
- A budget per type. `Retention(types:)` and a rule per type were refused
  on #16: a policy object at run time for what recency decides.
- A background trim. The open is where the size is known and the file is
  idle; a trim during a session would race the writer for a cache that
  shrinks at the next launch anyway.
