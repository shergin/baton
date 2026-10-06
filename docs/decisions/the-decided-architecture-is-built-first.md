# The decided architecture is built first, one release a step

Status: accepted, 2026-10-05. Serves
[What earns a concept](../principles/what-earns-a-concept.md). Reopen if
an adopter is blocked by something this order puts late and no step before
it unblocks, or if a step's gate fails and the next cannot move up.

## Context

main is at `0ff2407`, 272 commits after 0.6.0's release commit, `e88e47b`,
which was never tagged. The last GitHub release is 0.5.0, of 2026-10-03.
No release has published the compiler's bundle. `compilerRelease` in
`Package.swift` is empty (`Package.swift:9`), so no package can depend on
Baton by its tag, and CI's `consumer` job, which builds such a package,
runs with `continue-on-error` for that reason (`.github/workflows/ci.yml`).
The release workflow that would publish the bundle
(`.github/workflows/release.yml`) has never run.
[#8](https://github.com/shergin/baton/issues/8) asks for prebuilt compiler
binaries, and the answer on it said that what is missing is a release that
publishes them.

Ten records accepted on 2026-10-04 describe a runtime that is not built:
[The environment is the session](the-environment-is-the-session.md),
[An image belongs to one store](an-image-belongs-to-one-store.md),
[The store owns roots and ages](the-store-owns-roots-and-ages.md),
[A fragment has one reading](a-fragment-has-one-reading.md),
[A mapped scalar is a fallible read](a-mapped-scalar-is-a-fallible-read.md),
[An operation is sent as its text or its id](an-operation-is-sent-as-text-or-id.md),
[Client data is described by the schema and written by a payload](client-data-is-described-and-committed.md),
[An operation states its expiration in its document](an-operation-states-its-expiration.md),
[Keys a session produces belong to its store](session-keys-belong-to-the-store.md)
and [One runtime module](one-runtime-module.md). Two more are accepted with
this one:
[A handle keeps its fetch and derives its phase](a-handle-derives-its-phase.md)
and [A failure says its kind](a-failure-says-its-kind.md).

They depend on each other, by their own words. The commit stamps an
operation's age, so the commit has to know its operation; as built it is
handed a change set and nothing else (`Store.swift:249`). An ended store
commits nothing, checked where a change set reaches the main actor, and
the end drops the roots, which the store is to own. A handle still held
says `gone` through its phase. Keys a session produces are freed by the
store's collector and dropped at the store's end. The store's pointer to
its environment goes when its uses go: the settling of phases with the
handle's phase, a logged `@required` field with the report.

The first outside adopter filed twenty-one issues. Nineteen were answered
on 2026-10-04 with what stands and what is refused; the two that ask for a
Kotlin runtime were not. A review of 2026-10-04 asked what the next release
is for and left it open. The release planned next, before this record, was
tooling and previews. [What earns a concept](../principles/what-earns-a-concept.md)
holds that breadth costs depth, and that a feature is a composition of the
concepts that exist.

## Decision

What is decided is built before any feature, one step to a release.

- The next release is what is on main, once three things are in. The
  boundary rules of [One runtime module](one-runtime-module.md) become a
  check that runs in CI and among the local checks, with the moves that
  need no design: SwiftUI's part in one file, and the recorded and the
  silent transports in `BatonTesting`. The compiler refuses what the
  runtime cannot hold, a list of lists, instead of emitting a flatter type.
  And a handful of small corrections that need no decision. The release
  publishes the compiler's bundle, so that a package can depend on Baton
  by its tag and CI's `consumer` job becomes a gate. `v0.6.0` is tagged on
  its release commit, for the record.
- Then the decided architecture, one release a step, in the order the
  records' dependencies give:
  1. The handle:
     [A handle keeps its fetch and derives its phase](a-handle-derives-its-phase.md).
  2. The write: one way for a payload to become slots, of which
     `commitPayload` is the public door
     ([Client data is described by the schema and written by a payload](client-data-is-described-and-committed.md)).
  3. The lifetime:
     [The store owns roots and ages](the-store-owns-roots-and-ages.md) and
     [An operation states its expiration in its document](an-operation-states-its-expiration.md).
  4. The session:
     [The environment is the session](the-environment-is-the-session.md)
     and [An image belongs to one store](an-image-belongs-to-one-store.md).
  5. The keys a session produces, when their spike has chosen a mechanism:
     [Keys a session produces belong to its store](session-keys-belong-to-the-store.md).
- Beside those steps, work that touches other files, each once the step it
  composes from has moved the files it needs, in the order of what blocks
  an adopter. First, identity configured in `baton.json`
  ([#10](https://github.com/shergin/baton/issues/10)) and trusted documents
  ([#7](https://github.com/shergin/baton/issues/7),
  [An operation is sent as its text or its id](an-operation-is-sent-as-text-or-id.md)).
  Then the rest of the wire (credentials read per attempt, and
  [A failure says its kind](a-failure-says-its-kind.md)), mapped scalars
  ([A mapped scalar is a fallible read](a-mapped-scalar-is-a-fallible-read.md)),
  the compiler's report and the tools (#8,
  [#17](https://github.com/shergin/baton/issues/17),
  [#22](https://github.com/shergin/baton/issues/22),
  [#23](https://github.com/shergin/baton/issues/23)), and `@inline` when
  its trigger fires
  ([A fragment has one reading](a-fragment-has-one-reading.md)).
- A feature lands only as the composition its seam leaves: no issue is
  built before the step it is composed from.
- Every step is a tagged release with the compiler's bundle in the tag. A
  step whose gate fails parks, and the next moves up.
- Version numbers and release names are not part of this record.

## Evidence

- The repository, by running `git` and `gh` on 2026-10-05: 272 commits
  from `e88e47b` to `0ff2407`; tags from `v0.1.0` to `v0.5.0`, and no
  `v0.6.0`; 0.5.0 the latest GitHub release, published 2026-10-03 with no
  file attached; no run of the release workflow; `compilerRelease` empty,
  and the `consumer` job `continue-on-error`.
- The compiler as built, by reading: it lowers whether a field is a list
  as one flag (`compiler/src/pipeline/lower.rs:623` and `:662`), so a list
  of lists has no type of its own. The planning notes record a review that
  compiled `[[Int!]!]!` and got `[Int]`.
- The dependencies, read from the records: the ones Context names.
- The planning notes hold three orders that reviews proposed: one put the
  fetch first, one the store's ownership and the end, one the module's
  boundary check and the plan's type. This order keeps the first's
  dependencies, makes the third's check its ground, and puts the session
  before the plan's work, because the session is where the adopter's
  privacy requirement sits.
- Nothing is measured: this record orders work, and each step carries its
  own numbers.

## Not chosen

- The issues in the order adopters are blocked, with the architecture
  under them: each would be built on a seam the next step moves, and built
  again.
- The next release as planned before, tooling and previews. Previews are
  what `commitPayload` gives, in the write step, and the tools come with
  the compiler's report, beside the steps.
- One release at the end of the steps: no baseline to break from
  meanwhile, no bundle for adopters, and CI's `consumer` job never a gate.
- Releasing main before the boundary check: the first release an app can
  depend on would ship the test transports in every app, in a module whose
  rules are not held, and the next release would break the import.
