# A mapped scalar is a fallible read

Status: accepted, 2026-10-04. Serves
[Honest data](../principles/honest-data.md) and
[Relay's words](../principles/relays-words.md). Reopen if a mapping whose
conversion cannot fail has to keep the schema's nullability, or if a
product shows documents where an annotation on every mapped field costs
more than it protects.

## Context

A custom scalar is stored as its text, exactly as the server wrote it, and
reads as a `String`. The first adopter asked for a mapping at the lens
([#11](https://github.com/shergin/baton/issues/11)): `customScalarTypes` in
`baton.json`, Relay's key, so that `Decimal` reads as `Foundation.Decimal`,
`DateTime` as `Date`, `Url` as `URL`. The slot keeps the text and the
accessor converts.

The open question was what a non-null mapped field reads when the text
does not convert. As built, a non-null field whose value the generated
type cannot hold reads as the type's zero value and is reported: an empty
string, `0`, `false`, an empty list. The issue says an amount that does
not parse must never render as `0`. It asks for nil, on an accessor it
also wants non-optional. A mapped type has no honest zero either: zero is
an amount, a date's zero is a date, and a `URL` has none.

## Decision

Types follow what the schema promises. A non-null custom scalar promises
that a text is there. It does not promise that the text converts to the
type the client chose. So a mapped scalar is a fallible read, and its
accessor says so. This binds the mapping when it is built *(planned)*.

- A mapped scalar's accessor is optional, wherever the schema puts the
  field, unless a directive says what a failure does. Under `@required` it
  is non-optional, and a failure bubbles to the enclosing lens or throws.
  Inside `@catch` it is a `Result` whose failure holds the error. Under
  `@throwOnFieldError` it is non-optional, and a failure throws at the
  fragment or fails the operation. This is the typing a field that can
  carry an error in place already has.
- No mapped scalar reads as a zero value, and the mapping asks no type for
  one.
- A value that does not convert is reported as unexpected, never as
  missing: the heal would refetch it forever.
- A conversion that cannot fail keeps the schema's nullability. A
  generated enum with a case for a value this build does not know, as
  proposed with the same feature, stays non-optional on a non-null field.
- What the schema does promise is read as before. A null where it says
  non-null, or a value of another kind, reads as the type's zero value and
  is reported. Missing data reads as a zero value and is healed.
- Where a failure is detected is not decided: at the read, with the checks
  behind `@required` and `@throwOnFieldError` converting too, or once at
  ingest, as a field error stored beside the field. The mapping's design
  and the read bench decide.

## Evidence

- The readers as built: `requiredString`, `requiredInt`, `requiredDouble`,
  `requiredBool` and the list readers answer a null, a missing value and a
  value of another kind with `""`, `0`, `0`, `false` and `[]`, and report
  it.
- The ingest as built: a custom scalar is kept as its text and nothing is
  parsed. A built-in scalar's token of another kind fails its response
  with an `IngestError`, so the strict end of the rule exists already.
- The terminology's *Error behavior* and *Throw on field error*: a field
  that can carry an error in place is non-optional under
  `@throwOnFieldError` and inside `@catch`, and optional elsewhere. The
  decision adds no rule; it places mapped scalars under this one.
- Not measured yet: what a conversion costs at a read, which the issue
  asks the read bench to record, and what it costs again in a check.

## Not chosen

- A zero value and a report, the rule as built, for mapped types. Each
  type would owe the mapping a zero, `URL` has none, and a zero amount
  looks like data.
- The issue's shape as written: non-optional on a non-null field and nil
  on a failure. One accessor cannot be both.
- Failing the whole response when one value does not convert: one bad URL
  in a feed would fail the feed. How far a field's failure reaches belongs
  to the directives.
- Trapping, which the principle refuses.
- A wrapper that holds the value or the raw text: `@catch` already gives a
  `Result`.
- Non-optional accessors that trust the server to send what converts: the
  amount that does not parse has no answer then.
