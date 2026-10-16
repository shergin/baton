# The compiler decides; the runtime executes

Every operation is static, so the runtime interprets the plan and never
parses GraphQL.

Identity, aggregation, masking, storage keys, persisted ids, nullability
and diagnostics are settled at build time, and the runtime never consults
a policy object. No path a view or a commit takes hashes a field name.

## Why

A client that reasons about GraphQL at run time pays for it on every
request and in every binary. It carries a parser, a validator and an
executor over selection metadata, with records keyed by strings and type
policies looked up by name. The same client cannot tell you at build time
that a field does not exist, that a parent never spread the fragment a
child reads, or that two operations will collide in the cache. Meta's
native apps built their queries once, at build time, and sent an identifier
instead of the text, before Relay Modern adopted the same model. The
clients that did not are the ones with about 159 ms of type mapping behind
6 ms of parsing.

The opposite failure is a compiler that knows too little. It validates
documents, then leaves aggregation, identity and cache behaviour to runtime
configuration, so the same cache bugs come back. You only added a build
step.

## The idea

The compiler reads the schema, the identity configuration and every document
in the app, whether in Swift source or `.graphql` files. It validates, then
applies fragment arguments by cloning per unique argument set and inlines
fragments into one normalization plan per operation. Key fields and the
typenames identity needs are inserted. Every storage key is computed and
emitted as a constant, and the operation text is hashed to a persisted id
the transport can send. Lens types and the plans are emitted too.

The process numbers each constant the first time it is touched, and one
table is shared by every module, because modules compile apart and share
one store
([Slots are numbered by the process](../decisions/slots-are-numbered-by-the-process.md)).
A key with variables is resolved once per owner, and a field read through
an interface or union is resolved once per concrete type. Errors carry the
file, line and column of the GraphQL text inside the Swift source. The
front end is Relay's compiler, pinned, behind a driver that is ours, and
the plan format is the seam between the two.

The runtime is a tokenizer that follows a plan, a store that merges slots,
accessors that read them, and a transport that sends ids. It has no
opinion.

## Consequences

- Nothing is configurable at run time that could be decided at build time.
  Identity lives in schema configuration, and fetch behaviour is a directive
  or a value on a handle.
- Diagnostics are a build artifact, and they appear inline in the editor.
- A compile-time plan means a compile-time size, so the compiler's tests
  fence the bytes of generated code per accessor line at 120, over the
  goldens.
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

`batonc` runs as a SwiftPM and Xcode build-tool plugin, over a binary
artifact bundle, with `baton.json` beside the target or the package. Each
source that declares GraphQL, whether a Swift file or a `.graphql` or
`.gql` file, writes one output named by its path in the target.
`Screens/Home.swift` writes `Screens_Home.baton.swift`. The module's types,
slots and sites go to one shared `Baton.baton.swift`, so a `Baton.swift` at
the target's root may not declare GraphQL. A document with an error writes
nothing. This section may rot. The rest must not.
