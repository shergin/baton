# Relay's front end, pinned, behind our driver

Status: accepted, 2026-10-02. Serves
[The compiler decides](../principles/compiler-decides.md) and
[Relay's words](../principles/relays-words.md). Reopen when the pinned
revision cannot be advanced for a feature we need, or stops building on
stable Rust; the remedies, in order, are vendoring the crates and writing our
own front end behind the same plan IR. Apollo's compiler is not a remedy.

## Context

The compiler needs a GraphQL parser, a schema, a typed IR, spec validation
and Relay's transforms (fragment arguments, connections, refetchable queries,
identity fields, flattening). Relay's compiler is a Rust workspace, MIT, not
published to a registry, versioned 0.0.0, with its output languages and
source extraction closed to extension.

## Decision

Depend on Relay v21.0.1's `graphql-syntax`, `schema`, `relay-schema`,
`graphql-ir`, `relay-config`, `relay-transforms`, `graphql-text-printer`,
`common` and `intern` as git dependencies pinned to the tag. Everything in
front of them (finding GraphQL in Swift and Kotlin sources) and behind them
(the plan IR, the emitters, the artifact format) is ours. No fork.

## Evidence

- Spike S1 (2026-10-02): the pipeline builds on stable Rust; the stripped
  binary is 4.3 MB; 500 fragments compile in 8 ms warm; Relay's own error for
  a misspelled field lands on the exact character inside a Swift literal.
- Relay.swift depended on the JavaScript compiler's plugin API and was
  stranded when Relay 13 removed it; rescript-relay forks the Rust compiler
  and was 675 commits behind upstream in October 2026.
- Baton runs its own runtime, so a pinned front end cannot fall out of step
  with anything; upgrades are elective.
- The owner's web products run Relay; one directive vocabulary and one
  compiler lineage keep web and native in one language.

## Not chosen

- `apollo-compiler` plus our own transforms: published and versioned, but a
  second vocabulary and a second lineage.
- A fork: upstream tracking for no benefit, since the runtime is ours.
- An own front end from the start: months of validation work before the
  first lens, measured by Isograph's two and a half years to parity.
