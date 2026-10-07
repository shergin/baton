# A mapped scalar's host type is named per language

Status: accepted, 2026-10-07; amended 2026-10-07, the Kotlin entry's
shape. Serves
[The compiler decides](../principles/compiler-decides.md) and
[Two runtimes, one compiler](../principles/two-runtimes-one-compiler.md).
Built 2026-10-07. Reopen if Relay's `customScalarTypes` takes a shape of its
own for more than one language.

## Context

`config.rs` documents `customScalarTypes` as "the Swift type a custom scalar
reads as". The lowering puts that Swift type on the plan IR:
`TypePlan::Named.mapped` in `pipeline/plan.rs` is "the Swift type a custom
scalar reads as", filled in `pipeline/lower.rs` from the configuration. The
IR is meant to be the seam no language owns: `pipeline/plan.rs` opens by
saying nothing after it sees a Relay type, and a Kotlin emitter reads the
same IR.

The operation's `onError` has the same leak. `OperationPlan.error_behavior`
is a string filled from `OnError::swift_case`, the case of
`Baton.ErrorBehavior` that names the value.

## Decision

- `customScalarTypes` keeps Relay's key. A value is either a string, the
  Swift type as today, or an object by language, for example
  `{"swift": "Foundation.Decimal", "kotlin": {"type": "java.math.BigDecimal",
  "converter": "baton.scalars.Decimals"}}`.
- A language's entry has the shape that language needs. Swift's is the
  type, which conforms to `MappedScalar` and so parses and renders itself.
  Kotlin's is the type and the converter: a Kotlin type the runtime does
  not own cannot implement an interface, so an object implementing
  `ScalarConverter<T>` parses and renders it, and the compiler must be told
  the type, since nothing about a converter object names it.
- The plan carries the scalar's schema name, and each language's writer
  resolves the host type from the configuration.
- `OperationPlan.error_behavior` carries the `onError` value, not a Swift
  case name.
- The goldens prove each step: the Swift written does not change by a byte.

## Evidence

- The Kotlin emitter's first milestone, 2026-10-07: a constructor
  parameter of an input object or an operation needs its type, and a
  converter object named alone gives the compiler nothing to print for it;
  the entry became the type and the converter together.

- The compiler as built, by reading: the doc comment of
  `custom_scalar_types` in `compiler/src/config.rs`; `mapped` on
  `TypePlan::Named` in `compiler/src/pipeline/plan.rs`, and its doc
  comment; the lowering that fills it from
  `self.config.custom_scalar_types` in `compiler/src/pipeline/lower.rs`;
  `error_behavior: Option<String>` on the operation's plan, filled by
  `behavior.swift_case()` in the same file; `OnError::swift_case` in
  `config.rs`.
- The seam as stated: the module comment of `pipeline/plan.rs`.

## Not chosen

- A second key per language: Relay has one key, and a web project already
  has it.
- The Swift type on the IR, with the Kotlin writer translating it: a Swift
  name is not a fact of the schema, and the translation would be a table
  from one language's types to another's.
