# A raw response is asked for with `@raw_response_type`

Status: accepted, 2026-11-23. Serves
[Relay's words](../principles/relays-words.md) and
[The response is the oracle](../principles/response-is-the-oracle.md);
builds on [a payload is bytes in a response's shape](a-payload-is-bytes-in-a-responses-shape.md).
Reopen if an adapter must write nulls often enough that hand-written JSON
is the common case, or if generated code size shows a builder per
operation would be free.

## Context

A payload committed by hand, or yielded by a transport of the app's own,
was JSON written by hand, except a mutation's, which has the generated
`OptimisticResponse` builder. The testing recipe said so: "There is no
third builder". `@raw_response_type` was a compile error, as any
directive Baton gave no meaning to is.

An adapter that turns another protocol's messages into an operation's
response, as [a backend that is not GraphQL](../recipes/another-backend.md)
does, is coupled to the operation's shape. Written as JSON by hand, it
drifts when the selection changes, and nothing says so until a read comes
back missing.

## Decision

- Relay's `@raw_response_type` on a query or a subscription nests
  `RawResponse` in the operation's value. It is the builder a mutation's
  `OptimisticResponse` is: one type per selection set, every field an
  optional parameter, an absent field left out of the payload, and
  `payload` rendering the bytes the door takes.
- `commitPayload(operation, response.payload)` commits it. A transport of
  the app's own yields `response.payload.bytes`, in either runtime.
- On a mutation the directive is accepted and adds nothing: its
  `OptimisticResponse` is that builder already, named for its use.
- It is opt-in per operation, because a builder per operation is code
  most operations never use.
- No runtime type and no format number changed. The name `RawResponse`
  joins the names an operation's value nests, so the compiler keeps it
  from a schema enum or input object, and in Kotlin from a fragment or an
  operation, as it keeps `OptimisticResponse`.

The limit, stated plainly: the builder writes values and cannot write a
null. An optional parameter left nil is absent, not null, exactly as in
`OptimisticResponse`. A response that must null a field is a payload
written as JSON. This is watched, not solved.

## Evidence

- The compiler as built: the directive is read in the lowering, the
  decide pass gives a query or a subscription that carries it the same
  builder plan a mutation's optimistic response has, and both emitters
  write it with the optimistic builder's code, its doc comment naming
  what it is for.
- Relay's directive generates a type of the raw response, for the places
  a response is written by hand, an optimistic response and a payload
  committed by hand among them; Baton's builder renders
  a `Payload` rather than a typed object a second ingest would walk
  ([the payload decision](a-payload-is-bytes-in-a-responses-shape.md)).
- The runtime's feed tests, in both languages: a raw response yielded by
  a transport of the app's own reaches a subscription's handle, and one
  committed through the door writes what it gives and leaves the record's
  other fields as they were; a mutation carrying the directive generates
  what it generates without it.

## Not chosen

- A builder for every operation: code most operations never use, in
  every target.
- Renaming `OptimisticResponse` to `RawResponse`. Relay names the type
  "raw response" and the parameter "optimistic response"; Baton named the
  type for the parameter, and a rename breaks adopters for a word.
- Three-state fields, absent, null or a value: a double optional in
  Swift and a wrapper type in Kotlin, and a change of meaning for
  optimistic responses already written.
- A typed overload of `commitPayload`: a second spelling of the one door,
  for what `response.payload` already says.
