# The store owns roots and ages

Status: accepted, 2026-10-04. Serves
[The store is the UI's state](../principles/store-is-the-ui-state.md),
[Honest data](../principles/honest-data.md) and
[Relay's words](../principles/relays-words.md). Reopen the collector's
schedule, not its owner, if a pass misses a frame at a store size the
project supports. Reopen the rule for an unknown age if a product shows
screens that refetch on return, past the release buffer, more than it can
afford.

## Context

A root is what keeps records alive: an operation's selection and the record
it starts from. An age is when the store last received that operation's
response. As built, both live outside the store.

- Roots are the environment's: its handles, its release buffer and its
  completed mutations. Its `collect()` gathers four kinds of keeper, two of
  them by reaching into the store for the image's unwritten rows and the
  optimistic layers, and the store only sweeps. Three types mark from the
  same pair, a selection and a start record.
- A collection is scheduled when a handle is released or preloaded, when a
  subscription ends and when a completed mutation is pushed out. A release
  into the buffer removes no root, and the pass runs anyway. A commit that
  drops a link schedules nothing, so a screen that stays up and refetches
  keeps what its commits orphaned until some other view goes away.
- An age is the handle's, stamped by the handle after its own fetch, and
  apart from it the image's. A refetch, a page and a fetch made through the
  environment date nothing. A handle pushed out of the buffer forgets its
  age and the image remembers it: with an expiration set, the same return
  to data another root kept refetches with an image and reads as fresh
  without one.
- The store points back at its environment: for a lens that fetches, for a
  logged `@required` field, and to settle phases after a commit.

The terminology already gives the store its "retained roots and lifetime
state".

## Decision

Every fact has one home, chosen by what it is about. What is about data is
the store's: the records, what keeps them, and how old each operation's
data is. What is about the network is the environment's: fetches in flight,
their failures, streams, credentials. A handle holds its retention and
reads the rest. Built 2026-10-06: the roots, the release buffer and the
collector in the store, the retention token, and the collector's schedule
(a root left, or a commit dropped a link); the age stamped by the commit,
the unknown age read as stale wherever an expiration applies, and the end
of the store's pointer to its environment, whose lenses now fetch through
their owner.

- A record lives while a retention reaches it. A retention is a selection
  with the record it starts from, or a set of records. A view, a model, a
  fetch in flight, the release buffer, a completed mutation, an optimistic
  layer and the image's write queue each hold one, and the collector marks
  from nothing else.
- The store owns the root set, the release buffer and the collector. A root
  entry is a value: the selection, the start record, a count of holders,
  and the age.
- `retain()` returns a token whose end releases, and `release()` goes. The
  storage behind `@Query`, a view controller and a model hold the same
  token.
- The commit stamps the age, so every server write dates its operation,
  whoever asked for it. A query just written that nothing retains waits in
  the release buffer, which is what `preload` does by hand today. The
  image's fetch times are the root entries, persisted.
- Data with no known age is stale wherever an expiration applies: the rule
  hydration has, in memory too.
- The store collects when it may hold garbage: a root left, or a commit
  dropped a link. How eagerly is set by a bench at 50,000 records, inside
  the store, with no public setting.
- The store has no pointer to its environment. A lens that fetches reaches
  the environment through its owner. The two other uses, a logged
  `@required` field and the settling of phases, go with the report and the
  handle's phase, which are decided apart.

## Evidence

- The runtime as built, by reading: what Context says. `scheduleCollection`
  has three callers and none is a commit; the age is stamped in the
  handle's `didFetch` alone, and read back from the image only when the
  store has one. The screen that stays up and the age without an image are
  read, not run; tests prove them when the change is built.
- [`BENCHMARKS.md`](../../BENCHMARKS.md), 2026-10-04 at `2ba3d18`, an M1
  Pro: a collection pass over about 9,000 records takes 0.18 ms at best
  and 2.58 ms at the median. That is what a release pays today, whether or
  not a root left.
- Relay's `RelayModernStore`, read 2026-10-04: a root entry holds the
  operation, a count, an epoch and a fetch time; `retain` returns a
  disposable; the release buffer and the collector are the store's; a
  write for an operation stamps its entry, and an unretained query just
  written waits in the release buffer; the check reads the entry's epoch
  and fetch time against the store's expiration.
- [`BENCHMARKS.md`](../../BENCHMARKS.md), 2026-10-06, the lifetime entry:
  a pass over one root reaching 50,004 records takes 2.8 ms at the median,
  over 300 roots 34 µs, and a pass that keeps none of 50,000 records 26.7
  ms. The schedule's cost shows on the connection bench: from the eleventh
  page each page's root pushes an older page's out of the release buffer,
  and the pass that follows makes a page of 50 cost 1.12 ms at the median
  against 205 µs before, inside the next page's await. No frame is missed.

## Not chosen

- Roots in the environment, as built, which a review of the same code
  recommended keeping. Every input of the lifetime rule is the store's: two
  live there already, and the other two are held only as a selection and a
  start record. The environment adds a place to keep them, at the price of
  a pointer back and a collector in two halves.
- Collecting when the root set shrinks, and only then, which is Relay's
  schedule: a screen that stays up and refetches is never collected.
- Collecting on every release, as built: a pass with no root gone.
- Ages per record or per field. The operation is the unit a fetch
  refreshes, and finer ages invite a policy per type.
- An unknown age read as fresh, which is Relay's rule: an expiration that
  is not honoured, and nothing says so.
- Balanced `retain()` and `release()` calls kept beside the token: two ways
  to do one thing.
- A public way to retain a fragment. A retention allows it, and no screen
  asks for it yet.
- The root set and the collector inside `Store.swift`. The type owns them;
  the file, already the largest, does not grow.
