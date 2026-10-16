# The response is the oracle

Whatever path a value takes, reading it through a lens equals reading the
raw response at the same path.

Anything faster than the naive reading has to reproduce that exactly. A
fixture proves that it does.

## Why

A normalized store is a long chain of clever steps. A one-pass tokenizer,
driven by a plan. Interned storage keys. Shared records, written by many
operations. Optimistic overlays, rebased on every commit. A persisted image,
read back on the next launch. Each step is a place to lose a value, to merge
two records that are not the same thing, or to show one operation's data
through another's selection. The clients that broke in production broke
here. Identity without stable keys. Cache misses after a key-generator
change. Stale data served as fresh.

The opposite failure is to trust the chain because each step was tested in
isolation. The bugs are between steps.

## The idea

For data this client fetched, the truth is the response as it arrived. A
naive reference reader exists only to be the oracle. It walks the raw JSON
by the same path a lens would, and returns the value found there. Every
fixture pairs recorded responses with the lens reads and the store dump they
must produce. Every runtime passes the same fixtures. A new optimization is
admitted when the fixtures still pass and a bench shows the gain.

## Consequences

- `spec/` holds schema, documents, recorded responses, expected store
  contents and expected reads in a language-neutral form. The Swift runtime
  passes them. The Kotlin runtime will pass the same files.
- Optimistic data is still data. The oracle for an optimistic read is the
  optimistic response at that path, until the server's response replaces it.
- Persisted data is still data. A value read back from disk equals the value
  written, or the entry is a miss.
- Identity is part of the oracle. Two records are the same record when their
  typename and key fields match, by configuration the compiler checked.
- A refactor of the store, the tokenizer or the record layout is
  behavior-frozen. The fixtures do not change.

## Not this

- Unit tests of the tokenizer, the normalizer and the reader in isolation as
  the only proof.
- Comparing optimized output against last week's optimized output.
- A performance claim without the fixture that shows the result is unchanged.
- Generated test data that no server ever produced.

See [Honest data](honest-data.md) for what happens when the oracle has no
value to give.

## Spelled today

`spec/` holds the schemas, the documents, the recorded responses, the store
dumps and the expected reads. The Swift tests and benchmarks read them in
place through `BatonSpec`. `spec/manifest.json` lists the cases, and
`spec/README.md` is its contract. The expected reads go through the lens the
compiler generated for the document, so they do not share the plan the store
walks by. Beside them, the reference reader `Oracle` in the test target
walks a response's JSON, as `JSONSerialization` reads it, and the store's
records by the same resolved plan. `OracleTests` requires every case of
the manifest to read as its rows say. The two walks must yield the same
leaves for every response in `spec/` that has data and a document that
reads it. They must do that after the commit. For responses under the
query root, they must do it from the image in a second store. They must
do it under an optimistic layer that overrides one leaf, and again after
that layer is reverted. A deferred response is checked as its first
part, with the later parts merged in at their paths.
`tokenizer/custom-tokens.json` is read through the lens instead, because
the layer's JSON round trip would rewrite the tokens it keeps as text.
Beside each response the oracle reads, `<response>.store.json` is the
store the commit must produce. Every record is there, by key. Links
are written as Relay writes them (`{"__ref": key}`), in sorted order, one
record a line. Identity and record layout change only with a reviewed change
to those files (`BATON_BLESS=1 swift test` rewrites them).
`spec/tokenizer/malformed.json` lists the responses that are not well
formed, each with the outcome it must have. Planned: the same files run by
the Kotlin runtime. This section may rot. The rest must not.
