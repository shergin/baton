# What earns a concept

A concept sits in the vocabulary only when real screens demand it and no
composition of the existing concepts expresses it. Both clauses. Everything
else is a directive the compiler already understands, a value on a handle, or
an example.

## Why

GraphQL clients die of configuration. Each real complaint becomes an option:
a cache policy here, a type policy there, a merge function, a link in a chain,
a flag on codegen. Ten years later the client has four codegen modes, a
dozen cache policies and a documentation site explaining which combinations
work. The complaints were real; the answers multiplied the surface instead of
fixing the mechanism.

The opposite failure is a client so pure it cannot do the job. Pagination,
optimistic updates and error handling are real; a store that refuses them is
a demo.

## The idea

The concept inventory is closed and short: schema, document, directive, lens,
record, store, plan, operation value, connection, environment, transport,
phase. A feature must be a composition of these, or a Relay directive the
compiler compiles into a plan. A new concept must pay for itself across many
features, and it enters through this test:

- Real screens demand it. Screens people build, not screens a completeness
  argument names.
- No composition of the existing concepts expresses it.

When the test passes, the concept gets a name in the terminology before it
gets a type in code, and a principle file if it constrains the others.

## Consequences

- Subtraction is a contribution. A concept that stops paying for itself is
  removed before 1.0.
- Requests that fail the test become examples: here is how to do that with
  what exists.
- Page-based pagination, imperative store updaters, a binary wire format and
  offline sync are on a watch list with triggers, not in the plan.
- The terminology is the gate: nothing ships that is not named there.

## Not this

- A codegen option to fix an ergonomic complaint.
- A per-type or per-field policy object.
- Two ways to do the same thing because the second is more convenient.
- A feature "for completeness."

See [Relay's words](relays-words.md) for where the names come from.

## Spelled today

Nothing is spelled yet. The inventory and the watch list are in the project's
planning notes until the first release; the terminology carries *(planned)*
markers until then. This section may rot; the rest must not.
