# Baton beside fate

The most instructive comparison for Baton is not with the clients it replaces
but with one that started from the same place and turned the other way.
[fate](https://github.com/nkzw-tech/fate) is Christoph Nakazawa's data client
for the web: 0.1.0 in December 2025, 1.0 in May 2026, read here from its
repository at 1.7.7 in October 2026, written in practice by one author. It
takes Relay's three insights, a normalized cache, declarative data
dependencies and views colocated with their data, and removes GraphQL as the
adoption barrier. Baton takes the same three insights and keeps the compiler.
Where the two agree, they agree on mechanisms Baton had already settled, which
is evidence. Where they differ, they differ on exactly the points Baton's
principles decide, which is the clearest statement of what those principles
are for. And three of fate's mechanisms are worth watching, each with the
trigger that would bring a version of it into Baton.

## What fate is

A view in fate is a plain object literal, `view<Post>()({ title: true, author:
UserView })`, and a spread is an object spread. A planner at run time flattens
the views of a screen into dotted field paths and sends them over fate's own
wire protocol, a `POST` with a `byId` and a `list` root per type; tRPC and
GraphQL transports sit beside it. There is no compile-time check; asked for a
compiler, the author answered that agents fill that role ([its issue
20](https://github.com/nkzw-tech/fate/issues/20)). Mutations are React Actions
with a partial optimistic record, and an `insert` places a created entity into
the lists it matches by a heuristic. `useLiveView` is field-scoped server push
over one server-sent-events stream. Persistence is IndexedDB with an age per
request, and a durable offline mutation journal with idempotency receipts on
the server. Every template ships an `AGENTS.md`, and the docs are copied into
the npm package so an agent reads them from `node_modules`.

It is a serious piece of work, and it is for the web. Nothing below is a
verdict on it there. The comparison is about design.

## Where the two agree

Each row is a mechanism fate chose from Relay's side of the line and Baton had
chosen already, with the record that says so.

| fate | Baton |
|---|---|
| A release buffer of ten, "inspired by Relay" | The release buffer, ten by default ([the terminology](../terminology.md)) |
| An optimistic layer over the confirmed base, rebased beneath later writes | Optimistic layers over the base, rebased on every commit |
| A partial optimistic record whose absent fields leave the store alone | A typed optimistic response that carries part of a selection |
| A request marked stalled after one refetch | The heal refetches once per fetch ([the principle](../principles/honest-data.md)) |
| An age per request | An expiration per operation, stated in its document ([the decision](../decisions/an-operation-states-its-expiration.md)) |
| A hydration scope that refuses another client's snapshot | The image's digest: a file written under another schema starts again ([the decision](../decisions/what-may-reach-the-image.md)) |
| Masking enforced: a reference carries the tags of the views spread into it, and a read without the tag throws | Masking as the shape of the type: the lens has no accessor for what it did not declare ([the principle](../principles/fragment-is-a-lens.md)) |
| Mutations as actions | An action, in the terminology |

Two clients that started from Relay and never spoke arrived at the same buffer
size, the same optimistic model, the same answer to a refetch that does not
fill a hole, and the same refusal to hydrate from a foreign snapshot. That is
the part of Relay that is about data rather than React, and it is the part
Baton kept.

## Where Baton does not follow

Four of fate's choices are the ones Baton's principles rule out, and each
would have been a new concept in a closed inventory ([the
principle](../principles/what-earns-a-concept.md)). A principle has no
reopening condition, which is the difference between it and a decision.

- **A planner at run time, with agents in place of a compiler.** Baton's rule
  is that the compiler decides and the runtime executes. A diagnostic at the
  character in the file is the loop an agent iterates on best, so the "we have
  agents" answer runs the other way: a run-time planner is weaker for agents,
  not stronger, because nothing tells the agent its view is wrong until a user
  does.
- **Automatic list insertion by heuristic.** A guess about which lists a new
  record belongs in is a policy in the store. In Baton an edge directive names
  its connection ([the
  decision](../decisions/connections-own-their-edges.md)).
- **An offline mutation journal.** Baton is not an offline sync engine and
  says so on its first page. Offline sync sits on the watch list that
  principle keeps outside the plan, behind its trigger.
- **A wire protocol of its own.** Baton asks nothing of a server beyond the
  GraphQL specification, and a Swift "views as objects" surface in fate's
  image would be a second way to write a document beside the GraphQL in the
  markers, which the records refuse as two constructs for one thing ([the
  decision](../decisions/marker-macros.md)).

## Three mechanisms to watch

The honest part of a comparison is what the other side does better, and
whether it is wanted. Each of these has a trigger, written here, that would
bring a version of it into Baton.

**Entity-level fill.** When a record lacks a field a view needs, fate fetches
only the missing paths of that one record, by id. Baton's heal refetches the
owning operation whole. The composition, if a screen ever needs it, uses what
exists: heal through the fragment's `@refetchable` query, or a lookup, when
one exists, and the owning operation otherwise. No new concept, a narrower
choice of which operation the heal runs. The trigger is a measured heal that
refetches a screen's operation for one row's field.

**Write ordering by request start.** fate keeps a generation per record and
per list, stamped when the request started, and drops an older response's
write over a newer one's. Baton commits in completion order, and the runtime
contract says nothing about ordering between operations, so a slow
`storeAndNetwork` fetch that started first can land after a quicker refetch
that started later. The cost of fate's answer is a sequence per written slot,
which sits beside a refusal Baton has already made, an age per record or per
field; the argument would have to show it is an ordering, not an age. The
trigger is a fixture reproducing the overwrite on a real screen.

**Fragment-declared liveness.** `useLiveView` declares on the view that its
fields are pushed. `@live` is a proposal in GraphQL's working group rather
than part of the specification, and Relay's `@live` marks a client resolver,
not a server push ([Relay's live
fields](https://relay.dev/docs/guides/relay-resolvers/live-fields/)), so the
composition today is a subscription beside the query, which the transport and
the handle already carry. The trigger is an adopter's server that pushes
entity updates and a screen where one subscription per fragment proves
awkward.

## Two things taken

Two things came out of the reading, neither a change to the runtime.

The first is a page. fate's `AGENTS.md` per template is the right idea, and
Baton's version is [the agents recipe](../recipes/agents.md): what to read,
the shape of a screen, what never to write, what to run, and a review
checklist. Baton's page points the agent at the compiler's diagnostics, which
is the loop fate lacks.

The second is a proof. fate's GraphQL template is a Pothos and Yoga server
over Prisma and Postgres, with `nodes(ids:)`, cursor connections, and live
nodes and connections over graphql-sse: standard GraphQL. On 9 October 2026
the template was run as it ships, with no change, and Baton's documents were
sent to it; the responses it recorded are fixtures under
[`spec/fate/`](../../spec/fate/README.md), proven by a Swift test target and
the Kotlin harness. Two pages of a posts connection, one post by `node(id:)`,
a mutation signed in as the seeded user, and the event stream of a live post.
Baton ran against fate's server unchanged, because it asks nothing of a server
that the specification does not. The recording also found the template's limit
for a normalized client: its live node answers a JSON scalar keyed by the
database id rather than typed fields under the post's global id, so its events
land at the subscription root and leave the post's record as it was. That is a
fact about the shape of the schema, and the fixture says it.

## What the comparison says

fate shows what Relay's insights look like with the language removed: a
smaller barrier to entry, a planner on the client, heuristics where the
compiler would have had facts, and a protocol of its own. Baton shows what
they look like with the compiler kept and the runtime deleted: one request per
screen assembled at build time, a wrong field as a build error, a lens that
cannot read what it did not declare, and any server that follows the
specification. The two agree wherever the question is about data and disagree
wherever it is about who decides. Baton's answer is the compiler, and the
records and principles linked above are the price of that answer, paid once.

## Sources

fate was read from [its repository](https://github.com/nkzw-tech/fate) at
commit `15af87c`, version 1.7.7, on 9 October 2026: the README for what a
view, a spread and a live view are and for the transports; the client at
[`packages/fate/src/client.ts`](https://github.com/nkzw-tech/fate/blob/15af87c/packages/fate/src/client.ts)
for the release buffer, the optimistic layer, the stalled request, the
hydration scope, the list insertion and the write generations; the templates
for their `AGENTS.md` and for the GraphQL server
[`spec/fate/`](../../spec/fate/README.md) was recorded from; the repository's
releases for the dates and the commit log for the authorship; and [issue
20](https://github.com/nkzw-tech/fate/issues/20) for the compiler question.
Baton's side is the records linked inline.
