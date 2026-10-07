# A mapped scalar converts at the read

Status: accepted, 2026-10-11. Builds on
[A mapped scalar is a fallible read](a-mapped-scalar-is-a-fallible-read.md),
which settled the typing and left the mechanism open. Serves
[Honest data](../principles/honest-data.md) and
[Relay's words](../principles/relays-words.md). Reopen if the read bench
shows the conversion dominating a body's read, which would move the
detection to the ingest as a field error stored beside the field; or if an
adopter needs a format the shipped conformances do not read.

## Context

The first decision made a mapped scalar's accessor optional unless a
directive covers it, refused zero values, and left three things to the
build: the contract between the configuration and the Swift type, where a
failure is detected, and what each directive reads as in code. The issue
([#11](https://github.com/shergin/baton/issues/11)) asked for a protocol
over the store's `Value`, a `raw:` reader beside the mapped one, and
reporting through the missing-data channel; the owner's review corrected
all three.

## Decision

- **The configuration is Relay's.** `customScalarTypes` in `baton.json`
  maps a custom scalar's name to the Swift type it reads as, written as
  Swift spells it, qualified or not: `"Decimal": "Foundation.Decimal"`. A
  name that is not a custom scalar of the schema is an error at the
  configuration. An unmapped custom scalar reads as `String`, as before.
- **The contract is over the text.** `MappedScalar` has `init?(scalarText:)`
  and `scalarText`. The store keeps the scalar's text as the server wrote
  it, so the oracle rule holds unchanged, and a variable of the type is
  sent as its text. Baton conforms `Decimal` (the POSIX locale, so no
  amount passes through a `Double` or a user's separators), `Date` (ISO
  8601's internet profile, with fractional seconds or without, written with
  them), `URL` and `UUID`; each format is one, and a fixture pins it.
- **Detection is at the read, and nothing is cached.** The accessor
  converts the text each time it is read. The conversion's cost is
  recorded in the read bench, per field, beside the string read it
  replaces.
- **A failure is a value the type cannot hold**, reported through
  `reportUnexpected`, never through the missing-data channel: the heal
  answers missing data with a refetch, and a text that does not convert
  would be refetched forever.
- **Each directive reads as its typing says.** Plain or non-null in the
  schema: `T?`, nil on a failure. `@required` of any action and
  `@throwOnFieldError`: `T`, a throwing getter, since a value that does not
  convert has no zero to stand in; under `@required(action: NONE)` or `LOG`
  the lens is unsatisfied as a null would leave it, and bubbles. `@catch`:
  a `Result` whose failure carries the conversion's error under the
  field's response path; on a non-null field a null is a failure too.
  Under `@throwOnFieldError` the fragment's `fieldErrors` include the
  conversion's error, so the fragment throws or the operation fails as the
  policy says. Under `@throwOnFieldError` a field the schema types nullable
  stays optional, as a plain scalar does. Lists keep the list rule: an
  element that does not convert is reported once, left out of a list of
  non-null elements, and nil in a list of nullable elements.
- **No raw accessor.** One field, one type. The slot's text is still what
  the store holds and the image writes; a document that wants the text
  leaves the scalar unmapped.

## Evidence

- The fixture `spec/tests/asset-prices.json`: an exact decimal of 29
  digits read back as that `Decimal`, a date with and one without
  fractional seconds, an empty URL, and three values the types cannot
  hold, which read as nil and are reported.
- The compiler's probe before this record: `@catch` on a mapped field
  emitted `Result<T?, FieldErrors>` where the schema says non-null, and a
  list emitted a conversion check of its own; both corrected before the
  goldens were blessed.
- The read bench, 2026-10-11 (`BENCHMARKS.md`, "mapped scalars"): an
  untracked `Decimal` read costs 567 ns best and 589 ns at the median
  against 31.5 ns for the string read beside it, on a loaded M1 Pro; about
  eighteen string reads, or one tracked read of a field. The cost is
  Foundation's `Decimal(string:locale:)`.
- The owner's review of #11 (2026-10-04): the protocol over the text, the
  failure as unexpected, no raw accessor; and enums at the same boundary,
  which the next change takes.

## Not chosen

- Detection at the ingest, as a field error stored beside the field: it
  would make a conversion part of the response's decoding, which the
  oracle rule freezes, and store a Swift type's verdict in the image.
- Caching the converted value on the record: a second representation to
  keep in step with the text, for a read the bench has not yet shown to
  need it.
- A non-optional accessor that reads a zero on failure, the rule the
  built-in scalars follow: `URL` has no zero and a zero amount is data.

## Since

`reportUnexpected` is gone: the four hooks became one sink, and a failed
conversion is logged as the `unexpected` event, per
[The environment logs value-free events](the-environment-logs-value-free-events.md).
The rule above is unchanged.
