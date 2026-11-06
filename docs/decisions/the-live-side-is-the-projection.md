# An operation value is a value; its live side is the storage's projection

Status: accepted, 2026-11-05. Serves
[The store is the UI's state](../principles/store-is-the-ui-state.md),
[Two runtimes, one compiler](../principles/two-runtimes-one-compiler.md)
and [What earns a concept](../principles/what-earns-a-concept.md). Reopen
if Swift's macros lose the `$` prefix for the names they introduce.

## Context

A Swift query value carried its resolution: the `Query` protocol required
`var resolution: Resolution<OperationHandle<Self>> { get set }`, every
generated value declared it with a trapping default behind it for the
library-evolution build, and `@Query`'s storage wrote the handle into a
copy of the value before handing it to the body, so `issues.phase` read
through the copy. The value was a value and a mailbox: two equal values,
one resolved and one not, read different phases; a value kept in a
navigation path read `.loading` until a view resolved it, and the
`unresolved` case existed to name that. The Kotlin runtime found the same
defect in its own value and removed it on 2026-10-08: `rememberQuery`
returns a `QueryState`, and the value is immutable. The two runtimes were
one machine with one value pure and one not.

## Decision

The live side of a query or subscription value in a view is the macro's
projection, as SwiftUI spells a wrapper's: `@Query var issues: IssuesQuery`
keeps `issues` the value the parent passed, and `$issues` is the state the
storage resolved it to.

- `$issues` is a `QueryState<IssuesQuery>`, the twin of Kotlin's: the
  handle the storage made in the environment the view sees, or none outside
  every environment, and through it `phase`, `fetch`, `isRefreshing`,
  `isStale`, `fetchTime`, `refetch()` and `retry()`. Outside every
  environment the phase reads failed with the fetch's environment kind, not
  injected, and `refetch()` throws it.
- `$live` of a `@Subscription` is the `SubscriptionHandle?` the storage
  made, nil outside every environment, as Kotlin's `rememberSubscription`
  returns.
- `Resolution` leaves the runtime; `Query` and `Subscription` lose the
  requirement and its trapping default; generated values lose the line and
  the reserved name `resolution`; the value's `Equatable` by its variables
  says the whole truth.
- A model or a controller outside views holds the handle, as before;
  nothing changes there.

## Evidence

- SE-0389, attached macros: `prefixed($)` is the one prefix besides `_` a
  macro may introduce a name with, so a macro can project as a property
  wrapper does. The expansion was built and the samples compiled with it on
  2026-11-05.
- Apple's own precedent, 2026: SwiftUI's `@State` became a macro over a
  `DynamicProperty` storage in iOS 27, and SwiftData paired `@Query` in
  views with a token-held observer outside them.
- The October review's P2, built in `f0b8328`, for the Kotlin value, whose
  reasons apply here word for word.

## Not chosen

- The property's declared type as the state (`@Query var issues:
  QueryState<IssuesQuery>`): the init accessor takes a value of the
  property's type, so the parent would construct the state, not the value.
- A second stored property the view declares by hand beside the value: two
  declarations for one thing, and the parent's initializer would take both.
- Keeping the mailbox: the Kotlin review named its cost, and a value that
  reads differently from its equal is not a value.
