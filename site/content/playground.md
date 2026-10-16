# Playground

Write a fragment and a query against the Rick and Morty schema, and read what the compiler makes of them. The lens in Swift and in Kotlin. A lens is a typed window onto one record. The operation's text, as the server would receive it. The diagnostic that names the character that is wrong. The compiler on this page is `batonc`, built to WebAssembly. It is the same crate the build plugins run, so what it writes here is what it writes in a build.

{{playground}}

## What to try

- Add `gender` to the fragment. One accessor appears in both lenses, and one field appears in the operation's text. Nothing else moves.
- Misspell a field. The diagnostic points at the line and the column inside the document, with the schema's suggestion.
- Declare a fragment no query spreads, and read the warning. A fragment nobody spreads is one nothing can read.
- Mark the fragment `@inline` and see a value in place of a lens: a struct in Swift, a data class in Kotlin.
- Put `@required(action: THROW)` on `name`. The accessor stops being optional and starts throwing.
- Give the query `@cacheExpiration(seconds: 60)`. The text the server receives does not change, because the directive is the client's business.

## What this is not

A playground over a schema with no server behind it shows the compile-time half, what the build settles before the app runs. The run-time half is a response becoming records, and a field change becoming one re-render. That half is on [One screen, end to end](../walkthrough/), drawn from the specification's fixtures.
