# Benchmarks

Performance here is a measurement, not a speed you can promise on another
machine. Every number comes from `swift run -c release BatonBenchmarks` (or
the comparison package named in its section), recorded with the revision,
machine, OS and date. Append; never edit a past entry.

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
