# A payload is bytes in a response's shape

Status: accepted, 2026-10-07. Serves
[The response is the oracle](../principles/response-is-the-oracle.md) and
[Relay's words](../principles/relays-words.md). Not built yet. Reopen if a
caller of the door needs to hand it something that is not in a response's
shape.

## Context

`Environment.mutate(_:optimistic:)` takes a `Variable?`, renders it to JSON
text as `"{\"data\":" + optimistic.json + "}"` and parses that text again
through `Ingest.normalize`, on the main actor. A custom scalar's token does
not survive the trip: `Variable` is a JSON value enum, its cases are null,
bool, int, double, string, list and object, and `.double` renders through
`String(double)`, so a scalar's text as written is not what reaches the
store.

`Variable` names three things. It is an operation's variable. It is an
optimistic response: the generated `OptimisticResponse` builders render to
`Baton.Variable` through `var variable`. It is a socket's connection
payload: `connectionParams: Variable?` on the WebSocket transport.
`commitPayload` already takes `Data`. The thing a response is has no word in
the vocabulary.

## Decision

- **Payload**, Relay's word from `commitPayload`: bytes in a response's
  shape, the one thing the door takes.
- The generated builders render a payload directly, keeping a scalar's text
  as written.
- `mutate(_:optimistic:)` and `commitPayload` take a payload.
- `Variable` is a variable's JSON value and nothing else.
- Done when a custom scalar in an optimistic response reads as its text and
  a fixture says so.

## Evidence

- The runtime as built, by reading: `mutate(_:optimistic:)` in
  `Environment.swift` builds the JSON text from `optimistic.json` and calls
  `Ingest.normalize` on it; `Variable` in `Value.swift` and its `json`
  rendering; `connectionParams` in `Transport.swift`; `commitPayload(_:_:)`
  taking `Data`.
- The generated code, by reading:
  `compiler/src/tests/goldens/WriteDocuments.baton.swift`, where
  `OptimisticResponse` and its nested builders each expose
  `public var variable: Baton.Variable`.
- Nothing is measured: the change removes a render and a parse from a path,
  and adds none.

## Not chosen

- A typed tree the ingest walks: a second ingest beside the one that reads
  bytes.
- Keeping `Variable` for the optimistic response, with a note: two meanings
  of one public type.
- A string: bytes are what the door takes and what a transport yields.
