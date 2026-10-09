# A plan declares each of its selections once

Status: accepted, 2026-10-06; supersedes the line of
[The emitter writes typed pieces](the-emitter-writes-typed-pieces.md) that
left the plan's printer laying out one expression. Serves
[The compiler decides](../principles/compiler-decides.md). Answers
[issue 34](https://github.com/shergin/baton/issues/34). Reopen when one
distinct selection is large enough to strain the type checker alone, or
when resident plans across operations are measured to matter.

## Context

An operation's plan was one Swift expression: every selection nested in
the field that selects it, and a fragment written out again at every
spread. Under a union inside a union the copies multiply, and Swift checks
the expression as one constraint system. The issue's generator, eight
sections of twenty cards of ten metas, wrote 2,258 selections into one
expression of 1.2 MB from a document of 5 KB; Swift was killed at 12 GB.

## Decision

- The plan's printer writes each distinct selection once, as a private
  static member of the operation with its type stated,
  `private static let selection1: Baton.Selection = ...`. The root is
  `selection0`, and each selection follows the first that refers to it, so
  a plan reads from the top down. A field refers to the selection it
  selects by its bare name.
- Two selections are the same when their Swift text is: the same type,
  key, fields, slots, guards, labels and the selections below them. A
  fragment spread in two places shares its plan only where every fact of
  it is equal, so `@arguments`, `@include`, `@catch` and `@defer` keep
  their own copies.
- The runtime is unchanged. `Selection` is a class and nothing keys by its
  identity, so a selection several fields refer to is one object, and a
  selection that reads no variables keeps one resolution for all of them.
  The format does not change: the generated code names what it named.
- Amended 2026-10-09: which selections are distinct and which number each
  takes is decided once, in `compiler/src/decide/selections.rs`, by the
  facts the normalization decided (the type, key, fields, slots, guards,
  labels and the selections below), and both emitters print that table;
  the Kotlin plan takes the same numbers. Neither emitter's goldens
  changed by a byte, so the sameness is the one stated above.

## Evidence

Measured 2026-10-06 on an Apple M1 Pro, macOS 26.5.2, Swift 6.3.3, with
the issue's generator; whole-module compiles of the generated file with
`swiftc -c -wmo`, debug, one job. Recorded in `BENCHMARKS.md`.

| S x C x M | Selections before | Declared now | Before | Now |
|---|---|---|---|---|
| 4 x 10 x 5 | 370 | 43 | 23.7 s, 3.2 GB (type check alone) | 1.1 s, 0.19 GB |
| 8 x 20 x 10 | 2,258 | 82 | killed at 12 GB in the issue | 1.7 s, 0.24 GB |
| 10 x 50 x 20 | 12,022 | 184 | not tried | 4.0 s, 0.36 GB |

Hoisting without sharing, the issue's workaround, still wrote one
declaration per copy: 31.7 s to type-check at 10 x 50 x 20.

The hostile-name corpus found that `Self.selection0` reads a variable
named `Self`; the bare name finds the static member before a variable
named like it.

## Not chosen

- One plan per fragment, shared by every spread: a fragment's plan depends
  on where it is spread, its arguments, guards, `@catch` and `@defer`.
  Equality shares exactly where sharing is sound.
- Plans as data decoded on first use: the references to `Types` and
  `Slots` would no longer be checked by the compiler, and the runtime
  would gain a decoder.
- Sharing across operations, in the shared file: every document's change
  would recompile it, for memory not yet measured to matter.
- A nested type holding the selections: it would hide a fragment of its
  name inside the operation, and take a name from every module.
