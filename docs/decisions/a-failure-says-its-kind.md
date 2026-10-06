# A failure says its kind

Status: accepted, 2026-10-05. Serves
[Honest data](../principles/honest-data.md),
[Relay's words](../principles/relays-words.md) and
[What earns a concept](../principles/what-earns-a-concept.md). Reopen if an
app shows a failure that fits none of the four kinds, or if a server's
convention needs a kind the transport's case cannot carry.

## Context

The phase fails with `any Error` (`Operation.swift:72-76`), so a view that
branches on a failure matches on types. What it can meet: `TransportError`
or the system's `URLError` from the built-in transports
(`Transport.swift:63-83`), or whatever an app's own transport throws;
`GraphQLErrors` for a response of errors and no data
(`Errors.swift:76-83`), and `IngestError` for one the plan cannot read
(`Ingest.swift:210-214`); `EnvironmentError` when nothing can send the
request (`Errors.swift:54-74`); `MissingDataError` for a `storeOnly` attach
whose data the store lacks (`Operation.swift:78-82`); and `FieldErrors`
and `RequiredFieldError` from the operation's directives
(`Errors.swift:21-52`). The runtime itself casts at eight places, to tell a
failure with data behind it from the rest
([A handle keeps its fetch and derives its phase](a-handle-derives-its-phase.md)).

`TransportError(statusCode:body:)` is a status and a text. Status 0 means
there was no response, as the web's `XMLHttpRequest` reports it: a socket
that closed, a recorded transport with nothing recorded. The text then says
what went wrong (`Transport.swift:63-83`).

A field error is a message and a dotted path (`Errors.swift:3-19`). The
ingest reads `message` and `path` from each error and skips every other
member (`Ingest.swift:951-967`). So an error's `extensions`, where the
specification's own example puts an error code, are dropped: on a field
error, and on the errors of a response that carried no data, which
`GraphQLErrors` keeps as messages alone.

The GraphQL specification names two kinds of error. A request error is
"raised before execution begins", and the response then has no data. A
field error is raised while a field executes, and the response has partial
data. Either can carry `extensions`, a map the specification leaves to the
service.

[#19](https://github.com/shergin/baton/issues/19) asks for a closed set of
failure kinds that an owner can branch on without matching strings, the
same kinds the events of [#15](https://github.com/shergin/baton/issues/15)
would classify by. The answer on #19 agreed that a closed type would fix
`Phase.failed(any Error)`, warned that a second enum beside
`TransportError` and `URLError` is a parallel vocabulary that can drift,
and left the taxonomy open. [#5](https://github.com/shergin/baton/issues/5)
needs a fetch's failure a view can read, and
[#12](https://github.com/shergin/baton/issues/12) needs a stream to say
how it ended.

## Decision

A failure says where it came from, in one of a closed set of kinds. All of
it is *(planned)*.

- A failure of a fetch is one of four kinds:
  - the transport's, carrying what the transport threw, unchanged: an HTTP
    status outside 2xx with its body, a connection error, an app's own
    transport's error;
  - a request error, the specification's word: a response of errors and no
    data, carrying the server's errors;
  - a malformed response, one the plan cannot read, which `IngestError`
    reports today;
  - the environment's, which `EnvironmentError` says today: no environment
    injected, a lens read outside one, the environment gone, no
    subscription transport.
- One type serves the fetch, the stream and the report. A fetch's failure,
  how a subscription's stream ended, and the events #15 asks for, which are
  proposed apart, classify by the same kinds.
- The set of kinds is closed, and the transport's case is its open end.
  What a transport throws stays what it is: `TransportError`, `URLError`
  and an app's own error are carried inside that case, not described again,
  so there is no second vocabulary to drift from the first.
- An error the server sent keeps its `extensions` beside its message and
  its path, as a JSON value, of the type the runtime already uses for
  JSON-shaped values, `Variable` (`Value.swift:38-94`). An app branches on
  the server's code and never on its message. On a field error the value is
  stored beside the field with the message and the path, and reaches the
  image with them. A request error's errors keep theirs too: they are the
  same objects in the response.
- A verdict's failure is not a fetch's. Field errors under
  `@throwOnFieldError`, a root whose `@required` field bubbled, and data a
  `storeOnly` attach does not have are facts about the data, with data in
  the store or none to fetch. They come from the phase's verdict
  ([A handle keeps its fetch and derives its phase](a-handle-derives-its-phase.md)),
  not from the fetch.

Left open, to settle when it is built, with the handle and the transport's
work: what `Phase.failed` carries, one type with the verdict's cases added
or the fetch's kinds alone; whether `refetch()`, `Environment.fetch` and
`mutate` throw it as a typed error, where
[Relay's error directives in Swift's terms](error-directives-in-swift.md)
names typed throws in its reopening line, for accessors; the Swift spelling
of the type and its cases; where a request error's errors are read from,
the handle or the report; and whether a response whose `data` is null
beside its errors, which the specification counts among field errors and
the ingest reads as no data today (`Ingest.swift:513-533`), is a request
error here or a verdict of the data.

## Evidence

- The runtime as built, by reading: what Context says. The ingest reads an
  error's members only inside an `errors` array, of a response, of a
  deferred part, or of a subscription's `error` frame
  (`Ingest.swift:951-967` and its callers).
- The GraphQL specification, October 2021, section 7.1.2,
  [Errors](https://spec.graphql.org/October2021/#sec-Errors), read
  2026-10-05: a request error comes before execution, and a response that
  has one has no `data` entry; a field error comes from a field during
  execution, and the result is partial; any error may carry `extensions`,
  a map reserved for the service's own additions with no restriction on
  what it holds, and the section's example puts a `code` there.
- The issues, read 2026-10-05: #19 asks for kinds an owner branches on
  without matching strings, one enum with the kinds of #15; #15 asks for
  events that carry a classified kind of failure and never a payload.
- The planning notes' strategy promised typed network and protocol errors
  from the start, and the plan that stored field errors left `extensions`
  as an open item.
- Nothing is measured, and nothing needs to be: a failure is a rare path,
  and `extensions` are read only when an error is present.

## Not chosen

- `Phase.failed(any Error)` and matching on types, as built: every render
  site matches on types, and the runtime itself casts at eight places.
- One enum that describes the transport's failures again, in cases of its
  own (a status, a timeout, a connection error): the parallel vocabulary
  that can drift. The transport's case carries the transport's own error
  instead.
- `TransportError` alone as the taxonomy, which a review of the same code
  proposed. It cannot say a request error, a malformed response or a
  missing environment, and an app's own transport does not throw it.
- A string code on the error: the matching of strings the issue complains
  of.
- Dropping `extensions`, as built: the server's code is the one thing in an
  error an app can branch on.
- A verdict's failure typed as a kind of the fetch's: field errors, a
  bubbled `@required` field and data a `storeOnly` attach lacks are facts
  about the data.
