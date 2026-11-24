# Client data is described by the schema and written by a payload

Status: accepted, 2026-10-04; supersedes the planning log's "no client
schema extensions in v1", and leaves its "no resolvers" standing. Serves
[What earns a concept](../principles/what-earns-a-concept.md),
[Relay's words](../principles/relays-words.md) and
[The store is the UI's state](../principles/store-is-the-ui-state.md).
Reopen if a real write cannot be said as a payload for an operation, or if
adopters' stores fill with state no fragment of a view reads.

## Context

Few apps are GraphQL from end to end. Two adopters asked within two days.
The first outside one named a REST endpoint that returns an entity the
schema also describes, a socket of its own protocol whose ticks update
records, a push that carries part of an entity, and a value the device
computes ([#13](https://github.com/shergin/baton/issues/13)). The
project's own dogfooding app has a list whose spine is REST: notification
threads that exist in no GraphQL schema, each pointing at a pull request
that does.

As built, an app writes to the store through a fetch, a mutation or a
subscription event and nothing else, and the schema is the server's alone.
Relay's front end takes schema extensions; the compiler passes it none. The
runtime does hold client data, but only its own: a connection's record with
its loading flags and edge index, and the three roots.

Relay has four words here: client schema extensions, `commitPayload`,
`commitLocalUpdate` and resolvers. The strategy refused extensions and
resolvers together, as a local-state framework. The first answer on the
issue left extensions open until a screen showed client data that has to
take part in the store's own semantics. The list above is that screen. It
needs the store to know that a thread points at a pull request, so the pull
request is kept and identified, and it wants to be drawn from the image at
launch. A model beside the lens gives neither.

## Decision

The schema describes what the store can hold, a payload writes it, and a
lens reads it: the same three for data the server sent and data it did not.
All of it is *(planned)*.

- `commitPayload(operation, payload)` is the one door for data from outside
  the transport: the operation's plan over a payload in a response's shape,
  with the ingest, the commit and the image a fetch has. Data the schema
  already describes needs nothing more.
- Client schema extensions come under Relay's key, `schemaExtensions`:
  `.graphql` files that give server types client fields or declare types
  the server does not have. They add to the description and to nothing
  else.
- A client field is written through that door only: a local update is a
  payload for an operation that selects the field. A lens reads it like any
  field, so one fragment can join a row the server never sent with an
  entity it did.
- The compiler leaves client fields out of the text and the id it prints
  for a server, and the plan marks where a field comes from, so the
  availability check and the heal do not wait for what no server sends.
- Client records live while a retention reaches them, their operation is
  dated by its commit, and they reach the image as any record does.
- Baton stores what it is given and computes nothing. No resolvers, no
  generated setters, no `commitLocalUpdate`, no payload or plan for a
  fragment, no `@commitable`.
- It is built after the write path and the plan's work on a field's origin,
  which it is composed from. Two details wait for the build: whether a
  client field may be non-null, and whether an operation of client fields
  alone is allowed, where Relay asks for one server field.

## Evidence

- The two requests, and the one screen: a list of rows from REST, each
  linked to an entity from GraphQL.
- The compiler as built: `pipeline.rs` builds its schema with Relay's
  `build_schema_with_extensions_parallel` and an empty list of extensions.
  [Relay's words](../principles/relays-words.md) already counts schema
  extensions among the configuration a web project has and Baton reads.
- The runtime as built: `Store.commit` is `package`; the connection's
  client fields are told apart by a list of two names in the image's code.
- Relay's guide to client schema extensions, read 2026-10-04
  ([guide](https://relay.dev/docs/guides/client-schema-extensions/)): the
  `schemaExtensions` key, client fields on server types and client-only
  types, read through ordinary queries with one server field, written with
  `commitLocalUpdate`, kept while rendered or retained.
- Not measured yet: a payload committed for every tick of a stream. It is
  benched before the door is recommended for one.

## Not chosen

- The app's own model beside the lens for everything the server did not
  send, which is the answer as built. It is right for a flag. For a list
  that links into the graph, the store cannot keep or identify what the
  list points at, cannot draw it from the image, and every row joins two
  sources by hand.
- `commitLocalUpdate` with generated setters: a second way to write, beside
  the plan.
- A payload for a fragment, with `@commitable`: a plan per fragment and a
  new directive, for what an operation already does.
- Resolvers, or any field Baton computes: logic in the store, which is the
  local-state framework the README declines.
- Reaching a record to set a value on it: imperative updaters stay where
  they were, behind a real write that a payload cannot express.
- A directive that says whether a client field is persisted: what may reach
  the image is a rule about types, proposed apart.
- Waiting for a second screen: both adopters asked in two days, and the
  first screen is in the project's own app.

## Settled by the build, 2026-10-11

The two details left to the build are settled as the extensions landed. A
client field is nullable: an extension declaring a non-null client field is
refused at its own line, since the schema cannot promise what no server
sends and a lens reads the field as absent until a payload writes it. An
operation of client fields alone is refused at its name: the text a server
receives would select nothing, and a server answers one field at least, so
a client-only type such as a list of drafts is read beside a server field.
A payload committed for every tick of a stream is still unbenched; the door
is not yet recommended for one.

## A client-only operation, 2026-11-05

Supersedes the second sentence of the section above: an operation of
client fields alone compiles. The refusal's reason, that a server answers
one field at least, holds for an operation that is sent, and a client-only
operation is never sent. Relay has the word: `useClientQuery`, a query of
client fields alone, executed against the store and never sent to the
network, and `loadClientQuery` since v20. Baton had every part, client
fields written through the door, a handle whose attach never fetches, the
image carrying client records, and refused the composition. The adopter's
evidence came from the other side of the line: an adopter's app keeps snoozes,
offsets and marks per media in a local state beside the store and
persists it by hand, a second store for per-entity facts a client field
describes exactly.

- A query whose fields are all the client's compiles. The compiler marks
  it client-only; its document is the text the author wrote, printed with
  its client fields from the program before Relay's text transforms, since
  those leave nothing of it to send; it takes no persisted id and is left
  out of the persisted documents file; the report says so.
- Its handle attaches as `storeOnly` whatever policy the view asks. The
  availability check waits for no client field, so the operation is present
  at once and its fields read absent until a payload writes them; nothing is
  stale, since there is no network to be stale against. No fetch is ever
  made for it: not by an attach, an invalidation, a revalidation or a heal.
  `refetch()` throws the fetch's environment kind, a new case,
  `clientOnly`: the operation selects client fields alone, so there is
  nothing to send; `Environment.fetch` throws the same.
- `commitPayload` writes it, as it writes every client field, and the
  image keeps its records as any record's.
- A mutation or a subscription of client fields alone stays refused: a
  mutation is sent by definition, and a subscription is a server's stream.
  A local write is a payload committed for a query that selects the
  fields, as before.

Not chosen: a document with no text, which would give `Request` a third
kind of document for a request that is never made; an implicit `storeOnly`
spelled by the view, which would let a `networkOnly` attach of a
client-only operation fetch nothing and say nothing; and keeping the
refusal, which sends per-entity state out of the store, where the first
section of this record says it belongs.

## Another backend is schema, 2026-11-23

This record stands, and its line is drawn: a client field is what no
transport is asked for. A second backend the app's own transport answers,
a socket of another protocol or a REST endpoint, is not client data. Its
fields are declared in a file of the schema, which may `extend` a type
there and keep the fields the server's, and are sent, waited for and
healed like any server field. The refusal of a mutation or a subscription
of client fields alone stands, and its message says where such a field
belongs. [The schema is what the transport answers](the-schema-is-what-the-transport-answers.md)
is the record.

## A stream's ticks, measured, 2026-11-23

Supersedes the Evidence's last item, that a payload committed for every
tick of a stream is not measured yet, and the last sentence of "Settled by
the build", that the door is not yet recommended for one. It is measured,
and recommended in a paced shape.

[The bench entry of 2026-11-23](../../BENCHMARKS.md#unreleased-a-feeds-ticks-through-the-two-doors--2026-11-23)
measured the Swift runtime on an Apple M1 Pro: ticks of two scalar fields
committed through `commitPayload` one call a tick and through a
subscription the app's transport answers, at 1 to 1,000 ticks a second
over 1, 10 and 100 keys, sustained for ten seconds with an image attached
and 21 readers, beside bursts of 1,000 and one payload of 100 keys. The
Kotlin runtime was not benched.

- Delivery kept up in every run: the last tick committed within 7.1 ms of
  its send through either door, and the image's writer emptied its queue
  within 7.3 ms of the last tick.
- The limit is the main thread's share of each frame. It crosses a tenth
  of a frame per frame, 100 ms/s, at 1,000 ticks a second, through
  `commitPayload` over 1 key and over 100 and through the subscription
  over every key count; at 100 ticks a second the highest is 79 ms/s.
- The cost is per commit far more than per value: a tick costs the main
  thread 13 µs called back to back and 89 µs or more at a sustained rate,
  and one payload carrying 100 keys 176 µs.
- The shape recommended for a service: decode off the main actor, keep
  the newest pending value per key, and once per interval commit one
  payload through a client-only query over a client list field of the
  server's type, its root field transient. At 1,000 ticks a second over
  100 keys it cost the main thread 10.9 to 55.6 ms/s at 30 and 60 commits
  a second, against 548.1 for a commit per tick in the same run, and wrote
  a tenth of the bytes. [A fast stream, paced](../recipes/stream.md) is
  the recipe.
- Two costs come of the store's collection, a mark of the store on the
  main actor. A root per key that nothing holds is pushed out of the
  release buffer by every tick past ten keys, and a collection follows:
  over 100 keys, 405.4 ms/s at 1,000 ticks a second against 89.0 with
  every root held. A commit that drops a link schedules a collection too,
  so a paced list carrying only the keys that ticked costs one a commit;
  listing every known key keeps the list growing and runs none, 32.2
  against 10.9 ms/s at 30 commits a second. How eagerly the store
  collects is its own schedule, set by a bench; these costs describe
  today's schedule, not the contract.
- No batching API was added: no `commitPayloads`, and the runtime merges
  or drops no tick. A merge would have to know that a newer value for a
  key supersedes an older one, which only the app knows, and one payload
  per interval already costs what the bench shows.
