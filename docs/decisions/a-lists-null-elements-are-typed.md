# A list's null elements are typed as the schema says

Status: accepted, 2026-10-08. Serves
[Honest data](../principles/honest-data.md) and
[The compiler decides](../principles/compiler-decides.md). Reopen if an
adopter shows a schema whose nullable list elements are never null in
practice and whose accessors a `[T?]` makes unusable, which would argue for
a directive on the field rather than a change to the default.

## Context

The plan said of a field's type that it was a list or not, and whether the
field was non-null; the elements' nullability was lost between the schema
and the generated code. A list `[String]`, whose elements may be null,
read as `[String]?`, and a null element was dropped on the way, since
0.1.0, by no decision anyone had recorded. The plan's type is now one
recursive shape with nullability at every level, built once in the
lowering for the reader side and the normalization side alike, and the
question had to be answered: type the elements as the schema says, or
record the dropping with its reason.

## Decision

- A list of scalars whose elements the schema types nullable reads as an
  array of optionals, `[String?]`, as Relay types it, and a null element
  reads as nil. A list whose elements the schema types non-null reads as
  `[String]`; an element it cannot hold, a null or a value of another type,
  is reported once through `Store.reportUnexpected`, as a scalar reports a
  value it cannot hold, and left out.
- A list of records keeps dropping its null entries in `List`, and this
  is the reason recorded: a `List` is a collection keyed by its records'
  identities, for `ForEach` and for diffing, and a null entry has no
  identity to be keyed by. The store keeps the entry, so nothing is lost
  from the oracle; what the lens shows is the records.
- A variable typed as a list of nullable elements is a property of the same
  shape, `[String?]?`.
- Generated code of this shape is format 2. Code of format 1 fails to
  compile at its marker, with the message.

## Evidence

- The `tokenizer/response` case of `spec/manifest.json` has lists with
  null elements; its expected reads carry the nulls, and the lens reads
  them as nil where it dropped them before.
- The compiler's tests: `[String]` reads as `[String?]?` through
  `nullableStrings`, `[String!]` as `[String]?` through `strings`,
  `[String!]!` as `[String]`, `[String]!` as `[String?]`; the goldens
  changed in exactly those accessors and the format marker.

## Not chosen

- Dropping null elements silently, as built: data the server sent, read
  as if it were not there, against the principle.
- A nullable element read as a zero value: a false value in the list.
- `List<Lens?>` for lists of records with nullable elements: a collection
  whose entries cannot all be keyed, for a case the store already holds and
  the reads do not need.
