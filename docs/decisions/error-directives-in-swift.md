# Relay's error directives in Swift's terms

Status: accepted, 2026-10-03. Serves
[Honest data](../principles/honest-data.md) and
[Relay's words](../principles/relays-words.md). Reopen if a product needs a
throwing read on fields that carry no directive, or if Swift gains typed
throws broad enough to carry the field's error type through accessors.

## Context

Relay's reader has one way to say "this cannot be shown": throw during
render, and let an error boundary catch it. `@required(action: THROW)`,
`@throwOnFieldError` and the `@catch` that stops them all lean on that. A
SwiftUI body cannot throw, and a lens accessor is read inside one. The
question was how each directive reads in Swift without inventing a word.

## Decision

- `@required(action: NONE | LOG)` nulls the enclosing object in Relay; here
  the accessor that produces the enclosing lens returns nil. The compiler
  generates a `satisfied` check on every lens whose required children can
  bubble, and every producer of such a lens (linked field, spread, list
  element, connection node) runs it with tracked reads. LOG reports the path
  through `Environment.requiredFieldMissing`. A root that bubbles fails the
  operation: `Phase` has no null data.
- `@required(action: THROW)` throws at the read: the field's own accessor is
  `get throws` and raises `RequiredFieldError`. Nothing else in the lens is
  affected.
- `@catch(to: RESULT)` is a `Result<T, FieldErrors>` accessor whose failure
  holds the field's error and everything below it; `to: NULL` is the plain
  optional accessor.
- `@throwOnFieldError` on a fragment makes its spread accessor `get throws`;
  on an operation it puts the handle in `.failed(FieldErrors)` while the data
  stays in the store. Semantic non-null types follow Relay's rule: under
  `@throwOnFieldError` or inside `@catch`.
- Field errors are stored beside the field they name, resolved by path at
  ingest, and cleared by the next payload that answers the field. A plain
  accessor keeps reading an errored field as null.

## Evidence

- The delivery tests (2026-10-03): a `@catch` read, a plain read and a cached
  read of the same errored field agree with the response; NONE drops a list
  element and nothing else; LOG reports `status` once; THROW throws
  `RequiredFieldError` and the semantic field beside it reads `String`;
  `@throwOnFieldError` fails the operation on an uncaught error and not on a
  caught one.
- The bench: a `@catch` read of a field without an error costs 122 ns against
  29 ns for a plain read (a `Result`, a closure and the error lookup); a
  `satisfied` check of a lens with one required field costs 29 ns; twenty
  field errors add about a quarter of a millisecond to the ingest of the
  686 KB fixture, most of it the index of entries the path walk needs.
- The GitHub sample: a missing repository comes back as `null` with a field
  error, and `repository @catch` shows the server's sentence instead of a
  guess.

## Not chosen

- Throwing accessors everywhere, so that any error could surface at the
  read: every body would be a `try`, and the schema's nullability would stop
  meaning anything.
- `Result` everywhere: the same, in a different spelling.
- Dropping THROW: it is Relay's word for "this view cannot render", and
  `get throws` says exactly that at exactly the read.
- A null `Data` for a bubbling root, as Relay returns: `Phase.ready(nil)` has
  no meaning a view could render; `.failed` names the field.
