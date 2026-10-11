# Playground

Write a fragment and a query against the Rick and Morty schema, and read what the compiler makes of them: the lens in Swift and in Kotlin, the operation's text as the server would receive it, and the diagnostic that names the character that is wrong. The compiler on this page is `batonc` built to WebAssembly, the same crate the build plugins run, so what it writes here is what it writes in a build.

{{playground}}

## What to try

- Add `gender` to the fragment and watch one accessor appear in both lenses and one field in the operation's text. Nothing else moves.
- Misspell a field. The diagnostic points at the line and the column inside the document, with the schema's suggestion.
- Declare a fragment no query spreads, and read the warning: a fragment nobody spreads is one nothing can read.
- Mark the fragment `@inline` and see a value in place of a lens: a struct in Swift, a data class in Kotlin.
- Put `@required(action: THROW)` on `name` and see the accessor stop being optional and start throwing.
- Give the query `@cacheExpiration(seconds: 60)`. The text the server receives does not change, because the directive is the client's business.

## What this is not

A playground over a schema with no server behind it shows the compile-time half: what the build settles before the app runs. The run-time half, a response becoming records and a field change becoming one re-render, is on [One screen, end to end](../walkthrough/), drawn from the specification's fixtures.
