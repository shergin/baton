# The Kotlin host marks a document on the composable

Status: accepted, 2026-10-08. Serves
[Two runtimes, one compiler](../principles/two-runtimes-one-compiler.md)
and answers [#6](https://github.com/shergin/baton/issues/6). Built: the
`.kt` scanner in `compiler/src/kotlin.rs`. Reopen if Kotlin gains a string
form without templates, or if Compose gains a place beside a parameter
that is not a parameter list.

## Context

Relay colocates a fragment with the component that renders it, and the
Swift host keeps that: `@Fragment("…")` sits on the view's stored property
whose type is the fragment's lens. Compose has no view struct; a composable
is a function, and the data it renders is a parameter. Issue #6 asked what
the Kotlin marker is, and the before-Kotlin assessment left the answer to a
probe rather than an argument, since the candidates differed in how a file
reads, not in what they can do.

A second fact shaped the answer: `$` is a template in every Kotlin string,
plain or raw, and a variable in every GraphQL document.

## Decision

- A document is an annotation on the composable, or the class, that renders
  the fragment, holds the handle or holds the action: `@Fragment`, `@Query`,
  `@Mutation` and `@Subscription`, each taking the document's text, with
  source retention and the targets `FUNCTION` and `CLASS`. The parameter
  that carries the fragment's lens is typed by the fragment's name, and the
  text stands above the function as a doc comment would.
- The text is written in a multi-dollar raw string, `$$"""…"""`, where a
  single `$` is a character. The scanner reads every Kotlin string form,
  dedents a raw string as Swift's multi-line literal does, so the text is
  the one an author would write in a `.graphql` file, and refuses a
  template in a document at the marker, saying a document with a variable
  needs a `$$` string.
- A lens is named for its fragment, as Relay names them (`HeroCard_character`),
  so a composable and the lens it renders never share a name; a query's
  class stands beside the composable that holds it.
- The generated file takes the host's package and opts into
  `baton.Generated`, the runtime's contract with generated code.

## Evidence

- The probe of 2026-10-07 on Compose for Desktop (Kotlin 2.4.20, Compose
  Multiplatform 1.12.1, kept with the private notes): a plain raw string
  holding `$count` fails to compile, with "Annotation argument must be a
  compile-time constant" and an unresolved reference; a `$$` raw string
  compiles as an annotation argument and reads the two characters back.
  Both candidates, the annotation on the function and on the parameter,
  compiled and rendered; the function-level one reads as a header and holds
  a long fragment, where the parameter-level one puts the text inside a
  parameter list.
- Kotlin 2.2 made multi-dollar interpolation stable.
- The scanner as built: its tests carry a position through a dedented `$$`
  string back to the host (`Home.kt:4:21`), and its diagnostic for a
  template in a document.

## Not chosen

- The annotation on the parameter: the text sits in a parameter list, where
  a second parameter pushes it out of view, and it binds the fragment to a
  parameter whose type already names it.
- A `.graphql` file beside the source, as Apollo Kotlin reads: the
  colocation Relay and the Swift host have is lost, and the scanner has
  nothing to read in Kotlin.
- A plain string with `\$` before every variable and `\"` around every
  argument: no one would write it by hand.
- A comment carrying the text: invisible to the compiler's diagnostics and
  to the editor's GraphQL support.
