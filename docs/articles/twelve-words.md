# Twelve words, and why the list is closed

GraphQL clients die of configuration. Each real complaint becomes an option: a
cache policy here, a type policy there, a merge function, a link in a chain, a
flag on codegen. Ten years later the client has four codegen modes, a dozen
cache policies and a documentation site explaining which combinations work.
The complaints were real; the answers multiplied the surface instead of fixing
the mechanism. Baton's vocabulary is twelve concepts and Relay's directives,
and a feature that is not a composition of them does not ship. This page is
what that rule refuses, what it buys, and how it looks beside a client that
went the other way.

## The twelve

Schema, document, directive, lens, record, store, plan, operation value,
connection, environment, transport, phase. The server's menu; a query, a
mutation, a subscription or a fragment beside a view; the only way behaviour
attaches to data; a typed read-only view over one record; an observable object
keyed by type and id; all records, owned by the main thread; how a response
becomes records, decided by the compiler; an operation's variables, the thing
a parent constructs; a list that pages, merged in the store; the session, one
store and one transport; one verb, `send`, yielding payloads; loading, ready
or failed, always readable.

[The terminology](../terminology.md) marks each of its entries with its place
in that inventory: the concept it is or is a form of, or the concepts it is a
composition of. An owner is a lens and an operation value. A mutation's action
is an operation value and a payload. A heal is a phase, a store event and a
fetch. Nothing ships that is not named there, and a name comes before a type
in code.

A concept enters through one test, with two clauses, both required: real
screens demand it, screens people build rather than screens a completeness
argument names, and no composition of the existing concepts expresses it ([the
principle](../principles/what-earns-a-concept.md)). Two words are Baton's own,
because the things they name are new: a lens, which is Relay's fragment
reference and fragment data as one value, and a plan, the normalization
artifact as data. Everything else is Relay's or the specification's.

## What the rule refused

The first adopter filed twenty-one issues in the project's first week, and
answering them is the best record of the rule at work. Each refusal carries
the reason and the condition that would reopen it; the decisions directory has
the long form.

- **A retention policy per type.** The request was a budget: keep so many of
  these, evict those first. The answer is the mechanism that already exists, a
  release buffer of ten roots, collection from the roots, and eviction from
  the image by launch and a size limit; a budget per type was refused, with no
  reopening condition, as a policy object at run time for what recency decides
  ([the decision](../decisions/the-image-evicts-by-launch.md)).
- **Shipped transport wrappers.** Retries, a deadline, a token refresh. The
  transport has one verb, credentials are read per attempt, and the wrapper is
  [a recipe](../recipes/exchange.md) of a few dozen lines the app owns,
  compiled in both languages and tested over a loopback server. A library
  wrapper would be a policy object with options.
- **A `@snapshot` directive.** Relay already has the word: `@inline`, a
  fragment that compiles to a value instead of a lens, built when the spread's
  accessor is called ([the
  decision](../decisions/a-fragment-has-one-reading.md)).
- **A store swapped under live handles at sign-out.**
  `Environment.replaceStore` would have needed a generation checked on every
  write path. Instead the environment is the session: a sign-in makes one, a
  sign-out ends it, and a handle still held reads `gone` ([the
  decision](../decisions/the-environment-is-the-session.md)).
- **Imperative store updaters.** Every write so far has been a directive on a
  fragment or a payload for an operation, and `commitPayload` is the one door
  a payload takes. A write neither can express reopens it.
- **A session type, a transport mode, a cache-update function, an age per
  record, automatic persisted queries.** Each is in the records with its
  reason.

Page-based pagination, a binary wire format and offline sync are on a watch
list in the planning notes, each with a trigger, not in the plan. Leaving a
problem unsolved is a fair answer; a half-built feature in the library is not.

## Subtraction is a contribution

The rule cuts both ways, and the changelog records removals as plainly as
additions. Four reporting hooks became one log of value-free events. A
generated line per lens, `typeName`, went when nothing needed it. Two
spellings of `fetch` became one. The placeholder environment went when the
handle learned to say it was not injected. A concept that stops paying for
itself is removed before 1.0.

## Beside a client that dropped GraphQL

The sharpest comparison is not with Apollo but with a client that took Relay's
ideas and removed GraphQL. [fate](https://github.com/nkzw-tech/fate), a data
client for the web whose 1.0 shipped in May 2026, read here from its
repository at 1.7.7 in October 2026, keeps Relay's three insights, a
normalized cache, declarative data dependencies and views colocated with their
data, and drops the language as the adoption barrier: a view is a plain object
literal, a spread is an object spread, and a planner flattens views into field
paths at run time. It is a serious piece of work by one author, and where it
agrees with Baton it agrees with decisions Baton had already settled: a
release buffer of ten, an optimistic layer over the confirmed base rebased
beneath later writes, a partial optimistic record whose absent fields leave
the store alone, a request marked stalled after one refetch, an expiration per
request, a hydration scope that refuses another client's snapshot. That is
evidence, from a different starting point, that the mechanisms are right.

Where it differs is where Baton's principles decide, and each difference is a
concept Baton would have had to add:

- **A planner at run time, and agents in place of a compiler.** Baton's rule
  is that the compiler decides; a diagnostic at the character is the loop a
  developer or an agent iterates on, and a plan computed once at build time is
  a plan the phone never computes.
- **Automatic list insertion by heuristic.** fate guesses which lists a
  created record belongs in. In Baton an edge directive names its connection,
  because a guess about membership is a policy in the store.
- **A wire protocol of its own.** Baton asks nothing of a server beyond the
  specification, and runs against fate's own GraphQL template server as a
  proof of that: the responses it recorded there are fixtures in `spec/fate/`,
  passed by both runtimes.
- **An offline mutation journal.** Baton is not an offline sync engine, and
  says so on the first page; the concept is on a watch list kept in the
  planning notes, with its trigger.

None of this is a verdict on fate for the web. It is the closed inventory
doing its job: each of those four would have been a thirteenth word, and the
test says what each would have had to show first.

## Beside the configured clients

Apollo's native clients are the other direction, and their own documentation
shows the cost. Apollo Kotlin's documentation says its response-based codegen
can grow exponentially with fragment nesting, so operation-based is the
recommended default ([the
docs](https://www.apollographql.com/docs/kotlin/advanced/response-based)), and
that is two codegen modes before the cache's options begin. Apollo iOS users
reported about 20 MB of app size and about 50,000 generated lines from a
sixteen-line fragment change under field merging, the option that controls
whether a parent's model exposes a child's fields
([apollo-ios#2560](https://github.com/apollographql/apollo-ios/issues/2560)).
Identity is a type policy, a field policy or a function; freshness is a fetch
policy per call plus an expiration in the cache; the cache is memory, SQL or a
chain, all of it read off the main thread. Every one of those options answers
a real complaint. Baton's bet is that the complaint is better answered by a
mechanism with no knob: masking is the shape of the type, so there is no
field-merging option; identity is read from `baton.json` by the compiler, so
there is no key generator; reads are synchronous, so there is no thread policy
for the cache.

## What it buys

A vocabulary that fits on one page, so a new engineer or a coding agent can
hold the whole model. One way to do each thing, so a review asks whether the
fragment is right and not which of three mechanisms was chosen. A second
runtime written against the same twelve words within a week, because there
were only twelve to write. Documentation that is short because the surface is.
And depth where it counts: each concept was designed, measured against the
oracle and built once per runtime, which a client that covers twice the ground
does half as well, and the half shows in the first frame and in the bugs.

The cost is that some problems are not solved here. An app whose state is
mostly not a graph on a server, one that needs offline sync, or one that pages
by number against a server that cannot change, finds the edge of the inventory
quickly, and the watch list in the planning notes says what would move it.
Better a few strict rules than lots of features: that is how a screen stays
one request, a view stays one fragment, and a change stays one re-render.
