# A format is per emitter

Status: accepted, 2026-10-07. Serves
[The compiler decides](../principles/compiler-decides.md). Built as
decided: nothing moves. Reopen if the plan IR is ever written out and read
as data by something other than the compiler.

## Context

What generated Swift names in the Swift runtime is fenced by one number.
`compiler/src/emit.rs` declares `pub const FORMAT: u32 = 16`; generated
code writes `static let format = Baton.Format16.self` in its `Types` enum;
`swift/Sources/Baton/Plan.swift` declares `Format16` and keeps every earlier
marker unavailable, with a message. `CLAUDE.md` states the rule: a change
to what generated code names raises the number on both sides in one commit.
Nothing says what the number means for a second runtime.

## Decision

- A format is per emitter. The Kotlin emitter gets its own number and its
  own fence, enforced the way its language allows.
- The plan IR between the emitters is not serialized and carries no number.
- The two emitters change together when the plan's shape changes, and apart
  when one language's interface does.

## Evidence

- The compiler and the runtime as built, by reading: `FORMAT` in
  `compiler/src/emit.rs`; the line that writes the marker in
  `compiler/src/emit/shared.rs`, and the same line in the golden
  `compiler/src/tests/goldens/Baton.baton.swift`; the markers in
  `swift/Sources/Baton/Plan.swift`, from format 1 to the available
  `Format16`.
- What the fence guards is one language's interface: the messages on the
  unavailable markers name changes to Swift's generated code, such as a
  schema enum reading as the Swift enum generated for it.

## Not chosen

- One number shared by both emitters: a Swift-only interface change would
  raise Kotlin's number for nothing, and the reverse.
- A versioned IR: nothing reads it as data.
