# What Meta built, and what you can download

The most experienced native GraphQL client in the world is one you cannot
download. GraphQL was created in 2012 for the native rebuild of the Facebook
apps ([GraphQL: A data query
language](https://engineering.fb.com/2015/09/14/core-infra/graphql-a-data-query-language/)).
Meta's native apps, Facebook and Instagram among them, have run an in-house
client ever since.

Its current incarnation is called Pando. It is not open source. Meta has not
published its storage layout, or a single performance number for it. What is
public is a trail of engineering posts from 2012 to 2015, a 2017 post on
where Relay Modern's ideas came from, a 2025 podcast with an engineer on the
Mobile GraphQL Platform team, and a handful of conference abstracts.

That trail is the best available evidence on what a native GraphQL client
needs at the extreme. It is worth reading beside Baton. Baton makes most of
the same choices, and goes further on the one Meta calls a goal.

## The public record

The 2012 iOS rebuild showed previously cached content at launch, instead of
a spinner. It kept the network, the JSON parsing, and the disk off the main
thread. It stored story heights, so that launch read only what the first
layout needed ([Under the hood: Rebuilding Facebook for
iOS](https://engineering.fb.com/2012/08/23/ios/under-the-hood-rebuilding-facebook-for-ios/)).

By 2014 the iOS app's data layer was Core Data, a fully normalized SQLite
store, and it had become the bottleneck. Entities had gone from dozens to
hundreds. Every parse ran a fetch-or-create. Creating and querying model
objects took longer with every entity added.

The replacement had three principles. Models are immutable. Storage is
denormalized, with a cache per part of the app. Consistency is asynchronous
and opt-in: a controller on background queues that notices a field change
and issues updated models. News Feed came out nearly 50% faster ([Making
News Feed nearly 50% faster on
iOS](https://engineering.fb.com/2014/10/31/ios/making-news-feed-nearly-50-faster-on-ios/)).

In 2015 the Android app measured its JSON cost. 35 ms to parse a 20 KB
response, more than a 16.6 ms frame, with about 100 KB of transient memory
allocated per parse. The fix was FlatBuffers, a format read in place with no
objects built, and the UI reading storage directly through cursors. Story
load time from the disk cache went from 35 ms to 4 ms. Transient allocations
fell by 75%. Cold start improved by 10 to 15% ([Improving Facebook's
performance on Android with
FlatBuffers](https://engineering.fb.com/2015/07/31/android/improving-facebook-s-performance-on-android-with-flatbuffers/)).

In 2016 Facebook's native code generation moved from type-based models, with
a getter for every server field, to fragment-based models. Those carry only
the fields a fragment fetches, so an unfetched field is a compile error
rather than a runtime one ([Native code generation at
Facebook](https://www.apollographql.com/blog/community/native-code-generation-at-facebook-7d6d0db4f3ee/),
a 2016 talk summary).

The 2017 Relay Modern announcement says where ahead-of-time compilation came
from. The native apps had found that building queries by concatenating
strings, and uploading them over slow connections, was costly. Queries
sometimes grew into the tens of thousands of lines. So static queries were
constructed once at build time, saved on the server, and replaced in the app
with a tiny identifier. Relay Modern adopted the same model for the web
([Relay Modern: Simpler, faster, more
extensible](https://engineering.fb.com/2017/04/18/web/relay-modern-simpler-faster-more-extensible/)).

The 2025 podcast is the only public description of the client as it is now.
The engineer calls it a framework "very similar to Relay", named Pando,
implemented in C++ in a shared layer, with native wrappers around it.

It has two parts for a product developer. A build-time component that
generates type-safe accessors, in Kotlin or Java and in Objective-C or
Swift, for exactly the fields a query selected. A runtime that executes
queries and integrates the network, the cache, and the consistency engine.

The models are immutable. Consistency is a publish-subscribe engine that
tells everywhere else that a value changed, without refetching. Generated
builders let product code make a local change, a hidden post or a pending
like, that flows through the same engine. An optimistic mutation publishes
the expected state and rolls back on failure. Pagination follows the Relay
connection specification, from one annotated field.

The team tries not to make its APIs too automatic. Colocating a view's data
with the view, Relay's shape, is a longer-term goal on mobile, not the
current state ([Mobile GraphQL at Meta in
2025](https://www.metacareers.com/podcast/mobile-graphql-at-meta-in-2025/)).

Two more pieces of the record bear on the shape. A 2023 retrospective on the
iOS app's architecture says C++ was the lever that built Meta's abstractions,
and that product-facing code should no longer contain it, so that Swift can
be adopted ([The evolution of Facebook's iOS app
architecture](https://engineering.fb.com/2023/02/06/ios/facebook-ios-app-architecture/)).
The 2024 post on Threads' performance quantifies why any of this matters.
Injecting 0.29 to 0.36 seconds of navigation latency cost 0.54 to 0.81% of
daily active users ([How we think about Threads' iOS
performance](https://engineering.fb.com/2024/12/18/ios/how-we-think-about-threads-ios-performance/)).

## Where Baton makes the same choices

Agreement with a client that has run on billions of phones is evidence. The
list is long.

- **The operation is compiled ahead of time.** Every Baton operation is
  static. The compiler validates it against the schema, assembles it from
  the fragments it spreads, and hashes it to an id. Under Relay's
  `persistConfig`, the app sends the id alone, as Meta's apps sent a tiny
  identifier in 2017 ([the
  decision](../decisions/an-operation-is-sent-as-text-or-id.md)).
- **Product code gets typed accessors for exactly the fields it selected.**
  A Baton fragment compiles to a lens, with one accessor per declared field
  and nothing else. That is the 2016 move from type-based models to
  fragment-based models, with masking as the shape of the type.
- **Never build objects a view did not ask for.** The FlatBuffers lesson is
  that the cost is in the objects, not the bytes. Baton's ingest decodes a
  response's bytes straight into record slots, by the plan the compiler
  emitted, with no model tree in between. A lens reads a slot. On an Apple
  M1 Pro, on 2 October 2026, a 686 KB response is in the store 3.4 ms after
  the bytes arrive. `JSONSerialization` alone takes 4.47 ms on the same
  bytes ([BENCHMARKS.md](../../BENCHMARKS.md), the 0.1.0 entry).
- **Cached content in the first frame.** Reads are synchronous on the main
  actor. The handle resolves against the store before the first body. An
  image on disk is read before the first body on the next launch ([The first
  frame has the data](the-first-frame.md)).
- **Consistency without refetching, and optimistic writes that roll back.**
  A mutation's payload lands in the one record a character is. Every view
  reading it sees the change. An optimistic response goes through the same
  ingest as a server's answer, and is reverted if the server refuses.
- **Pagination from one annotated field.** `@connection` on a refetchable
  fragment. The store merges the pages. The lens pages with `loadNext`.
- **Incremental delivery.** `@defer` and `@stream`, which grew partly out of
  Meta's needs, are compiled and merged into the store in both runtimes.

## Where Baton goes further

**Colocation is the current state, not a goal.** The fragment sits on the
view that renders it, in the Swift or Kotlin file, as a real GraphQL
document. The compiler assembles the screen's operation from the fragments
spread into it. Nobody writes the screen's query. The 2025 podcast names
this as where Meta's mobile stack is trying to get. It is where Baton
starts.

**The typed view points at a live record, not at a copy.** Meta's family of
designs, from the 2014 iOS layer to Pando, hands product code an immutable
model tree. A consistency engine republishes new trees when an entity
changes. Reads of a tree are free. Updates cost work proportional to the
trees that mention the id. The app holds two copies of every fact, one in
the cache and one in the model.

Baton collapses the two. The normalized record is the only copy. The lens is
the immutable typed view Meta generates, pointed at a live slot. The
consistency engine is the UI framework's own observation. A commit notifies
the slots that changed, and the bodies that read them run ([Relay without
the read side](relay-without-the-read-side.md)). There is no second tree to
rebuild, and no engine to keep it consistent.

**No shared C++ core.** Pando is C++ with wrappers. That is one
implementation of the hard parts, for two platforms. Baton's compiler is
Rust, and it runs on the build machine. The runtimes are Swift and Kotlin,
written twice on purpose, held to one behaviour by one compiler's plans and
one set of fixtures ([Two runtimes, no
bridge](two-runtimes-no-bridge.md)).

Meta's own 2023 guidance, that product-facing code should not contain C++,
points the same way. A lens read that costs 26 ns as a native slot load
would cost a string copy across a foreign-function boundary on every render,
or a native shadow cache, which is a second store.

**Any server that follows the specification.** Pando is built for Meta's
schema, Meta's servers, and Meta's transport. Baton asks nothing of a server
beyond GraphQL over HTTP, with `graphql-transport-ws` and `graphql-sse` for
subscriptions. It has been run against fate's GraphQL template server on
Yoga, GitHub's API, and the public Rick and Morty API. The wire is JSON.

A binary response format is on a watch list in the planning notes, with a
trigger, not in the plan. A GraphQLConf 2026 session abstract from WhatsApp
reports that its Argo encoding makes responses 27 to 50% smaller than JSON.
That is the kind of evidence that would move it.

**Relay's words, Relay's compiler.** Because the front end is Relay's own,
pinned behind Baton's driver, a team that runs Relay on the web and Baton on
native speaks one language. The same directives. The same connection
specification. The same error directives. Meta's web and native stacks share
a north star. Baton's share a parser.

**Every number is public.** Meta has not published Pando's numbers. Baton's
are in [BENCHMARKS.md](../../BENCHMARKS.md), with the revision, the machine,
the OS, and the date. The comparison harnesses are in the repository. Anyone
can rerun them, or correct them.

## What Meta has that Baton does not

Honesty is part of the argument. Pando runs at a scale no open-source client
has been tested at, has for years, and has a team around it.

Meta has pushed the specification from the client side. `@defer` and
`@stream`, then `@async`, presented at GraphQLConf 2025 so that products ask
for data only when it is needed ([What launched at GraphQLConf
2025](https://graphql.org/blog/2025-10-20-graphql-conf-2025-article-1/)).
Batching with dependencies between queries, in use internally by 2016 ([New
features in
GraphQL](https://www.apollographql.com/blog/community/backend/new-features-in-graphql-batch-defer-stream-live-and-subscribe/)).
QUIC for GraphQL requests in the Facebook app, with a 20% cut in tail
latency ([How Facebook is bringing QUIC to
billions](https://engineering.fb.com/2020/10/21/networking-traffic/how-facebook-is-bringing-quic-to-billions/)).

Baton's transport is the platform's own stack. That gives it HTTP/3 where
the server supports it, and nothing the specification does not have. Baton
is at 0.16, with an API that will break before 1.0, and no install base to
speak of.

## The lesson

Every public description of Meta's native stack, from 2014 to 2025, has the
same shape. Compile the operation ahead of time. Hand product code immutable
typed accessors for exactly the fields it asked for. Never materialize what
a view does not read. Keep the synchronous read path cheaper than a frame.
Show cached content first.

That is the shape Baton ships, for SwiftUI and Compose, with the platform's
own observation in place of the consistency engine, and the fragment on the
view today. It is the design the people with the hardest version of the
problem converged on. It is the one you can add to a package manifest this
afternoon.

## Sources

The engineering posts linked above. The podcast transcript, which was read
through an automated extraction, so its wording is paraphrased except for
the three words quoted. The GraphQLConf 2025 and 2026 session abstracts on
`graphql.org`, and the conferences' schedule pages. None of them describes
Pando's storage layout, wire format, or performance, and none announces its
release. Baton's numbers are from [BENCHMARKS.md](../../BENCHMARKS.md).
