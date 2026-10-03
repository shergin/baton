# A fragment is a lens

A fragment compiles to a typed, read-only view over one record: a reference
and one accessor per declared field. Nothing is decoded to hand it to a view.
The value a parent passes to a child is the fragment itself: a record
reference and a context.

## Why

Every native GraphQL client before this one decoded responses into models.
Apollo's generated structs wrap a dictionary and cast on every access; its
Kotlin sibling parses into models, re-serializes them into records, and
rebuilds the model tree on every read. Meta measured the consequence in 2015:
tokenizing a response was cheap, building objects from it was the frame
budget. The models also leak. A parent that holds a child's fragment as a
struct can read its fields, so components grow implicit dependencies, and the
generated code grows with every field merged into every type that mentions
it: twenty megabytes of app size from one codegen option, in one reported
case.

The opposite failure is a client that hands views the raw records. Then
masking is a convention, types are strings, and the first refactor of a
fragment breaks a view nobody knew depended on it.

## The idea

The compiler knows every fragment and every field it selects. For each
fragment it emits a struct holding a record reference (and a context when the
fragment uses variables) and a one-line accessor per field. Reading
`character.name` loads a slot. A linked field returns another lens; a plural
field returns a lazy collection of lenses, identifiable by record. A spread
into another fragment becomes a named accessor returning that fragment's
lens, optional exactly when the spread is conditional or deferred.

Masking falls out of the shape: the lens has no accessor for a field the
fragment did not declare, and the compiler is the only thing that can add one.
Observation falls out of the shape too: the accessor is where a read is
registered, so a view body depends on the fields it read and nothing else.

## Consequences

- There is no model to copy, mutate, persist or keep in sync. The store is the
  only data.
- Generated code is one line per field plus a few data tables. No `Codable`,
  no `Hashable` beyond identity, no initializers except opt-in test builders.
- A lens is valid only on the main actor, where the store lives. Code that
  needs a value elsewhere hops there or takes an explicit snapshot.
- Equality of lenses is identity: same record, same context. SwiftUI's
  diffing of a view holding a lens compares references.
- A fragment's name appears once in Swift, as the type of the property that
  holds it.

## Not this

- Decoding responses into `Codable` models and normalizing from the models.
- A parent reading a child's fields through a shared struct.
- Fragment references as protocols a generic view is constrained by.
- Materializing a snapshot of a fragment to compare it against the previous
  one.

See [The store is the UI's state](store-is-the-ui-state.md) for what a read
registers, and [The compiler decides](compiler-decides.md) for who emits the
lens.

## Spelled today

Nothing is spelled yet. Planned: a fragment `CharacterRow_character` compiles
to `struct CharacterRow_character`; an operation root to
`CharactersScreenQuery.Data`; a spread to an accessor such as
`characterRow`; a plural field to a `RandomAccessCollection` of lenses.
This section may rot; the rest must not.
