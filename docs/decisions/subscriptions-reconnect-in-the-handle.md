# A subscription reconnects in its handle, by a fixed backoff

Status: accepted, 2026-10-11. Answers
[#12](https://github.com/shergin/baton/issues/12)'s reconnection, parking
and gap handling. Serves
[The store is the UI's state](../principles/store-is-the-ui-state.md) and
[What earns a concept](../principles/what-earns-a-concept.md). Reopen the
constants when a server is shown for which they are wrong; reopen the
single-connection mode of `graphql-sse` for a gateway that cannot do HTTP/2.

## Context

A subscription's stream that failed set `error` and `isActive` false, and
nothing reconnected. A socket stayed open in the background until the
system closed it, and the stream died with the socket. The issue asked for
reconnection with a configurable backoff, a lifecycle observer, sharing of
equal subscriptions and a callback for a gap. Sharing already existed; the
owner's review proposed the rest as values on the handle and one input on
the environment.

## Decision

- **Reconnection is the handle's**, so every transport gets it. A stream
  that ends by a failure while the handle is retained and the environment
  active is a wait, not an end: the handle opens it again after a backoff.
  The server's completion ends the stream, and so does a request error, the
  server's refusal of the operation as written, which a retry would only
  repeat every half minute for as long as the handle lived; `retry()` opens
  an ended or waiting stream again at once. A stream that fails while the
  environment is inactive, or a handle retained while it is, parks rather
  than waits, so activity opens it.
- **The backoff is fixed and documented**: a step doubling from one second
  to a cap of thirty, jittered to between half and the whole of the step,
  reset by an event. No policy object: five numbers on the environment are a
  settings bag, and no server has shown the constants wrong.
- **The stream's states are values**: idle, connecting, open, waiting to
  reconnect until an instant, ended. A count of resumptions on the handle,
  raised each time the stream is opened again after a wait or a parking,
  is the gap's signal: an owner observes it and refetches its baseline. No
  callback: an observable value already is the hook.
- **Parking is one input**, `Environment.isActive`, set by the app from its
  scene phase and by hand in tests. False closes every retained
  subscription's stream and keeps the retention; true opens them again.
  Queries read nothing of it.
- **The transport's element stays a payload.** The handle knows a
  resumption because it made it, so the stream's element need not say
  "connected".

## Evidence

- The runtime as built before this change: a failed stream stayed ended
  (`Operation.swift`, the handle's `start`), and nothing observed the app's
  lifecycle.
- The owner's review of #12 (2026-10-04): sharing exists; reconnect in the
  handle with fixed constants; state and gaps as values; one input for
  parking; `graphql-sse` in its distinct-connections mode first.

## Not chosen

- `Environment.subscriptionPolicy` with five numbers: a settings bag for
  constants no server has contradicted.
- An `onResume` callback: a second channel beside the observable count.
- A transport element that says "connected": the handle makes every
  reconnection itself and needs no word from the stream.
- Reconnecting an unretained handle, or past the environment's end: there
  is no view to serve.
