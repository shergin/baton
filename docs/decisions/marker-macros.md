# Marker macros carry the GraphQL

Status: accepted, 2026-10-02. Serves
[A fragment is a lens](../principles/fragment-is-a-lens.md). Reopen when
Swift offers a way to attach a literal to a property without a macro, or when
the macro trust prompt proves prohibitive for adopters; `.graphql` files
remain the macro-free path either way.

## Context

GraphQL belongs beside the view that reads it, as a full, valid document in
the Swift file, found by the compiler. Something has to attach the text to
the property that holds the lens. Candidates: a property wrapper with a
string argument, an attached macro, a separate `graphql("…")` declaration, a
doc comment, or `.graphql` files only.

## Decision

Attached macros: `@Fragment("…")`, `@Query("…")`, `@Mutation("…")`,
`@Subscription("…")`. `@Fragment` is a peer macro that expands to nothing,
so the property stays stored and the memberwise initializer takes the lens.
`@Query` is an accessor-plus-peer macro: the peer is the operation storage,
the accessors are an init accessor and a getter, so a parent passes the
variables and the body reads the resolved handle. The compiler finds the
text by the attribute, never by expanding the macro. `.graphql` files are
accepted alongside.

## Evidence

- A property wrapper cannot do it: `@Fragment("…") var user: T` with
  `init(wrappedValue:_:)` fails with "missing argument for parameter
  'wrappedValue'", because attribute arguments initialize the wrapper
  directly (spike, 2026-10-02).
- The macro form builds and runs: `CharacterRow(character:)` takes the lens;
  `CharactersScreen(characters: CharactersScreenQuery(page: 1))` takes the
  variables and `characters.phase` reads the handle. The declaration must
  list `names: named(init), named(get)` or the compiler rejects the init
  accessor.
- Prebuilt swift-syntax applies in SwiftPM and Xcode 26, so the macro package
  costs seconds, not minutes.
- Apple's own `@State` became an accessor-plus-peer macro in Xcode 27; the
  shape is the platform's.

## Not chosen

- A property wrapper: the compile error above.
- A separate `graphql("…")` declaration: two constructs for one thing, and
  the property's type and its document drift apart.
- GraphQL in doc comments: invisible to tooling and formatters.
- `.graphql` files only: no colocation.
