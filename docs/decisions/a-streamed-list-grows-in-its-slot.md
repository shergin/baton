# A streamed list grows in its slot

Status: accepted, 2026-10-13. Serves
[Relay's words](../principles/relays-words.md) and
[The response is the oracle](../principles/response-is-the-oracle.md).
Reopen if a real screen needs to ask a list whether more of it is to come
and the handle's fetch cannot say it, or if a server in use streams a list
of scalars.

## Context

`@stream` is the other half of incremental delivery: `@defer` fills a hole
once, `@stream` grows a list item by item after its first `initialCount`.
Relay's front end validates it, Relay's connection transform rewrites
`@stream_connection` into `edges @stream` with the page info under
`@defer`, and Baton's transport, part parser and delivery already read
every incremental shape for `@defer`. Until now the directive was a compile
error, watched behind the trigger "a server in use that emits it"; the
owner asked for it on 2026-10-13, and GraphQL Yoga, graphql-js 17 and Hot
Chocolate emit it.

What is new is one primitive: a list slot that grows across parts. The
questions were where an item lands, what keys it, what says the list is
complete, what happens when something else writes the list meanwhile, and
how a streamed connection learns of its new edges.

## Decision

- A streamed item is placed in the list the first part wrote, at the index
  its path names (Relay's shape and the June 2023 shape) or after the last
  item (the 2024 shape, whose items arrive in order); a list is extended
  with nulls to reach an index, so items that arrive out of order read in
  their order once each is there, and a null element reads as absent, as
  a list's null does.
- An item is keyed as it would be had it not been streamed: by its id when
  the type is keyed, else by the parent record, the field's storage key
  and its index, which is what Relay generates too. The plan marks the
  field with the stream's label, as it marks a deferred field; nothing
  else in the plan changes, and the lens reads the list through the
  accessor it has without the directive.
- Nothing is generated to say whether more items are to come. Relay's
  reader has no such thing either. The handle's fetch is in flight while
  the stream runs, so `isRefreshing` says it, and a streamed connection's
  page info arrives deferred, so its `isPresent` says the edges are whole.
- The root is dated when the stream completes, as a deferred response's
  is. Under an undated root a streamed list is not held, so a
  `storeOrNetwork` attach fetches: the counterpart of the half-held
  deferred part, decided without a mark on the list, since the date is
  already the fact.
- An item that lands in a list another commit changed since the stream
  left it is dropped and logged, as Relay's executor drops it and as a page
  fetched after a cursor that moved is ignored. The delivery keeps, per
  streamed list, the list as it left it, and compares by identity before
  each commit.
- A part that lands on a connection's page, a streamed edge or the deferred
  page info, merges the page into its connection again, by the mode the
  page was fetched with. Relay runs its connection handler again for the
  same reason.
- `@stream` on a list of scalars is refused, as Relay refuses it; a list
  field of objects is the one place it goes. `@stream` in a mutation or a
  subscription is a compile error, as `@defer` is.
- The compiler speaks `@stream`'s arguments as the schema spells them: the
  specification's `initialCount` and `useCustomizedBatch` by default,
  Relay's `initial_count` and `use_customized_batch` when the schema
  declares those, so a schema of either lineage compiles.
  `@stream_connection` is Relay's own directive and keeps Relay's
  `initial_count`.
- The operation's flag is `hasIncremental`, the specification's word for a
  response in parts, in place of `hasDeferred`, which named one of two.

## Evidence

- `spec/tests/character-streamed*`: the three shapes, out-of-order
  arrival, a stray item, a failed stream and a streamed connection, each a
  server response the dumps are frozen under; the script `streams` for the
  handle over time, the cut stream and the list another commit changed.
- Relay v21.0.1's `OperationExecutor._processStreamResponse`: the item at
  the path's index, the client id from the parent, the field and the
  index, the stale item dropped when the list changed, the handle run
  again; `RelayModernEnvironment-ExecuteWithStream-test.js`, "processes
  streamed payloads that arrive out of order".
- `BENCHMARKS.md`, 2026-10-13: a streamed item placed into a list of a
  thousand, and a page of a thousand edges merged again.

## Not chosen

- A generated accessor saying whether the list is complete: Relay has
  none, the handle's fetch already says it, and a connection's page info
  says it for the one list whose end a screen asks about.
- Placing an item into whatever list the slot holds: a mutation that
  replaced the list meanwhile would have its items overwritten by a stale
  order.
- Holding the items back until the stream completes: the point of the
  directive is the first frame.
- A kind of plan field for a streamed list: a label on the linked field is
  the whole fact, as it is for a deferred field.
