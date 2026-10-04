# The compiler decides; the runtime executes

Every operation is static. Identity, aggregation, masking, storage keys,
persisted ids, nullability and diagnostics are settled at build time. The
runtime interprets plans; it never parses GraphQL, hashes a field name or
consults a policy object.

## Why

A client that reasons about GraphQL at run time pays for it on every request
and in every binary: a parser, a validator, an executor over selection
metadata, string-keyed records, type policies looked up by name. It also
cannot tell a developer at build time that a field does not exist, that a
parent never spread the fragment a child reads, or that two operations will
collide in the cache. Meta's native apps compiled operations ahead of time
and shipped ids instead of text before Relay existed; the clients that did
not are the ones with 150 ms of type mapping behind 6 ms of parsing.

The opposite failure is a compiler that knows too little: one that validates
documents but leaves aggregation, identity and cache behaviour to runtime
configuration. Then the same cache bugs return, with a build step added.

## The idea

The compiler reads the schema, the identity configuration and every document
in the app, whether in Swift source or `.graphql` files. It validates, applies
fragment arguments by cloning per unique argument set, inlines fragments into
one normalization plan per operation, inserts the key fields and typenames
identity needs, interns every storage key to a slot, hashes the operation text
to a persisted id the transport can send, and emits the lens types and the
plans. Errors carry the
file, line and column of the GraphQL text inside the Swift source. The front
end is Relay's compiler, pinned, behind a driver that is ours; the plan format
is the seam between the two.

The runtime is a tokenizer that follows a plan, a store that merges slots,
accessors that read them, and a transport that sends ids. It has no opinion.

## Consequences

- Nothing is configurable at run time that could be decided at build time.
  Identity lives in schema configuration; fetch behaviour is a directive or a
  value on a handle.
- Diagnostics are a build artifact and appear inline in the editor.
- A compile-time plan means a compile-time size: the bench suite fences bytes
  of generated code per field.
- The Swift and Kotlin runtimes consume the same plans, so they can only
  disagree in execution, which the fixtures catch.
- Adopting a new specification feature is our decision, not a dependency's.

## Not this

- A GraphQL parser or executor in the runtime.
- Type policies, key resolvers, merge functions or interceptor chains
  registered at run time.
- Generated code that carries selection metadata for an executor to walk.
- Depending on an upstream compiler as an extension host whose plugin API we
  do not control.

See [Relay's words](relays-words.md) for why the front end is Relay's, and
[A fragment is a lens](fragment-is-a-lens.md) for what the compiler emits.

## Spelled today

Nothing is spelled yet. Planned: `batonc`, a SwiftPM build-tool plugin over a
binary artifact bundle, a CLI mode, `baton.json`, and `<File>.baton.swift`
outputs beside each source that declares GraphQL. This section may rot; the
rest must not.
