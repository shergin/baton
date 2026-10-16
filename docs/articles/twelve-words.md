# Twelve words, and why the list is closed

GraphQL clients die of configuration. Each real complaint becomes an option:
a cache policy here, a type policy there, a merge function, a link in a
chain, a flag on codegen.

Ten years later the client has four codegen modes, a dozen cache policies,
and a documentation site explaining which combinations work. The complaints
were real. The answers multiplied the surface, instead of fixing the
mechanism.

Baton's vocabulary is twelve concepts, and Relay's directives. A feature
that is not a composition of them does not ship. This page is what that rule
refuses, what it buys, and how it looks beside a client that went the other
way.

## The twelve

The twelve are schema, document, directive, lens, record, store, plan,
operation value, connection, environment, transport, and phase, in that
order.

A schema is the server's menu. A document is a query, a mutation, a
subscription, or a fragment beside a view. A directive is the only way
behaviour attaches to data. A lens is a typed, read-only view over one
record. A record is an observable object, keyed by type and id. A store is
all records, owned by the main thread. A plan is how a response becomes
records, decided by the compiler. An operation value is an operation's
variables, the thing a parent constructs. A connection is a list that pages,
merged in the store. An environment is the session: one store and one
transport. A transport is one verb, `send`, yielding payloads. A phase is
loading, ready, or failed, always readable.

[The terminology](../terminology.md) marks each of its entries with its place
in that inventory: the concept it is, or is a form of, or the concepts it is
a composition of. An owner is a lens and an operation value. A mutation's
action is an operation value and a payload. A heal is a phase, a store
event, and a fetch. Nothing ships that is not named there. A name comes
before a type in code.

A concept enters through one test, with two clauses, both required. Real
screens demand it, and those are screens people build rather than screens a
completeness argument names. No composition of the existing concepts
expresses it ([the principle](../principles/what-earns-a-concept.md)).

Two words are Baton's own, because the things they name are new. A lens is
Relay's fragment reference and fragment data as one value. A plan is the
normalization artifact as data. Everything else is Relay's, or the
specification's.

## What the rule refused

The first adopter filed twenty-one issues in the project's first week.
Answering them is the best record of the rule at work. Each refusal carries
the reason, and the condition that would reopen it. The decisions directory
has the long form.

- **A retention policy per type.** The request was a budget: keep so many of
  these, and evict those first. The answer is the mechanism that already
  exists: a release buffer of ten roots, collection from the roots, and
  eviction from the image by launch and a size limit. A budget per type was
  refused, with no
  reopening condition, as a policy object at run time for what recency
  decides ([the decision](../decisions/the-image-evicts-by-launch.md)).
- **Shipped transport wrappers.** Retries, a deadline, and a token refresh
  were refused. The transport has one verb, and credentials are read per
  attempt. The wrapper is
  [a recipe](../recipes/exchange.md) of a few dozen lines the app owns,
  compiled in both languages and tested over a loopback server. A library
  wrapper would be a policy object with options.
- **A `@snapshot` directive.** Relay already has the word: `@inline`, a
  fragment that compiles to a value instead of a lens, built when the
  spread's accessor is called ([the
  decision](../decisions/a-fragment-has-one-reading.md)).
- **A store swapped under live handles at sign-out.**
  `Environment.replaceStore` would have needed a generation checked on every
  write path. Instead the environment is the session: a sign-in makes one,
  and a sign-out ends it. A handle still held reads `gone` ([the
  decision](../decisions/the-environment-is-the-session.md)).
- **Imperative store updaters.** Every write so far has been a directive on
  a fragment, or a payload for an operation. `commitPayload` is the one door
  a payload takes. A write neither can express reopens it.
- **A session type, a transport mode, a cache-update function, an age per
  record, automatic persisted queries.** Each is in the records, with its
  reason.

Page-based pagination, a binary wire format, and offline sync are on a watch
list in the planning notes, each with a trigger, not in the plan. Leaving a
problem unsolved is a fair answer. A half-built feature in the library is
not.

## Subtraction is a contribution

The rule cuts both ways. The changelog records removals as plainly as
additions. Four reporting hooks became one log of value-free events. A
generated line per lens, `typeName`, went when nothing needed it. Two
spellings of `fetch` became one. The placeholder environment went when the
handle learned to say it was not injected. A concept that stops paying for
itself is removed before 1.0.

## Beside a client that dropped GraphQL

The sharpest comparison is not with Apollo. It is with a client that took
Relay's ideas and removed GraphQL.
[fate](https://github.com/nkzw-tech/fate) is a data client for the web whose
1.0 shipped in May 2026, read here from its repository at 1.7.7 in October
2026. It keeps Relay's three insights: a normalized cache, declarative data
dependencies, and views colocated with their data. It drops the language as
the adoption barrier. A view is a plain object literal. A spread is an
object spread. A planner flattens views into field paths at run time.

fate is a serious piece of work by one author. Where it agrees with Baton, it
agrees with decisions Baton had already settled: a release buffer of ten; an
optimistic layer over the confirmed base, rebased beneath later writes; a
partial optimistic record, whose absent fields leave the store alone; a
request marked stalled after one refetch; an expiration per request; and a
hydration scope that refuses another client's snapshot. That is evidence,
from a different starting point, that the mechanisms are right.

Where it differs is where Baton's principles decide. Each difference is a
concept Baton would have had to add.

- **A planner at run time, and agents in place of a compiler.** Baton's rule
  is that the compiler decides. A diagnostic at the character is the loop a
  developer, or an agent, iterates on. A plan computed once at build time is
  a plan the phone never computes.
- **Automatic list insertion by heuristic.** fate guesses which lists a
  created record belongs in. In Baton, an edge directive names its
  connection, because a guess about membership is a policy in the store.
- **A wire protocol of its own.** Baton asks nothing of a server beyond the
  specification. It runs against fate's own GraphQL template server, as a
  proof of that. The responses it recorded there are fixtures in
  `spec/fate/`, passed by both runtimes.
- **An offline mutation journal.** Baton is not an offline sync engine, and
  it says so on the first page. The concept is on a watch list kept in the
  planning notes, with its trigger.

None of this is a verdict on fate for the web, but the closed inventory
doing its job. Each of those four would have been a thirteenth word. The
test says what each would have had to show first.

## Beside the configured clients

Apollo's native clients are the other direction. Their own documentation
shows the cost. Apollo Kotlin's documentation says its response-based
codegen can grow exponentially with fragment nesting, so operation-based is
the recommended default ([the
docs](https://www.apollographql.com/docs/kotlin/advanced/response-based)).
That is two codegen modes before the cache's options begin.

Apollo iOS users reported about 20 MB of app size, and about 50,000 generated
lines, from a sixteen-line fragment change under field merging. Field merging
is the option that controls whether a parent's model exposes a child's
fields
([apollo-ios#2560](https://github.com/apollographql/apollo-ios/issues/2560)).

Identity is a type policy, a field policy, or a function. Freshness is a
fetch policy per call, plus an expiration in the cache. The cache is memory,
SQL, or a chain, all of it read off the main thread. Every one of those
options answers a real complaint.

Baton's bet is that the complaint is better answered by a mechanism with no
knob. Masking is the shape of the type, so there is no field-merging option.
Identity is read from `baton.json` by the compiler, so there is no key
generator. Reads are synchronous, so there is no thread policy for the
cache.

## What it buys

What it buys is a vocabulary that fits on one page, so a new engineer, or a
coding agent, can hold the whole model. There is one way to do each thing,
so a review asks whether the fragment is right, and not which of three
mechanisms was chosen. A second runtime was written against the same twelve
words within a week, because there were only twelve to write. The
documentation is short because the surface is.

There is also depth where it counts. Each concept was designed, measured
against the oracle, and built once per runtime. A client that covers twice
the ground
does that half as well, and the half shows in the first frame and in the
bugs.

The cost is that some problems are not solved here. An app whose state is
mostly not a graph on a server, one that needs offline sync, or one that
pages by number against a server that cannot change, finds the edge of the
inventory quickly. The watch list in the planning notes says what would move
it.

A few strict rules are better than lots of features, which is how a screen
stays one request, a view stays one fragment, and a change stays one
re-render.
