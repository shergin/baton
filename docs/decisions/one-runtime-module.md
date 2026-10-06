# One runtime module, with edges as targets and a checked rule inside

Status: accepted, 2026-10-04. Serves
[The store is the UI's state](../principles/store-is-the-ui-state.md).
Reopen for a platform without SwiftUI, for a Kotlin runtime whose split
between core and interface is worth mirroring, or when optimisation across
the targets of one package is something a published library can rely on
and a bench shows what it recovers.

## Context

The runtime is one module of seventeen files. Its layers exist by
convention. `Store.swift` is 1,159 lines and does eight jobs. Three files
import SwiftUI, for the environment value, the three storages behind the
macros and one `ForEach` initializer, though the project's rule is that the
runtime depends on Foundation, Observation and SQLite. The store names its
environment. The recorded and the silent transports, which exist for tests
and previews, ship in every app. The planning log drew two targets, the
runtime and its interface, and the code never split.

Two of the first adopter's issues add edges: a store inspector
([#17](https://github.com/shergin/baton/issues/17)), and a guide for apps
that use no SwiftUI
([#25](https://github.com/shergin/baton/issues/25)).

A target is the stronger guard, because the compiler holds it. It is not
free everywhere. The read and the commit run across the record, the plan,
the ingest, the store and the lens, and they are inlined by an annotation
that stops at a module's edge.

## Decision

A boundary gets the strongest guard that costs nothing. Built 2026-10-05:
the script, `scripts/check-boundaries.sh`, with the store's name for its
environment as the one violation it lists; SwiftUI's part in one file;
`BatonTesting`. Still *(planned)*: `BatonInspector`, and the end of the
listed violation.

- One runtime module holds records, plans, the ingest, the store, the
  environment, lenses and transports: what the read and the commit cross.
- An edge is a target. What depends on the runtime, and the runtime never
  depends on, is a product of the same package: `BatonTesting` for the
  recorded and the silent transports, which need public API only, and
  `BatonInspector` for the inspector, which reads the store through
  `package` access.
- Inside the module a script holds four rules, in CI and among the local
  checks. One file imports SwiftUI. Only the disk's file imports SQLite.
  The record, the plan and the ingest do not name the store. The store's
  files do not name the environment or a transport.
- SwiftUI's part is confined to that one file and gets no target of its
  own for now, so a later split is a move and not a redesign.
- One concept to a file. `Store.swift` and `Environment.swift` are split
  as each seam in them is worked on, not as a project of its own.

## Evidence

- The module as built, by reading, 2026-10-04: the three files that import
  SwiftUI and the one that imports SQLite; 29 uses of `@inline(__always)`
  against one `@inlinable`, most of them in the ingest, the lens and the
  record.
- [`BENCHMARKS.md`](../../BENCHMARKS.md), 2026-10-04 at `2ba3d18`: an
  untracked read costs 25.9 ns a field at the median. That is the number a
  boundary through the read would have to keep.
- The installed Swift, 6.3.3, has an option to optimise across the targets
  of one package. Whether a library fetched by its tag may be built with
  it, and what it recovers, is not checked and not measured.
- No split of the core was built or measured. The decision is made so that
  none has to be.

## Not chosen

- A target for every layer. The compiler would hold each boundary, and the
  read and the commit would cross them: every hot internal becomes part of
  the module's interface to stay inlined, or stops being inlined.
- A target for SwiftUI's part now, as the planning log drew it. Every
  platform the project supports has SwiftUI, and every generated file's
  import would change.
- Convention alone, as built: three files import SwiftUI, and the store
  names its environment.
- The test transports inside the runtime, as built, and an inspector
  beside them: code for tests and for debugging in every app's binary.
