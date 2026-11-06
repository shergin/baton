# A `@oneOf` input reads as an enum

Status: accepted, 2026-11-05. Serves
[Honest data](../principles/honest-data.md) and
[Relay's words](../principles/relays-words.md). Reopen if the
specification changes `@oneOf`'s rule, exactly one field given and that
one non-null.

## Context

The September 2025 edition of the GraphQL specification merged `@oneOf`
(graphql-spec#825): an input object of which exactly one field is
provided, with a non-null value. Relay v21 generates a strict
discriminated union for such an input, with `oneOfType: "relaxed"` as the
opt-out for migrations. Baton generated the same struct it generates for
any input: a property per field, every one optional, so a caller could
send none of them, or two, and the type said less than the schema.

## Decision

An input the schema declares `@oneOf` compiles to a choice, not a record.

- In Swift, an enum with a case per field, whose payload is the field's
  type made non-null, `indirect` when a field's type contains the input
  itself; `Hashable`, and an `InputObject` whose `variable` renders the
  object with its one member.
- In Kotlin, a sealed interface with a data class per field, equal by
  value, implementing `InputObject` the same way.
- A Swift case is named as the struct's property would be, by the same
  rules, so a field named like a reserved member or a keyword is spelled
  as it is spelled elsewhere. A Kotlin class is the field capitalized, and
  one named like a runtime or standard library type, a member, the
  interface itself or a type a sibling's field spells, which the nested
  class would shadow, takes an underscore, as the package's own types do.
- An input without `@oneOf` is the struct it was.

## Evidence

- The specification's September 2025 changelog lists OneOf input objects
  as merged (read through the Relay and working-group survey of
  2026-11-05).
- Relay v21.0.0's release notes: `@oneOf` inputs generate a strict
  discriminated union; `oneOfType: "relaxed"` opts out.
- The compiler as built: `pipeline/lower.rs` builds `InputFieldPlan`s
  from the schema's input object and reads none of its directives;
  `emit/shared.rs` and `emit/kotlin/shared.rs` print one shape.

## Not chosen

- The struct of optionals with a check at the render, a precondition that
  exactly one field is set: the dishonesty moved from the type to a trap.
- Relay's relaxed opt-out: it exists for migrations of generated types
  Baton has none of.
- A runtime type for one-of inputs: the shape is the compiler's to decide,
  and `InputObject` already says what a request carries.
