# An operation states its expiration in its document

Status: accepted, 2026-10-04. Serves
[The compiler decides](../principles/compiler-decides.md),
[Honest data](../principles/honest-data.md) and
[Relay's words](../principles/relays-words.md). Reopen if Relay or the
GraphQL specification gains a word for it, which then replaces ours; or if
a real screen has to tolerate older data than another reader of the same
operation.

## Context

One expiration covers a whole environment: `queryCacheExpiration`, which
can be set at any time. The first adopter's data does not fit one number
([#5](https://github.com/shergin/baton/issues/5)): a quote is old in
seconds and a profile is good for hours. The issue asks for an expiration
on each handle, settable by its owner.

A handle has no one owner. Equal operation values share it, so a number
set by an owner is whichever owner set it last. The fetch policy shows the
defect already: it is applied at an attach and then forgotten. And
[the store now owns ages](the-store-owns-roots-and-ages.md), so it should
say what is stale without asking who is looking.

Relay has no word for this: its expiration is one option of the store, and
the rest of its staleness is explicit invalidation. The GraphQL
specification has none. In React Native the common spelling is TanStack
Query's `staleTime`, an option beside each query that teams write once per
query by convention; Apollo Client's cache has no expiration at all.

## Decision

How old an operation's data may be is part of what the operation says. All
of this is *(planned)*.

- A query states its expiration once, in its document, with a directive:
  `@cacheExpiration(seconds:)`. The compiler emits it as a constant of the
  operation.
- The store answers whether an operation is stale from the age of its root
  and that constant. An operation that states none takes the default, which
  is given when the store is made, where Relay gives it. The settable
  `Environment.queryCacheExpiration` goes.
- Nothing is passed at an attach. The fetch policy stays there, as in
  Relay: it says what to do with the store's answer, not what the answer
  is.
- Crossing the window fetches nothing by itself. No timer is armed.
  Staleness is read at an attach, and by a revalidation the app calls,
  which is proposed apart.
- This is the first directive that is not Relay's. Neither Relay nor the
  specification has a word, a real screen asks, and the fetch policy cannot
  say it: a screen that stays retained while the app is away has no new
  attach, so only the operation's own number lets a revalidation see it as
  stale. When it is built, the principle's sentence that the directive set
  is Relay's names the exception.

## Evidence

- As built, by reading: `isStale` on a handle reads the environment's one
  expiration; `handle(for:fetchPolicy:)` applies its policy at each attach
  to a handle that equal values share; `invalidate()` refetches every stale
  retained handle whatever policy it was attached with.
- Relay's guide to staleness, read 2026-10-04
  ([guide](https://relay.dev/docs/guided-tour/reusing-cached-data/staleness-of-data/)):
  `queryCacheExpirationTime` is an option of the store and applies to every
  query; the other means are invalidation of the store or of a record.
- React Native practice, read 2026-10-04: TanStack Query's `staleTime` is
  an option of a query, zero by default, and its guide refetches stale
  queries when the app returns, through `AppState`; Apollo Client's guide
  to queries lists fetch policies and polling, and no expiration.
- Nothing is measured, and nothing needs to be: the store reads a
  constant.

## Not chosen

- An argument at the attach, beside the fetch policy. On a shared handle
  the last attach wins; one root would be stale for one holder and fresh
  for another; and a Swift argument reaches neither a `.graphql` file nor
  the Kotlin runtime.
- A settable property on the handle, as the issue asks: the same defect,
  with no owner at all.
- One expiration for the environment and no other, as built and as in
  Relay: it cannot say seconds for one screen and hours for another.
- Freshness stated per type, in the schema's language. It is closer to the
  data, but one screen cannot tolerate older data than another, and it
  reads like type policies. It could feed the same constant later.
- Freshness read from a response's `Cache-Control`: few GraphQL servers
  state it, and a transport returns bytes. It could feed the same constant
  later.
- A map from operation names to seconds in `baton.json`: the statement
  apart from its document, keyed by a string.
- A timer that refetches when the window closes: work the view did not ask
  for.
- A new stem such as `@expires`: `cacheExpiration` is the word the option
  already has, after Relay's.
