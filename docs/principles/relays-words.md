# Relay's words

Where Relay or the GraphQL specification has a word, Baton uses it. Baton
invents a word only where neither has one.

That covers the directives, the connection specification, the fetch policies
and the glossary. Baton also drops what is React's, or Meta's, rather than
GraphQL's.

## Why

A team that runs Relay on the web and a different client on native keeps two
mental models of the same schema. Two pagination conventions. Two names for
"refetch this piece". Two error-handling stories. The clients that invented
their own vocabulary (type policies, links, field policies, codegen modes)
taught their users words that mean nothing anywhere else. Relay's words are
the ones a decade of schema design has been shaped around: `Node`,
`@connection`, `@refetchable`, `@required`, `@catch`, `@argumentDefinitions`.

The opposite failure is porting Relay whole. Half of its runtime exists to
solve React's problem of not knowing who read what. Some of its conventions
exist for Meta's module system. Those are not GraphQL's words.

## The idea

Baton consumes the Relay compiler's front end, so Relay's directives are
parsed and validated by the code that defines them. The directive set is
Relay's, with one exception, `@cacheExpiration(seconds:)`, for what neither
Relay nor the specification has a word
([the decision](../decisions/an-operation-states-its-expiration.md)). The
connection handling is Relay's. The fetch policies are Relay's four. The
glossary terms are Relay's: operation, fragment, record, store, environment,
retain, release buffer. Configuration keeps Relay's key names, in
`baton.json`: `schema` today, and `schemaExtensions`, `customScalarTypes`
and `persistConfig` as each is built. `relay.config.json` itself is not
read.

What Baton does not port is named in the vision: snapshots and seen-record
sets, structural recycling, suspension by thrown promises, the
generator-based collector, string-keyed records, Resolvers, client edges,
data-driven dependencies, updatable fragments, multi-actor stores, and
filename-based naming rules.

Two words are Baton's, because the thing they name is new. A *lens*: Relay
has a fragment reference and fragment data, and here they are one value. A
*plan*: the normalization artifact as data.

## Consequences

- A Relay developer reads a Baton fragment without a glossary.
- Server conventions are opt-in capabilities, as they are in Relay's
  compiler. `Node` is for refetch. Connections are for pagination. Neither
  is required to normalize.
- A Baton-specific directive needs the membership test in
  [What earns a concept](what-earns-a-concept.md), and a reason Relay has no
  word for it.
- Terminology entries carry their lineage: where the word comes from, and
  why it was chosen over the alternatives.

## Not this

- Apollo's vocabulary, or a blend of the two.
- Renaming a Relay directive to sound more Swift.
- Porting a Relay mechanism because Relay has it.
- Inventing a word for something Relay already names.

See [Honest data](honest-data.md) for how Relay's error directives are used.

## Spelled today

Understood by the compiler and honored by the runtime:
`@argumentDefinitions`, `@arguments`, `@connection`, `@refetchable`,
`@alias`, `@appendEdge`, `@prependEdge`, `@appendNode`, `@prependNode`,
`@deleteEdge`, `@deleteRecord`, `@include`, `@skip`, `@required`, `@catch`,
`@throwOnFieldError`, `@semanticNonNull` (schema), `@defer`, `@stream`,
`@stream_connection`, `@inline`.
This section may rot. The rest must not.
