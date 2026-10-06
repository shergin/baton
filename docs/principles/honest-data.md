# Honest data

Nullability is what the schema says. Missing data is reported and healed,
never invented silently. Field errors survive caching and are visible where
they occurred. Staleness is a phase a view can read, not a surprise it
cannot.

## Why

GraphQL clients lie in small ways that compound. They type every field
nullable because any field can fail, so product code handles permutations
that never happen. They hide a field error behind a `null` and the view shows
an empty label. They return `undefined` for data a related write made
disappear, and the first `.length` crashes. They serve a cached value as if
it were fresh, and a product team routes around the cache with mutations.
Relay spent its 18th release fixing the first two with `@catch`,
`@throwOnFieldError` and semantic nullability; Netflix wrote about the last.

The opposite failure is a client that crashes on any imperfection: SwiftData's
invalidated-model trap is the precedent nobody wants.

## The idea

Types follow the schema. A non-null field is a non-optional property; a
nullable one is optional; `@required` moves the null up to where the product
wants it; `@catch` turns a failure into a `Result`; a schema that declares
semantic non-null gets non-optional types where a handling policy is in
place; a server that advertises `onError` behaviour is asked for it.

Errors are data: the normalizer stores a field's error beside the field, so a
cached read sees the same error the network read saw. Staleness is data: a
handle's phase says whether the content is current, refreshing or failed, and
the previous content stays visible while a refresh runs.

Missing data is the one case the types cannot express. It arises only when a
link is retargeted by another operation to a record fetched with fewer
fields. Then a lens returns the type's zero value for that read, the store
records the event, marks the owning operation stale and refetches it, and a
debug build raises a runtime issue naming the fragment, the record and the
field. A view shows a blank for a moment and then the truth; a developer sees
exactly where and why.

## Consequences

- Reading a non-null field never crashes and never returns a made-up value
  silently: either the value, or a zero value with a recorded event and a
  refetch under way.
- Field errors are part of the fixtures; a cached read must surface the same
  error as a fresh one.
- `isRefreshing` and `failed(error)` are ordinary states of a handle; a view
  decides what to show.
- Debug builds are loud about missing data; release builds are quiet and
  self-healing.
- The directives that express this are Relay's, so a web team's habits
  transfer.

## Not this

- Typing every field optional "to be safe."
- Swallowing a field error into `null` with no record of it.
- Trapping when data is missing.
- Returning a cached value with no way to tell it is stale.
- Inventing default values that look like data.

See [The response is the oracle](response-is-the-oracle.md) for where truth
comes from and [Relay's words](relays-words.md) for the directive vocabulary.

## Spelled today

As of 0.6.0: `phase` on an operation value (`.loading`, `.ready(data)`,
`.failed(error)`) with `isRefreshing` and `isStale`, which keep their meaning
across a launch because the image stores when each operation fetched; field
errors stored beside the field, in memory and in the image, and read through
`@catch(to:)` as a `Result`;
`@required(action:)` bubbling at the lens boundary, logging through
`Environment.requiredFieldMissing`, or throwing from the accessor;
`@throwOnFieldError` failing the operation or throwing at the spread, with
`@semanticNonNull` types under it; `onError` in `baton.json`, sent with every
operation the target compiles;
`Store.reportMissing` for missing data and `Store.reportUnexpected` for a
null in a field typed non-null or a value of another kind, with zero values
from the `required*` readers and one placeholder record per type behind a
non-null link without data. Still planned: the heal's refetch of the owning operation. This
section may rot; the rest must not.
