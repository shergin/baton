# The phase stays stored, beside the fetch

Status: accepted, 2026-10-05. Supersedes the derived phase of
[A handle keeps its fetch and derives its phase](a-handle-derives-its-phase.md),
by that record's own reopening line: its bench failed. Serves
[The store is the UI's state](../principles/store-is-the-ui-state.md).
Reopen if the verdict is made to cost less than a walk of every record the
operation's own selection reaches, under the 50 µs a read that record set.
Superseded in part on 2026-10-07 by
[The verdict is the root's, and the phase is derived from it](the-verdict-is-the-roots.md),
on the stored phase and the chain that settles it; the fetch as a value
stands.

## Context

The record this one supersedes decided two things: the fetch as a value
beside the phase, and the phase derived in its getter from what the store
holds. It set a gate on the second before it was built: a read of the phase
under 50 µs on the largest `@throwOnFieldError` operation the fixtures under
`spec/` answer. If the gate failed, the fetch's value was to ship alone and
the phase to stay stored.

## Decision

- The fetch is a value of the handle, as decided: `Fetch`, read as
  `fetch`, is `.idle`, `.inFlight` or `.failed(Failure, at:)`, with the
  failure and the instant it failed. A fetch that fails behind data, whoever
  started it, is read there by every view of the handle while the phase
  stays ready; the next response replaces it. `isRefreshing` is data
  present and a fetch in flight, and `retry()` with data behind it does not
  pass through loading.
- The phase stays stored on the handle and settled after each commit, as
  before the record this one supersedes. `Phase` keeps its three cases and
  its meaning.
- The chain that settles it, from the store's notice of a changed null,
  link or field error to each retained handle's walk, stays until the
  reopening line below is met.

## Evidence

- [`BENCHMARKS.md`](../../BENCHMARKS.md), "The re-evaluation a commit runs,
  for the handle step", 2026-10-05, on an Apple M1 Pro: the fixture under
  `@throwOnFieldError`, 899 records. The verdict, the field errors of the
  operation's own selection with none present, costs 567 µs untracked; with
  20 present, 785 µs; in a body's tracking scope, where every slot the walk
  reads registers, 4.56 ms. The gate allowed 50 µs. The commit that settles
  a stored phase costs 939 µs with the handle retained, against 136 µs
  without it.
- `61c3ac4` built the fetch as a value and left the phase stored.

## Not chosen

- Shipping the derived phase over the gate: a body reading the phase would
  pay a walk of the selection on every evaluation, and register every slot
  it read.
- Caching the verdict in the handle to make the read cheap: a stored phase
  under another name.
