# Revalidation is one call the app makes, and the policy stays with its holder

Status: accepted, 2026-10-05. Answers
[#18](https://github.com/shergin/baton/issues/18), and two points
[A handle keeps its fetch and derives its phase](a-handle-derives-its-phase.md)
left open: whether a handle keeps the policy it was attached with, and the
revalidation method. Serves
[The store is the UI's state](../principles/store-is-the-ui-state.md) and
[What earns a concept](../principles/what-earns-a-concept.md). Reopen a
reachability input or a pacing setting when a stampede is measured that
`revalidate()` and the sharing of a fetch in flight do not prevent.

## Context

Nothing refetched when an app returned to the foreground or regained its
connection. #18 asked for a sweep of the stale and failed handles on an
active scene, a retry of failed fetches when the network returns, an
`isReachable` input, a `revalidationSpread` to pace the requests, and a
platform observer by default.

`invalidate()` did two things: it marked everything stale and refetched the
retained handles that were stale. The fetch policy was applied at an attach
and then forgotten, so `invalidate()` refetched a handle attached
`storeOnly`: one request before it, two after. A sweep that skips
`storeOnly` handles could not be written while no handle remembered its
policy.

## Decision

- **One method.** `Environment.revalidate()` refetches each retained
  operation whose data is stale or whose last fetch failed, where a holder
  allows the network, and marks nothing. A fetch in flight is not
  duplicated, and a handle with data does not pass through loading.
  "Whose last fetch failed" reads the handle's `fetch` value. The app calls
  it on its return to the foreground, and from its own path monitor if it
  has one.
- **The policy is the holder's.** An attach's policy stays with the
  retention it makes. A fetch the runtime starts later, for an
  invalidation, a revalidation or a heal, asks whether any holder of the
  root allows the network, so a `storeOnly` holder is fetched for by none
  of them. A `storeOnly` attach without data fails with
  `MissingDataError`, as it did.
- **No timer.** Staleness is the operation's `@cacheExpiration(seconds:)`
  or the store's default, read at an attach and by this call.

## Evidence

- `e93ea3d` built both. The tests in `LifetimeTests.swift`: "a storeOnly
  holder is fetched for by neither an invalidation nor a revalidation; a
  holder that allows the network is, while it holds", and "revalidate
  refetches a retained handle that is stale and one whose last fetch
  failed, leaves a fresh one alone, and marks nothing".
- The request count above, run against `97ddaa5` and reported on #18.

## Not chosen

- `isReachable`: a second input for a narrower predicate; a path that flaps
  wakes every screen. The app calls `revalidate()` from its path monitor.
- `revalidationSpread`: pacing belongs behind the transport, where an app
  can put a limit it shares with the rest of its networking.
- A platform observer by default: UIKit and AppKit lifecycle code inside
  the data layer. `Environment.isActive` parks subscriptions and is set by
  the app; queries read nothing of it.
- A trigger on the log's `fetchStarted`: a case or a field joins the log
  when an adopter shows a number it cannot derive, per
  [The environment logs value-free events](the-environment-logs-value-free-events.md).
