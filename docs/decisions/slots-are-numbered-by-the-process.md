# Slots are numbered by the process, not by the compiler

Status: accepted, 2026-10-03. Serves
[The compiler decides](../principles/compiler-decides.md) and
[Two runtimes, one compiler](../principles/two-runtimes-one-compiler.md).
Reopen if a build step sees every module of an app and the exact schema each
was compiled against, or if a measurement shows the numbering on a path a
view or a commit takes more than once.

## Context

A record stores a field's value at a slot: a small integer per storage key
and type. The principle says storage keys are settled at build time and that
the runtime never hashes a field name, so the obvious reading is that the
compiler writes the integers into the generated code. A review of 0.6.0
proposed exactly that.

The compiler runs once per module. The modules of an app are compiled
independently and share one store, so two modules must agree on the slot of
`Character.name` without having seen each other.

## Decision

The compiler computes every storage key and emits one constant per key and
type (`Slots.Character_name`). The number behind a constant is assigned by
the process the first time the constant is touched, in a table all modules
share. No slot number is ever written into generated code, a plan or the
image.

What the principle's rule means under this decision: a name may be hashed
where a key is first met (a constant's initialization, the resolution of a
plan for a key with variables, an abstract field's first read on a concrete
type) and nowhere a view or a commit passes again. Accessors for keys without
variables on concrete types keep this today. Keys with variables, and fields
read through an interface or union, still go through the table on every read
at 0.6.0; resolving them once is *(planned)*, and is a defect against the
principle, not part of this decision.

## Evidence

- `BatonBenchmarks` (`BENCHMARKS.md`, 0.6.0): an untracked read through a
  constant slot costs 28 ns a field. The numbering is paid once per key per
  process, not per read.
- `BENCHMARKS.md`, 0.4.0: records pre-sized to their type's slot count cost
  the scroll bench 1 KB a record (+15.8 MB against +4.4 MB). Numbers taken
  from the schema would size every record by its type's declared fields: the
  same failure at the schema's scale.
- The image stores type names and storage keys by name because slot numbers
  belong to a process ([The image is the system's SQLite](the-image-is-sqlite.md)).
  It survives a build with other documents because nothing in it is a number
  a compiler chose.

## Not chosen

- Numbers assigned by the compiler per module: two modules number
  `Character.name` differently and write each other's fields.
- Numbers derived from the schema, a field's position in its type, the one
  input every module shares. Records become as wide as the schema's types
  instead of as wide as what the app selects; two modules built against
  different revisions of the schema disagree silently, where names still
  agree; and a key with arguments has no position.
- A numbering step after every module has compiled: build-tool plugins run
  per target and see no other, and the image would need names regardless.
- A hash of the key as the slot: a record would be a hash table again.
