# The response is the oracle

Whatever path a value takes, reading it through a lens equals reading the raw
response at the same path. Anything faster than the naive reading has to
reproduce it exactly, and a fixture proves that it does.

## Why

A normalized store is a long chain of clever steps: a one-pass tokenizer
driven by a plan, interned storage keys, shared records written by many
operations, optimistic overlays rebased on every commit, a persisted image
read back on the next launch. Each step is a place to lose a value, merge two
records that are not the same thing, or show one operation's data through
another's selection. The clients that broke in production broke here:
identity without stable keys, cache misses after a key-generator change,
stale data served as fresh.

The opposite failure is to trust the chain because each step was tested in
isolation. The bugs are between steps.

## The idea

For data this client fetched, the truth is the response as it arrived. A
naive reference reader exists only to be the oracle: it walks the raw JSON by
the same path a lens would and returns the value found there. Every fixture
pairs recorded responses with the lens reads and the store dump they must
produce, and every runtime passes the same fixtures. A new optimization is
admitted when the fixtures still pass and a bench shows the gain.

## Consequences

- `spec/` holds schema, documents, recorded responses, expected store
  contents and expected reads in a language-neutral form. The Swift runtime
  passes them; the Kotlin runtime will pass the same files.
- Optimistic data is still data: the oracle for an optimistic read is the
  optimistic response at that path, until the server's response replaces it.
- Persisted data is still data: a value read back from disk equals the value
  written, or the entry is a miss.
- Identity is part of the oracle: two records are the same record when their
  typename and key fields match, by configuration the compiler checked.
- A refactor of the store, the tokenizer or the record layout is
  behavior-frozen: the fixtures do not change.

## Not this

- Unit tests of the tokenizer, the normalizer and the reader in isolation as
  the only proof.
- Comparing optimized output against last week's optimized output.
- A performance claim without the fixture that shows the result is unchanged.
- Generated test data that no server ever produced.

See [Honest data](honest-data.md) for what happens when the oracle has no
value to give.

## Spelled today

Nothing is spelled yet. Planned: `spec/` with fixtures, a `ReferenceReader`
in the test target only, and conformance tests that every runtime runs.
This section may rot; the rest must not.
