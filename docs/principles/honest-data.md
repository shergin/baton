# Honest data

Nullability is what the schema says, and missing data is reported and
healed, never invented silently.

Field errors survive caching and are visible where they occurred. Staleness
is a phase a view can read, not a surprise it cannot.

## Why

GraphQL clients lie in small ways that compound. Every field is typed
nullable because any field can fail, so product code handles permutations
that never happen. A field error is hidden behind a `null`, and the view
shows an empty label. Data a related write made disappear is returned as
`undefined`, and the first `.length` crashes. A cached value is served as
if it were fresh, and a product team routes around the cache with
mutations. Relay spent its 18th release fixing the first two, with
`@catch`, `@throwOnFieldError` and semantic nullability. Netflix wrote
about the last.

The opposite failure is a client that crashes on any imperfection:
SwiftData's invalidated-model trap is the precedent nobody wants.

## The idea

Types follow the schema: a non-null field is a non-optional property, and a
nullable one is optional. `@required` moves the null up to where the product
wants it, and `@catch` turns a failure into a `Result`. A schema that
declares semantic non-null gets non-optional types where a handling policy
is in place, and a server that advertises `onError` behaviour is asked for
it.

Errors are data: the normalizer stores a field's error beside the field, so
a cached read sees the same error the network read saw. Staleness is data
too: a handle's phase says whether the content is current, refreshing or
failed, and the previous content stays visible while a refresh runs.

Missing data is the one case the types cannot express. It arises only when a
link is retargeted by another operation to a record fetched with fewer
fields, and then a lens returns the type's zero value for that read. The
store records the event, marks the owning operation stale and refetches it.
A debug build raises a runtime issue naming the fragment, the record and
the field. A view shows a blank for a moment and then the truth. You see
exactly where, and why.

## Consequences

- Reading a non-null field never crashes and never returns a made-up value
  silently: you get the value, or a zero value with a recorded event and a
  refetch under way.
- Field errors are part of the fixtures, so a cached read must surface the
  same error as a fresh one.
- `isRefreshing` and `failed(error)` are ordinary states of a handle, and a
  view decides what to show.
- Debug builds are loud about missing data, while release builds are quiet
  and self-healing.
- The directives that express this are Relay's, so a web team's habits
  transfer.

## Not this

- Typing every field optional "to be safe."
- Swallowing a field error into `null` with no record of it.
- Trapping when data is missing.
- Returning a cached value with no way to tell it is stale.
- Inventing default values that look like data.

See [The response is the oracle](response-is-the-oracle.md) for where truth
comes from, and [Relay's words](relays-words.md) for the directive
vocabulary.

## Spelled today

As of 0.6.0, `phase` on an operation value is `.loading`, `.ready(data)` or
`.failed(error)`, with `isRefreshing` and `isStale`. Those keep their
meaning across a launch, because the image stores when each operation
fetched. Since 0.7.0, `fetch` sits beside `phase` and is the last fetch as
a value: idle, in flight, or failed, with a `Failure` of one of four kinds
and the time it failed. A fetch that fails behind data is seen without the
data going. Field errors are stored beside the field, in memory and in the
image, and read through `@catch(to:)` as a `Result`. `@required(action:)`
bubbles at the lens boundary, logs a `requiredFieldMissing` event, or throws
from the accessor. `@throwOnFieldError` fails the operation or throws at
the spread, with `@semanticNonNull` types under it. `onError` in
`baton.json` is sent with every operation the target compiles. The
environment's `log` has a `missing` event for missing data, and an
`unexpected` one for a null in a field typed non-null or a value of another
kind. Zero values come from the `required*` readers, and one placeholder
record per type sits behind a non-null link without data. A server's
response that omits a field the operation selected fails the fetch as
malformed, so missing data arises only when a link is retargeted. An
optimistic response and `commitPayload` may carry part of a selection. The
heal is that a read which finds data missing marks the owning operation
stale and refetches it, once per fetch, if a holder allows the network.
This section may rot. The rest must not.
