# Vision

Baton is Relay for native apps. You declare the fields a view reads next to
its body, and that piece of GraphQL is a fragment. The compiler gathers a
screen's fragments into one operation and checks every field against the
schema before the app runs. The runtime turns responses into records that
the UI framework itself observes, so a screen fetches once, renders cached
data in the first frame, and re-renders only the views whose fields changed.

The goal is not the biggest feature list. It is the smallest set of concepts
that makes the data layer disappear from product code. A few strict rules
beat lots of features. That is how a screen stays one request, a view stays
one fragment, and a change stays one re-render.

That means three commitments:

- **The view never sees the data layer.** No query files to keep in sync. No
  cache-update code. No view model copying fields around. A fragment next to
  a body, and the data is there.
- **Every claim can be checked.** A lens is the typed view a fragment
  compiles to. Reading a field through a lens equals reading the raw
  response at the same path. Every advertised number comes from a bench
  recorded with device, OS and date. A view that re-rendered did so because
  a field it read changed, and a test can count it.
- **Relay's language, native's mechanisms.** Directives, conventions and the
  compiler's front end are Relay's, so web and native teams speak one
  language. The parts of Relay that exist because React could not see who
  read what are replaced by what SwiftUI and Compose can see.

Relay built a runtime to answer one question: which component read which
field, so a change re-renders exactly those. SwiftUI's Observation and
Compose's snapshot state answer that question already. Baton therefore
keeps Relay's compiler and the write side of its store, and deletes the
read side rather than porting it.

- The compiler finds the GraphQL in source and validates it against the
  schema. It aggregates fragments into operations, applies fragment
  arguments, computes every storage key, hashes persisted ids, and emits a
  typed lens per fragment and a normalization plan per operation. Errors
  point at the GraphQL text inside the Swift file.
- The transport can send a persisted id and variables, and it streams bytes
  back.
- The ingest decodes a response's bytes straight into record slots, off the
  main actor, with no intermediate model.
- The store commits a change set on the main actor: writes for the slots
  that changed, and notifications for the fields that observed views read.
- A lens reads a record's slots synchronously, and registers each read with
  the framework. A view body is invalidated by the fields it read, and by
  nothing else.
- Persistence is a write-behind image, hydrated before the first body. An
  entry that cannot be read is a miss, never a migration.

Adoption may follow. It is never chased: no parity race with Apollo, no
feature bazaar, no runtime knobs.

## Who it is for

Teams that already run Relay on the web and want the same model on iOS and
Android come first. The schema conventions, the directives and the
vocabulary carry over, and the native screens gain what the web ones have.

Native teams on GraphQL come second. They are tired of loading flashes,
whole-screen re-renders, hand-maintained queries and caches that grow
without bound. Baton's answers to those complaints are mechanisms, not
settings.

Swift first, Kotlin later. The compiler, the artifact format, the vocabulary
and the conformance fixtures are shared. Each runtime is written for its
platform and feels like it.

## The rules

Five rules, one axis each: what a fragment means, what the UI reads, what is
true, who decides, and what the words are.

1. **A fragment is a lens.** A fragment compiles to a lens, a typed
   read-only view over one record: a reference and one accessor per field
   you declared. Nothing is decoded into a model to hand to a view. A
   parent passes a reference and a context. Masking is structural rather
   than enforced, because the lens has no accessor for a field the fragment
   did not declare.
2. **The store is the UI's state.** Records are observable objects. A body
   that read a field is invalidated when that field of that record changes,
   and at no other time. Reads are synchronous on the main actor, and
   commits are atomic batches there. The availability check runs there too,
   and reads the image when memory lacks a record. Collection runs there,
   and so does the normalization of an optimistic response, whose layer
   shows in the turn of the call. Decoding a response and writing the image
   run off the main actor. There is no asynchronous read path for views.
3. **The response is the oracle.** Whatever path a value takes, through
   ingest, interned slots, optimistic overlays and persisted images,
   reading it through a lens equals reading the raw response at the same
   path.
   Anything faster has to reproduce the oracle exactly. Missing data is
   reported and healed, never invented silently.
4. **The compiler decides; the runtime executes.** Every operation is
   static. Identity, aggregation, masking, storage keys, persisted ids and
   diagnostics are settled at build time. The runtime interprets plans and
   never parses GraphQL or consults a policy object. No path a view or a
   commit takes hashes a field name. The compiler emits a constant per
   storage key, and the process numbers it once
   ([decision](decisions/slots-are-numbered-by-the-process.md)).
5. **Relay's words, a closed set.** The vocabulary is Relay's and the
   GraphQL specification's wherever they have a word. The concept inventory
   is closed. A feature is a composition of existing concepts, or a
   directive the compiler understands, or it does not ship.

## Principles

Constraints the vision names without arguing. One file per principle. The
type names in each "Spelled today" section may rot. The rest must not.

- [A fragment is a lens](principles/fragment-is-a-lens.md)
- [The store is the UI's state](principles/store-is-the-ui-state.md)
- [The response is the oracle](principles/response-is-the-oracle.md)
- [The compiler decides](principles/compiler-decides.md)
- [Honest data](principles/honest-data.md)
- [What earns a concept](principles/what-earns-a-concept.md)
- [Relay's words](principles/relays-words.md)
- [Two runtimes, one compiler](principles/two-runtimes-one-compiler.md)

## Decisions

Choices made among real alternatives live in [decisions/](decisions/). Each
one has its evidence, and the condition that would reopen it. Decisions may
be superseded. Principles may not.

## Openings

Decisions and what they paid for will be recorded in `openings/` as the
project ships them. None yet.
