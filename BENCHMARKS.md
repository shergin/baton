# Benchmarks

Performance here is a measurement, not a speed you can promise on another
machine. Every number comes from `swift run -c release BatonBenchmarks` (or
the comparison package named in its section), recorded with the revision,
machine, OS and date. Append; never edit a past entry.

Figures are those tables drawn again, by [`benchmarks/charts`](benchmarks/charts),
with malevich, the library behind `kaz`. `cargo run --manifest-path
benchmarks/charts/Cargo.toml` rewrites the SVG files. A figure does not
replace the table it sits under.

## Across releases

Best ingest and best commit of the fixture at each release below.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="benchmarks/charts/read-path.svg">
  <source media="(prefers-color-scheme: light)" srcset="benchmarks/charts/read-path-light.svg">
  <img alt="Ingest and commit, best, from 0.1.0 through 0.5.0" src="benchmarks/charts/read-path.svg">
</picture>

## 0.5.0 — 2026-10-03

Revision: the 0.5.0 tree. Machine: Apple M1 Pro (MacBook Pro), macOS 26.5.2,
Xcode 26.6, Swift 6.3.3, release build. Same fixture as 0.1.0; the error
bench adds an `errors` array naming every row's `image` to it.

The earlier numbers, same day as 0.4.0's: ingest 2.76 ms (2.53), commit into
an empty store 1.35 ms (1.34), same payload again 187 µs (184), one field
changed 376 µs (372), untracked read 29 ns (28.5), tracked read 536 ns (552),
check 126 µs (127), the optimistic cycle 413 µs (414), a connection page
320 µs best (281), the scroll footprint +4.7 MB (+4.2 to +5.0). The ingest
moved by a quarter of a millisecond: every field record now carries the
deferred label and the caught flag, and the response's top level is read
through a general member walk instead of two byte compares. The rest is
within the day's noise.

### Errors: the fixture with a field error on every row's image

| Measurement | Best | Median | Notes |
|---|---|---|---|
| Ingest of the fixture with 20 field errors | 3.00 ms | 3.10 ms | 2.76 ms without; the difference is the index of entries the path walk needs, built only when errors exist |
| Commit the errors, then clear them, 20 rows observed (two commits) | 409 µs | 417 µs | each errored slot notifies once when the error lands and once when it clears |
| `@catch` read of a field without an error, per field | 122 ns | 122 ns | a `Result`, a closure and the error lookup, against 29 ns for a plain read |
| `satisfied` check of a lens with one `@required` field, per lens | 29 ns | 29 ns | one tracked read |

What it means: a response without errors pays nothing for the machinery; one
with errors pays a path walk per error; a view that opts into `@catch` pays
a hundred nanoseconds per field it catches, and a `@required` lens costs a
read per required field at the boundary that produces it.

## 0.4.0 — 2026-10-03

Revision: the 0.4.0 tree. Machine: Apple M1 Pro (MacBook Pro), macOS 26.5.2,
Xcode 26.6, Swift 6.3.3, release build. Same fixture as 0.1.0; the connection
bench uses the test schema's `notes` connection on a character, with 42
synthetic pages of 50 notes.

The earlier numbers, same code paths, same day: ingest 2.53 ms (2.16 in
0.3.0), commit into an empty store 1.34 ms (1.44), same payload again 184 µs
(164), one field changed 372 µs (331), untracked read 28.5 ns (26), tracked
read 552 ns (542), availability check 127 µs (104), a layer applied and
reverted 43 µs (41), the full optimistic cycle 414 µs (375). The untracked
read moved on unchanged code, so part of the drift is the day; the rest is
real and small: every field record now carries a handle reference and every
linked field a connection reference, the ingest keeps a second scratch list
per object for the connection links, and the check skips deleted records.
Two larger regressions were found by this bench and fixed before the tag: an
inline `ConnectionSlots` in the resolved field had the ingest copying 250
bytes per matched key and the check at 231 µs; and records pre-sized to their
type's slot count cost the scroll bench 1 KB per record once a paginated field
had registered a key per page on `Character` (+15.8 MB).

### Connections: 42 pages of 50 notes merged into one connection

| Measurement | Best | Median | Notes |
|---|---|---|---|
| `loadNext`: recorded transport, ingest off the main actor, merge, per page of 50 edges and nodes | 281 µs | 734 µs | 41 pages, 2,100 nodes, 41 notifications: one per page, on the connection's `edges` slot |
| `nodes` of the merged connection, 2,100 lenses, untracked | 124 µs | 125 µs | 59 ns per node |
| `nodes` of the merged connection, inside an observation scope | 1.11 ms | 1.48 ms | one registrar access per edge and per node |
| Collection after the 41 pagination fetches (no roots of their own) | — | — | 4,289 records before, 4,207 after: the 41 page records and their page infos go, every edge and node stays |
| Refetch of the first page while 42 are merged | — | — | 50 nodes, one notification |

What it means: a page costs the main actor a merge of two edge lists and one
notification, whatever the number of pages already merged; reading two
thousand nodes untracked is a tenth of a millisecond; and pagination fetches
leave nothing behind but the data, because the connection, not the page, is
what roots reach.

### Lifetime: 42 pages scrolled through a release buffer of 10, again

Same bench as 0.2.0. Records plateau at 8,982 with 10 roots from page 10 on,
as before; the footprint since page 1 plateaus between +4.2 MB and +5.0 MB
across three runs (0.2.0: +6.5 MB), because records now size their values by
the slots they receive rather than by the type's slot count. Collection pass:
best 0.24 ms, median 3.8 ms, worst 4.6 ms.

## 0.3.0 — 2026-10-03

Revision: the 0.3.0 tree. Machine: Apple M1 Pro (MacBook Pro), macOS 26.5.2,
Xcode 26.6, Swift 6.3.3, release build. Same fixture as 0.1.0; the writes use
the test schema's `rename` mutation on top of it.

The read-side numbers hold: ingest 2.16 ms, same payload again 164 µs, one
field changed 331 µs, untracked read 26 ns, tracked read 542 ns, availability
check 104 µs (115 µs in 0.1.0; the check no longer copies plan fields). The
commit into an empty store is 1.44 ms against 1.24 ms: every changed slot now
also lands in an undo log, which is what lets a layer rebase.

### Writes: optimistic layers, one renamed character, 20 rows observed

| Measurement | Best | Median | Notifications |
|---|---|---|---|
| Apply a layer (one field on one record) and revert it | 41 µs | 48 µs | 2: one at the apply, one at the revert |
| Apply, commit the whole fixture under the layer, resolve with the server's answer, restore | 375 µs | 394 µs | apply 1, rebase 0, resolve 0, restore 1 |

What it means: an optimistic response costs microseconds and exactly the
notifications its visible change deserves. A server payload of 899 records
arriving while a layer is live costs the rebase about 200 µs more than a
plain commit (lift the layer, apply, re-apply) and notifies nothing, because
nothing visible changed; the answer that resolves the layer notifies nothing
either, because it agrees with the layer. The row observes a change twice in
the cycle: when the layer appears and when the restore commit changes the
name back.

GitHub's schema (1,558,210 bytes, about 1,800 definitions) builds in Relay's
front end in 33 ms; the GitHub sample's six documents compile in 35 ms.

## 0.2.0 — 2026-10-02

Revision: the 0.2.0 tree. Machine: Apple M1 Pro (MacBook Pro), macOS 26.5.2,
Xcode 26.6, Swift 6.3.3, release build. Same fixture as 0.1.0.

The 0.1.0 measurements are unchanged within noise (ingest 2.08 ms, commit
1.15 ms, same payload 164 µs, untracked read 26 ns, tracked read 524 ns,
check 114 µs).

### Lifetime: 42 pages scrolled through a release buffer of 10

Each page is the fixture with every id shifted, so pages share no records;
each page's handle is retained, settled, released, and a collection runs.

| Page | Records in store | Roots | Footprint since page 1 |
|---|---|---|---|
| 1 | 899 | 1 | +0.0 MB |
| 5 | 4,491 | 5 | +2.5 MB |
| 10 | 8,981 | 10 | +5.8 MB |
| 11 | 8,981 | 10 | +6.4 MB |
| 20 | 8,981 | 10 | +6.5 MB |
| 30 | 8,981 | 10 | +6.5 MB |
| 42 | 8,981 | 10 | +6.5 MB |

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="benchmarks/charts/footprint.svg">
  <source media="(prefers-color-scheme: light)" srcset="benchmarks/charts/footprint-light.svg">
  <img alt="Footprint since page 1, plateauing after page 10" src="benchmarks/charts/footprint.svg">
</picture>

Collection pass over about 9,000 records (mark from 10 roots, sweep about
900): best 0.30 ms, median 3.8 ms, worst 5.0 ms, on the main actor. The
median is dominated by the sweep's dictionary removals and record clearing;
an off-main mark and a budgeted sweep are on the watch list, with this number
as the trigger if it grows past a frame on a phone.

What it means: memory is bounded by the buffer, not by how far the user
scrolls, and nothing a mounted or recently left screen can reach is ever
collected.

## 0.1.0 — 2026-10-02

Revision: the 0.1.0 tree. Machine: Apple M1 Pro (MacBook Pro), macOS 26.5.2,
Xcode 26.6, Swift 6.3.3, release build. Fixture: the recorded response in
`spec/rickandmorty/characters-page-1.json`, 686,254 bytes, about 6,500 JSON
objects that normalize into 899 records (20 characters, 51 episodes, 826
characters referenced from episode casts).

### Baton

| Measurement | Best | Median |
|---|---|---|
| Ingest: response bytes → change set | 2.14 ms | 2.55 ms |
| Commit into an empty store (899 records) | 1.24 ms | 1.32 ms |
| Commit the same payload again (nothing changes, no allocation for strings) | 165 µs | 165 µs |
| Commit with one field changed, 20 rows observed (base commit + edited commit) | 332 µs | 334 µs |
| Untracked lens read, per field | 26 ns | 26 ns |
| Tracked read inside an observation scope, one row body of 8 fields, per field | 553 ns | 568 ns |
| Availability check of the whole fixture plan against the store | 115 µs | 116 µs |

What they mean: a 686 KB response is in the store 3.4 ms after the bytes
arrive, on one background actor plus one main-actor commit; a refetch that
changes nothing costs the main actor 165 µs and no view; a refetch that
changes one field invalidates one row. The tracked-read cost is
Observation's own and matches an `@Observable` property (spike, 2026-10-02:
534 ns against 554 ns).

Generated code for the sample's four screens: 47 field accessors at an
average of 107 bytes of source per accessor line (budget 120); 27.8 KB in
total including operation text, plans and the shared slots file. For the
fixture document alone: 14.5 KB (Baton) against 15.3 KB (Apollo iOS 2.4
codegen for the same document and schema).

### Apollo iOS 2.4.0, same operation, same graph

Measured with `benchmarks/apollo-comparison` (`swift run -c release
ApolloComparison`), same machine and day. The response was recorded for
Apollo's own query text, which adds `__typename` to every object because its
normalizer keys on it: 849,101 bytes against Baton's 686,254 for the same
data. Apollo's schema configuration keys entities by `id`, as Baton does; both
produce 899 records. Apollo's parse includes `JSONSerialization`, as its own
interceptor does, and builds the typed models and the cache records in one
pass with `includeCacheRecords: true`.

| Step | Baton | Apollo iOS 2.4 | Ratio |
|---|---|---|---|
| Response bytes → normalized change set / records | 2.14 ms | 317 ms (`JSONResponseParser`, models + records) | 148× |
| Commit / publish into an empty store | 1.24 ms | 1.39 ms (`InMemoryNormalizedCache`) | 1.1× |
| Bytes → data in the store, total | 3.4 ms | 318 ms | 94× |
| Same payload again, nothing changes | 165 µs | 3.99 ms (`publish`) | 24× |
| From the store to readable data | 0 (lenses read slots) + 115 µs availability check | 228 ms (`store.load`, whole query re-executed into models) | — |
| One field read, per field | 26 ns (lens, untracked) | 296 ns (`DataDict` access, after `load`) | 11× |
| `JSONSerialization` alone, for scale | 4.47 ms (686 KB) | 5.73 ms (849 KB) | — |

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="benchmarks/charts/apollo.svg">
  <source media="(prefers-color-scheme: light)" srcset="benchmarks/charts/apollo-light.svg">
  <img alt="Baton and Apollo iOS 2.4, seconds, log axis" src="benchmarks/charts/apollo.svg">
</picture>

The figure is that table, in seconds, on a log axis. Baton's store-to-data
mark is the availability check; the one-field mark is the untracked lens
read.

The ratios are not the point; the shape is. Apollo pays for materialization
twice, once building models and records from the tree and once rebuilding
models from the cache, and neither pass is cheaper than a frame; Baton
materializes nothing a view did not read. The 317 ms is consistent with
the maintainers' own issue tracker (about 6 ms of JSON decoding against
159 ms of type mapping for an 874 KB response, apollo-ios#3600, 2024), and
Apollo's cache publish is as fast as Baton's commit: the store is not where
the time goes.

Caveats: a Mac, not a phone; one fixture; Apollo's release build, default
options, no SQLite; Apollo's response is 24% larger by construction. The
comparison package is in the repository so anyone can rerun or correct it.

Commands:

```bash
swift run -c release BatonBenchmarks
cd benchmarks/apollo-comparison && swift run -c release ApolloComparison
```
