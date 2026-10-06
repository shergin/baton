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
