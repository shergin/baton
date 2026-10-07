# The verdict is the root's, and the phase is derived from it

Status: accepted, 2026-10-07. Serves
[The store is the UI's state](../principles/store-is-the-ui-state.md) and
[What earns a concept](../principles/what-earns-a-concept.md). Supersedes
[The phase stays stored, beside the fetch](the-phase-stays-stored.md) in
part, on the stored phase and the chain that settles it; the fetch as a
value stands. Restores the derived phase of
[A handle keeps its fetch and derives its phase](a-handle-derives-its-phase.md)
by another route. Built 2026-10-07, behind the phase script of format 2 of
`spec/manifest.json` and the gate below. Reopen if a measurement shows the
walk at the batch's end costing more than the chain it replaced.

## Context

A stored phase goes stale when the store changes, so the runtime keeps one
subscription of its own. A batch that changes a null, an error or a link
sets `nullsOrErrorsChanged` in `Store.swift`; `reevaluateIfNeeded` calls
the closure `phasesNeedSettling`, which `Environment.swift` sets to its
`reevaluate()`; that calls `reevaluate()` on every retained handle, through
`AnyOperationHandle` in `Operation.swift`; and each handle of an operation
with `@throwOnFieldError` or a bubbling `@required` root walks its
selection through generated code, `Op.Data.fieldErrors` and
`Op.Data.missingRequiredField`, and stores a new phase through `settle`,
whose three rules make ready after ready, equal field errors and an equal
required path no change.

The phase is the one fact about data a handle stores rather than reads.
The store's closure is a pointer to the environment that the boundary
script does not see, because it names nothing.

The record this one supersedes in part decided on a bench that deriving the
phase at read time costs too much. Neither record weighed a third shape:
the verdict settled at the commit and kept on the root.

## Decision

- `Store.Root`, already observable and already carrying `fetchTime`, gains
  `verdict`, which is sound, or field errors, or a required path, and
  `present`, whether the store holds the operation's data.
- The store settles both at the end of a batch that changed what a verdict
  reads, for roots whose plan has a policy, by the same generated walk the
  handle runs today: the root holds its handle weakly as its judge, and
  asks it. A closure stored on the root was measured and refused (Evidence).
- The handle's `phase` derives from `root.present`, `root.verdict`, its own
  `fetch` and the errors the last response carried with no field to hold
  them. Nothing walks at read, and no phase is stored. A verdict that did
  not change is not a change, so `settle` and its rules are not needed.
- `settle`, `phasesNeedSettling`, `Environment.reevaluate` and
  `AnyOperationHandle.reevaluate` go. The handle is a view of a root entry,
  which is the store's, and of a fetch, which is the environment's.
- The cost is today's: the walk runs as often, at the batch's end instead of
  in the environment's loop.
- The gate: the phase scripts are written first, so the move is
  behaviour-frozen under `spec/`; the commit of the strict fixture with a
  retained handle stays within the spread of today's 939 µs; the
  deterministic counts in `benchmarks/counts.txt` do not change.

## Evidence

- [`BENCHMARKS.md`](../../BENCHMARKS.md), "The re-evaluation a commit runs,
  for the handle step", the ground step of 2026-10-05 on an Apple M1 Pro:
  the fixture under `@throwOnFieldError`, 899 records. The verdict costs
  567 µs untracked and 4.56 ms in a body's tracking scope, against the 50 µs
  the first record allowed a read. The commit costs 939 µs with the handle
  retained, against 136 µs without it; that walk is the one this record
  moves, not adds.
- The runtime as built, by reading: `Store.swift` raises
  `nullsOrErrorsChanged` and calls `phasesNeedSettling` in
  `reevaluateIfNeeded`; `Environment.swift` assigns it to `reevaluate()`,
  which loops over the retained handles; `Operation.swift` declares
  `reevaluate()` on `AnyOperationHandle`, and the query handle's `evaluate()`
  reads `Op.Data.fieldErrors` and `Op.Data.missingRequiredField` and stores
  the result through `settle`. `Roots.swift` declares `Root` `@Observable`
  with `fetchTime`.
- [`BENCHMARKS.md`](../../BENCHMARKS.md), the verdict step, 2026-10-07,
  an A/B against `039aa2d` on the same loaded machine: the commit with a
  retained handle 958 µs against 1.01 ms, the clearing commit 745 against
  784 µs, the plain commit equal, the counts unchanged. The gate held. A
  closure made in the handle's generic initializer and stored on the root
  cost the same walk 200 µs more; the root asks the handle through a
  protocol instead.

## Not chosen

- The chain as built. Its cost is not the argument; its home is: a
  subscription the runtime keeps for itself, from the store into the
  environment through a closure, settling a fact about data on a handle.
- The verdict computed by the plan instead of generated code. The
  normalization plan has every spread inlined, as `pipeline/lower.rs` says,
  so it cannot tell the operation's own selection from a spread's, and
  `@throwOnFieldError` weighs only the operation's own.
- The phase derived at read time by a walk of the selection, as the
  superseded record measured: 567 µs a read untracked, and every slot it
  read registered in the body.
