# The schema is what the transport answers

Status: accepted, 2026-11-23. Leaves
[client data is described and committed](client-data-is-described-and-committed.md)
standing and draws its line. Serves
[What earns a concept](../principles/what-earns-a-concept.md),
[Relay's words](../principles/relays-words.md) and
[The response is the oracle](../principles/response-is-the-oracle.md).
Reopen if Relay changes what an extension in a schema file means, if an
app needs one operation answered by two backends, or if an adopter's
registration step cannot leave out the documents another backend answers.

## Context

An app has, beside its GraphQL server, a WebSocket API of its own
protocol, and wants that data in the store, ideally as a subscription a
view holds like any other. The app's own `Transport` can answer such an
operation: it sees the request's name and kind, and yields payloads.
What it could not do was declare the fields.

Until this record, the one declaration that worked was writing the field
into the server's SDL by hand, inside the type's own definition. A field
under `schemaExtensions` is a client field, and a subscription of client
fields alone is refused, since a subscription is a server's stream. An
`extend type Subscription` in the schema file itself did not help either:
Relay's builder at the pinned v21.0.1 marks every field an `extend`
declares as a client field, whichever list the file came in
(`compiler/crates/schema/src/in_memory.rs`, `build_extend_fields`). It
also refuses an extension written before its type
(`ExtendUndefinedType`, "the type is not defined on the server schema"),
and has no code for `extend schema`, `extend input` and `extend scalar`:
it stops at a `todo!`. So a hand-written modular SDL that extends
`Query` per module compiled into client fields, or failed on a non-null
"client" field, though every field in it is the server's.

The GraphQL specification reads an extension otherwise. Its text on type
extensions names a service that extends another service as a use: the
keyword says a definition is continued elsewhere, not who answers it.

## Decision

- The schema describes what the transport answers. The client schema
  extensions describe what the client adds, written by `commitPayload`
  and asked of no one. A second backend the app's own transport answers
  for, a socket of another protocol or a REST endpoint, is more schema,
  not client schema: to the store its fields are server fields, sent,
  waited for by the availability check and healed like any other.
- The refusal of a mutation or a subscription of client fields alone
  stands. Its message now says where a field another backend answers
  belongs: in the schema, not in `schemaExtensions`.
- Where a file is listed says whose its fields are, whatever keyword
  declares them. A file of the schema may `extend` a type, and the fields
  are the server's; a file under `schemaExtensions` declares client
  fields. Baton's driver parses the schema files itself, builds every
  definition before every extension, so an extension may come before its
  type in the file order, and marks a schema file's extensions as the
  server's. `extend schema`, `extend input` and `extend scalar` are
  diagnosed at their line, since Relay's builder has no code for them.
- The schema may be several files. Relay's `schemaDir` in `baton.json`,
  in place of `schema`, names a directory whose `.graphql` files, in name
  order, are the schema together; naming both is an error. `batonc`'s
  `--schema` may repeat and may name a directory. The SwiftPM plugin and
  the Gradle plugin declare the directory's files as inputs; the Bazel
  rule's `schema` attribute takes a target of several files and passes
  each as `--schema`.
- The schema's files are a set. Every definition is built before every
  extension, so the order the files are given in does not matter, and the
  schema's digest, which versions the image, is the same for the same
  files in any order and under any names, since the compiler sorts their
  texts before hashing; a schema of one file keeps the digest it had.
- One operation is answered by one transport. The app's transport routes
  by `Request.operationName`; nothing in the library splits an operation
  between backends, and the library ships no router.
- Under `persistConfig`, an operation another backend answers takes an id
  and lands in the persisted documents file like any other. The app's
  registration step leaves it out.

## Evidence

- The pinned Relay source, read 2026-11-23: `build_extend_fields` marks
  the fields of every `extend` as client fields, in the schema's files as
  in the extensions'; an extension of a type not yet built fails with
  `ExtendUndefinedType`; the three unbuilt extensions reach a `todo!`.
- The compiler's tests: a schema directory whose feed file sorts before
  the server's compiles, and the feed's field, declared by an `extend` in
  a schema file, is printed in the operation's text as a server field.
- The runtime's feed tests, eight in each language, over a documents
  target whose `baton.json` names `schemaDir` and whose feed file sorts
  before the server's: a subscription over the feed's field, answered by
  the app's transport, merges each tick into the record a query's lens
  reads; every other request reaches the wrapped transport as the
  environment wrote it; a failed feed stream is reopened by the handle
  after its backoff, and a released handle ends it; an edit to the feed's
  schema file regenerates under SwiftPM and under Gradle.
  `scripts/check-bazel.sh` builds and checks a target under
  `bazel/examples/rickandmorty/several` whose schema is a filegroup of two
  files, the extension's file first.
- [A backend that is not GraphQL](../recipes/another-backend.md) is the
  composition, in both runtimes.

## Not chosen

- A client-only subscription sent to the app's transport. "Client" would
  mean two things, never sent and sent to the app; and a client-only
  subscription in the existing sense would have no stream, which a lens
  observing the store already is.
- Resolvers, and Relay's `@live` resolvers, which are Relay's own answer
  for live client data. The client-data record refuses fields Baton
  computes, and its reopening trigger, a write no payload can say, is not
  met: a tick is a payload.
- `schema` as a list. Relay has the word, `schemaDir`.
- Folding an extension's fields into its type's definition before the
  build. A diagnostic would point into the wrong file.
- A directive or a mark per field that names its backend. The file says
  it once, and the transport already routes by the operation.
- A router type in the library. Routing by name is one `if` in the app's
  transport, and the app owns the second backend's client.
