# The emitter writes Swift from typed pieces, not strings

Status: accepted, 2026-10-04; superseded on 2026-10-06 on the plan's
printer, which
[declares each of its selections once](a-plan-declares-each-selection-once.md);
the rest stands as decided here. Serves
[The compiler decides](../principles/compiler-decides.md) and
[Two runtimes, one compiler](../principles/two-runtimes-one-compiler.md).
Reopen when the Kotlin emitter starts, to weigh a quasi-quoter with back
ends for both languages against a second writer of our own; or when a
hazard arrives that the pieces below do not hold.

## Context

After Relay's front end the compiler has three steps: the plan, `decide`
and `emit`. `decide` builds a model of what is generated: a lens's
accessors, their forms, their guards. `emit` prints that model with
`writeln!` and `format!`. Nothing models the Swift that is written. An
identifier, a type, a reference and a declaration are all strings.

What that has cost:

- One class of defect, repaired a site at a time. About seventeen commits
  are named like "Keep fields from hiding a fragment's refetch query",
  "Escape variables named like Swift keywords" and "Underscore a type or
  field named Any": Swift's name lookup, or its keywords, in generated
  code. One change alone fixed five valid documents whose Swift did not
  compile.
- The rule that keeps a member from hiding a name is a comment at the top
  of the lens printer, and every printer has to remember it.
- A type is inspected as text: one printer asks whether a type's string
  ends in a question mark.
- Sixteen functions of that file pass a string of indentation, and the
  combinations of `throws` and a guard are written out case by case.
- `decide` carries the Swift spelling of a type, so an emitter for Kotlin
  cannot reuse it.

The files show the same habit. `decide/reader.rs` is 1,913 lines, a model
and the logic that fills it; `pipeline.rs` is 1,605, the plan's types, the
driver and the lowering; 34 of the compiler's 244 functions are longer
than fifty lines.

## Decision

- `emit` writes Swift from typed pieces. An identifier is escaped where it
  is made. A type is a structure: named, optional, a result, a list. A
  reference to what a member can hide, the runtime's module, a fragment or
  a query, is made by one function that knows the spelling nothing hides
  in that position. A declaration states its effects, and one printer lays
  it out. A writer owns indentation. The pieces are in `emit/swift.rs`,
  over the writer in `emit/writer.rs`; the plan's printer still lays out
  its one expression itself.
- Expressions inside a body stay templates. The pieces are ours, a few
  hundred lines, and no dependency is added.
- The output does not change by a byte. The goldens are the proof of the
  change.
- `decide` says what a scalar and a variable are in terms no language
  owns: what the store keeps them as, whether they are lists, whether they
  may be null. The Swift writer spells the type and picks the reader. The
  names `decide` allocates are still Swift's, and stay so until a second
  emitter needs them otherwise.
- Documents with hostile names are goldens: every Swift keyword and every
  name generated code declares or spells, in every place a document's name
  can stand. In each place a name is compiled, refused at the name, or a
  known defect. The names are read from the rules that list them, so a
  keyword or a reserved name added to a rule fails the tests until every
  place holds it.
- The compiler's files keep a model apart from its logic. The plan's types
  are in `pipeline/plan.rs`, apart from the lowering in `pipeline/lower.rs`
  and the driver. The model of a lens is in `decide/lens.rs`, apart from
  the merging of a selection into members, the checks a lens carries and
  the decisions. The longest functions are broken along their cases: a
  selection is lowered, and a member read, by one function per kind.

## Evidence

- The compiler as built, by reading, 2026-10-04: the lens printer has 89
  calls that write a line and 60 that format a string; the commits above
  are in its history; the rule against hiding is the comment at the top of
  `emit/lens.rs`.
- The change itself, 2026-10-04: the Swift written for every target with
  documents, the tests, the benchmarks and both examples, 21 files and
  about 14,260 lines, is the same byte for byte from the compiler before
  and after, and no golden changed. The pieces have tests of their own.
- The corpus of hostile names, 2026-10-04: 149 names in 19 places. It
  found names the compiler accepted and wrote Swift for that does not
  compile: four keywords `escape` does not list, `Self` as a member,
  `await` and `hashValue` as variables, `var` and `let` as a mutation's
  variables, `fields` in a mutation's payload, keywords as the names of
  fragments and operations, a mutation named like what its action spells,
  a variable named like its mutation, and a fragment named from an
  underscore. Each is a known defect in its tests, which fails once it is
  fixed. Beside the names, a spread that binds sixteen arguments or more
  writes an expression Swift cannot type-check in reasonable time.
- Relay's own compiler: its type generator has an `AST` of types that no
  language owns and a `Writer` per language, for Flow, TypeScript and
  JavaScript.
- The one general crate that writes Swift from Rust, genco 0.19.0, read
  the same day: a quasi-quoter with back ends for Swift and Kotlin among
  others. It handles layout, string literals and imports. Its Swift module
  says nothing of keywords, of escaping an identifier or of name lookup,
  which is where the defects were.

## Not chosen

- A full syntax tree of Swift, written in Rust: a large part of a language
  to keep, and by itself it stops no member from hiding a name.
- A quasi-quoter now. It takes over the layout, the smaller half of the
  problem, for a procedural-macro dependency and a change to every golden.
  It is weighed again when Kotlin needs the same templates.
- Text templates in files: no structure at all.
- Printing through Apple's swift-syntax: a real tree, in a Swift library,
  so every build would run a second tool, and only the macro target may
  depend on it.
- Leaving the printers as they are: the next hostile name is the
  eighteenth repair.
