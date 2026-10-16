# A fragment is a lens

A fragment compiles to a lens. A lens is a typed window onto one record.

You get a reference, and one accessor per field you declared. Nothing is
decoded to hand it to a view. The value a parent passes to a child is the
fragment itself: a record reference and a context.

## Why

Every native GraphQL client before this one decoded responses into models.
Apollo's generated structs wrap a dictionary and cast on every access. Its
Kotlin sibling parses into models, re-serializes them into records, and
rebuilds the model tree on every read. Meta measured the cost in 2015.
Parsing a 20 KB response on Android took 35 ms, more than a frame. The fix
that removed it was a format read in place, with no objects built. Baton's
own bench shows where the time goes. Foundation tokenizes a 686 KB response
in 4.47 ms. Apollo iOS builds its models from the same bytes in 317 ms. The
models also leak. A parent that holds a child's fragment as a struct can
read its fields, so components grow implicit dependencies. The generated
code grows with every field merged into every type that mentions it. Twenty
megabytes of app size, from one codegen option, in one reported case.

The opposite failure is a client that hands views the raw records. Then
masking is a convention, types are strings, and the first refactor of a
fragment breaks a view nobody knew depended on it.

## The idea

The compiler knows every fragment, and every field it selects. For each
fragment it emits a struct. The struct holds a record reference, and a
context when the fragment uses variables. It has a one-line accessor per
field. Reading `character.name` loads a slot. A linked field returns
another lens. A plural field returns a lazy collection of lenses,
identifiable by record. A spread into another fragment becomes a named
accessor returning that fragment's lens, optional exactly when the spread
is conditional or deferred.

Masking falls out of the shape. The lens has no accessor for a field the
fragment did not declare, and the compiler is the only thing that can add
one. Observation falls out of the shape too. The accessor is where a read
is registered, so a view body depends on the fields it read and nothing
else.

## Consequences

- There is no model to copy, mutate, persist or keep in sync. The store is
  the only data.
- Generated code for a lens is one line per field plus a few data tables.
  No `Codable`. No `Hashable` beyond identity. No initializers except
  opt-in test builders. The explicit snapshot is generated too, as a
  fragment's other reading. An `@inline` fragment compiles to a value, not
  a lens ([the decision](../decisions/a-fragment-has-one-reading.md)).
- A lens is valid only on the main actor, where the store lives. Code that
  needs a value elsewhere hops there, or takes an explicit snapshot.
- Equality of lenses is identity: same record, same context. SwiftUI's
  diffing of a view holding a lens compares references.
- A fragment's name appears once in Swift, as the type of the property that
  holds it.

## Not this

- Decoding responses into `Codable` models and normalizing from the models.
- A parent reading a child's fields through a shared struct.
- Fragment references as protocols a generic view is constrained by.
- Materializing a snapshot of a fragment to decide what re-renders.
  Observation decides that.

See [The store is the UI's state](store-is-the-ui-state.md) for what a read
registers, and [The compiler decides](compiler-decides.md) for who emits the
lens.

## Spelled today

A fragment `CharacterRow_character` compiles to
`struct CharacterRow_character: Baton.Lens`. It holds its anchor, and it has
one accessor per field it declares. An operation root compiles to
`CharactersScreenQuery.Data`. A linked field compiles to a nested struct
such as `Data.Characters`. A spread is an accessor such as `characterRow`
that returns the child's lens. A plural link is a `Baton.List`, a
`RandomAccessCollection` of lenses. A lens is `Equatable` by its anchor, so
a row view may be too. A view declares
`@Fragment("…") var character: CharacterRow_character`. The anchor a lens
holds, the initializer that takes one, and every reader behind the accessors
are `@_spi(Generated)`. The generated files import that SPI. An app's files
do not, so another module cannot make one fragment's lens from another's.
Swift does not check SPI inside the module that declares it. In the module
the lenses were generated in, `Other(anchor: lens.anchor)` still compiles,
while the anchor's readers stay out of reach. This section may rot. The rest
must not.
