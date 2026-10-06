# An enum reads as a generated enum with an unknown case

Status: accepted, 2026-10-11. Completes the proposal recorded with
[A mapped scalar is a fallible read](a-mapped-scalar-is-a-fallible-read.md),
which placed enums at the same boundary as custom scalars. Serves
[Honest data](../principles/honest-data.md) and
[Relay's words](../principles/relays-words.md). Reopen if an adopter needs
the enum's cases spelled otherwise than the schema spells its values, or a
schema's enums outnumber what one shared file should declare.

## Context

Every scalar that is not `Int`, `Float` or `Boolean` read as a `String`,
enums included, and the GitHub sample lowercased an `IssueState` by hand.
The owner's review of #11 named enums as the same boundary as custom
scalars and asked for a generated enum with a case for a value this build
does not know; the decision on mapped scalars noted that such a conversion
cannot fail and so keeps the schema's nullability.

## Decision

- Each enum the documents read or pass is generated once per module, in the
  shared file: `nonisolated public enum Status: Baton.GeneratedEnum` with a
  case per value, spelled as the schema spells it, and `unknown(String)`
  for a value the build does not know. A value named `unknown` takes an
  underscore; a value Swift reads as a keyword is escaped.
- `GeneratedEnum` refines `MappedScalar` with a non-failable initializer
  from the text, so an enum is a mapped scalar whose conversion cannot
  fail: it reads through its own readers, keeps the schema's nullability,
  and a null on a non-null field reads as `unknown("")` and is reported, the
  rule every scalar follows for a value its type cannot hold. A variable of
  the type is sent as its text.
- The store keeps the text, as for every scalar; the plan is unchanged.
- The enum's Swift name is the schema's. A fragment or an operation of that
  name is a clash the document resolves by renaming; a schema enum named
  like a shared enum, a module or a standard library type the generated
  code spells takes `Enum` after its name, as a nested lens of such a name
  takes `Lens`.

## Evidence

- The test schema's `Status`, read through `ListsPayload.statuses`: a list
  of the enum, with a response that carries a value the schema does not
  declare, reads it as `unknown` with its text.
- Relay's generated TypeScript, which types every enum with
  `"%future added value"`, and the issue's own report of the sample
  lowercasing a state string.

## Not chosen

- Lower-camel-cased cases: two values that differ in case alone would
  collide, and the schema's spelling is what the server sends and the
  documents write.
- A failable enum, nil for an unknown value: it would make a schema's
  growth a client failure, which the unknown case exists to prevent.
- Reading enums as `String` with a separate typed accessor beside it: one
  field, one type, as for mapped scalars.
