# A handle keeps its fetch and derives its phase

Status: accepted, 2026-10-05. Serves
[The store is the UI's state](../principles/store-is-the-ui-state.md) and
[Honest data](../principles/honest-data.md). Reopen if the bench named
under Evidence fails its limits (then the fetch's value ships alone and the
phase stays stored), or if a reader outside a body needs the phase pushed to
it rather than computed when it asks. Superseded on the derived phase, by
its own reopening line, by
[The phase stays stored, beside the fetch](the-phase-stays-stored.md); the
fetch as a value is built as decided (`61c3ac4`). The policy and the
revalidation it left open are answered by
[Revalidation is one call the app makes](revalidation-is-the-apps-call.md).
Its derived phase is restored on 2026-10-07 by another route, the verdict
settled at the commit and kept on the root, by
[The verdict is the root's, and the phase is derived from it](the-verdict-is-the-roots.md).

## Context

A handle has three facts: whether the store holds its operation's data,
what the operation's directives make of that data, and the fetch. As built,
it keeps them in one enum. `Phase` has three cases: loading, ready with the
data's lens, and failed with `any Error` (`Operation.swift:72-76`). That the
data is present is implied by the phase: ready, or failed on field errors or
on a `@required` field that bubbled. What the directives make of the data, a
field error under `@throwOnFieldError` or a root that a `@required` field
bubbles to, is computed by `evaluate()` (`Operation.swift:213-222`) and
stored in the phase. The fetch is spread over `task`, `isRefreshing`,
`fetchTime`, `fetchEpoch` and `unplaced`, the errors the last response
carried that no field holds. `settle(_:)` compares a new phase with the old
one by hand (`Operation.swift:184-195`).

Three things follow.

- A failure behind data is kept nowhere. It is returned to whoever awaited
  `refetch()` (`Operation.swift:384-394`). A `storeAndNetwork` attach, an
  `invalidate()` or a `retry()` that fails behind data leaves no trace, and
  a second view of the same handle cannot tell. That is the complaint of
  [#5](https://github.com/shergin/baton/issues/5).
- The enum cannot say "failed, with data behind it", so the handle asks the
  error for its type: eight places in `Operation.swift` cast it to
  `FieldErrors` or `RequiredFieldError` (lines 188, 190, 233, 304, 348,
  389, 419 and 453).
- A stored phase goes stale when the store changes, so the runtime keeps a
  subscription of its own, where the principle says "The runtime has no
  subscriptions of its own." `noteNulls` raises `nullsOrErrorsChanged` on
  any write to or from null, any link moved to another record and any
  changed list of links (`Store.swift:473-488`), and a change to a field
  error or to whether a record is deleted raises it too
  (`Store.swift:455-471`). The commit then calls `environment.reevaluate()`
  (`Store.swift:265-269`), which calls every retained handle
  (`Environment.swift:88-94`), and each handle of an operation with
  `@throwOnFieldError` or a bubbling root walks its own selection again
  (`Operation.swift:448-458`), whether or not the commit touched its data.
  No bench covers that walk.

Three issues ask for the value that is missing: #5 for `lastError` and
`failedAt`, [#18](https://github.com/shergin/baton/issues/18) for a sweep
of the handles that are stale or failed, and
[#12](https://github.com/shergin/baton/issues/12) for `isReconnecting` and
`lastEventAt` on a subscription. The answer on #5 proposed the fetch as a
readable fact beside the phase, and left open whether the failure's time is
exposed too.

## Decision

A handle stores two facts and derives the third. All of it is *(planned)*.

- Stored: whether the store held the operation's data, at the handle's last
  availability check or at its own commit.
- Stored: the fetch, as a value a view reads as it is: idle, in flight, or
  failed, with the failure and when it failed. With it, the errors the last
  response carried that no field in the store holds.
- Derived, when it is read: the phase. With data, the getter reads the
  verdict and not the fetch's state. The verdict is the lens's static
  checks for `@throwOnFieldError` and for a root that bubbles, through
  tracked reads of the records, with the last response's errors that no
  field holds. So a refetch behind data re-runs no body that read only the
  phase. Without data, the getter reads the fetch.
- A body that reads the phase is invalidated by what the getter read and by
  nothing else: whether data is present; with data, the fields the verdict
  read, through the same channels as any lens read; without data, the
  fetch. The chain through the store goes: `nullsOrErrorsChanged`, the null
  half of `noteNulls`, `reevaluateIfNeeded`, `Environment.reevaluate`,
  `reevaluate()` on the handle protocol, `settle(_:)`, and the eight casts.
- `phase` keeps its three cases and its meaning: ready while data is
  present, unless the verdict fails it, and failed by a fetch only when
  there is no data to show. `isRefreshing` is data present and a fetch in
  flight. `retry()` with data behind a failed fetch does not pass through
  loading.
- A fetch's failure is one of the closed set of kinds of
  [A failure says its kind](a-failure-says-its-kind.md).
- A subscription's handle shows its stream's state the same way, as a
  value: connecting, open, waiting to reconnect, ended. That is not a
  `Phase` for subscriptions, which the planning log refused as a false
  loading. How a stream reconnects is proposed on #12 and is not decided
  here.
- A reader outside a tracking scope, a model or a test, computes the phase
  when it asks.
- It is measured before it ships. The verdict runs inside the reading
  body's tracking scope, so its reads are tracked reads. Two numbers are
  taken on the largest `@throwOnFieldError` operation that the fixtures
  under `spec/` answer: what a read of `phase` costs, and how many bodies
  re-run, beyond today's, on a commit that changes a value the verdict read
  and leaves the phase equal. The limits, written before the bench runs:
  under 50 µs for a read, and no extra body for an operation whose own
  selection is spreads. If either fails, the fetch as a value ships alone,
  the phase stays stored, and this record is superseded on that point.

Left open, to settle when it is built: the Swift spelling of the fetch's
value and of its properties; whether the handle keeps the fetch policy it
was attached with, which the answer on #5 proposed and the planning notes
refine without a decision; how a `storeOnly` attach without data reads
failed when no fetch is made, which goes with the policy; and the
revalidation method #18 asks for.

## Evidence

- A spike in the planning notes, 2026-10-04, on an Apple M1 Pro with
  macOS 26.5.2 and Swift 6.3.3. It models the mechanism: a record whose
  writes are silent and whose notification follows, as in a commit, and a
  handle whose phase is computed from its stored facts and a tracked read
  of that record. It shows semantics, not cost. Three properties ran. A
  reader of the derived phase is invalidated by the fields the verdict read
  and by no others: a change to a field the verdict did not read fired 0
  readers, and one it read fired 1. A refetch that failed behind data fired
  0, and the failure stayed readable beside the data. A tracking scope
  nested in another merges its accesses into the outer one, so a verdict
  computed under a scope of its own still leaves the body that asked
  depending on the fields behind it.
- The runtime as built, by reading: the chain and the casts that Context
  names. A reader outside a body already computes the verdict when it asks:
  `Environment.fetch` reads the operation's own selection before it throws
  for `@throwOnFieldError` (`Environment.swift:120-129`).
- [`BENCHMARKS.md`](../../BENCHMARKS.md), 2026-10-04 at `2ba3d18`, an M1
  Pro: a tracked read in a row body of eight fields costs 638 ns a field at
  the median, against 25.9 ns for an untracked read. The verdict walks only
  an operation with `@throwOnFieldError` or a root that bubbles, over that
  operation's own selection: an error inside a spread is the fragment's to
  weigh, as the terminology's *Throw on field error* says.
- The planning log of the review after 0.6.0 refused deriving the phase by
  wrapping the evaluation in the handle's own `withObservationTracking`: it
  registers every record of the selection on the main actor, re-arms on
  each change and fires at `willSet`. Deriving in the getter, under the
  reader's own scope, is not that. The spike is the new evidence, and it
  carries no further than the semantics it ran.
- Not measured yet: what a read of `phase` costs, and how many bodies a
  commit re-runs. Both numbers go into `BENCHMARKS.md` before it ships.

## Not chosen

- `lastError` and `failedAt` as stored properties beside a stored phase, as
  #5 asks, or `lastError` alone, as a review of the same code proposed.
  Either keeps the chain and adds fields to the state machine that has the
  problem.
- A fourth phase case, or `ready` carrying the error: every switch over the
  phase becomes a product decision.
- Deriving the phase under the handle's own observation scope: refused
  before, for the reasons under Evidence.
- A stored phase settled by hand after each commit, as built: a
  subscription the runtime keeps for itself, and a coarse one.
- A timer that refetches, or flips the phase, when a window closes: refused
  by
  [An operation states its expiration in its document](an-operation-states-its-expiration.md).
