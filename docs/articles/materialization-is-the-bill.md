# Materialization is the bill

Baton is faster than Apollo iOS and Apollo Kotlin on the same data, and the
reason is not a cleverer store. On the one step the stores share, writing
records into an empty cache, Apollo iOS takes 1.39 ms and Baton 1.24 ms. The
reason is three steps Apollo takes on every response or every read that Baton
does not take at all: building a model of the operation from the bytes,
rebuilding it from the store on every read, and reading the store
asynchronously. Each is work a view never asked for. This page itemizes the
bill, on a Mac and on a phone, with the caveats that go with it.

## The bill on a Mac

The fixture is a recorded page of the Rick and Morty API: 686,254 bytes, about
6,500 JSON objects, 899 records after normalization. Both clients key entities
by `id`; Apollo's own query adds `__typename` to every object, so its response
is 849,101 bytes. Apple M1 Pro, macOS 26.5.2, release builds, 2 October 2026,
Apollo iOS 2.4.0 with its in-memory cache, configured as its documentation
says ([BENCHMARKS.md](../../BENCHMARKS.md), the 0.1.0 entry).

| Step | Baton | Apollo iOS 2.4 |
|---|---|---|
| Response bytes to normalized records | 2.14 ms | 317 ms, models and records together |
| Publish into an empty store | 1.24 ms | 1.39 ms |
| Bytes to data in the store | 3.4 ms | 318 ms |
| The same payload again, nothing changed | 165 µs, and no view | 3.99 ms |
| From the store to something a view can read | 115 µs to check availability; the lens then reads slots | 228 ms to rebuild the query into models |
| One field | 26 ns, untracked | 296 ns, after that rebuild |
| `JSONSerialization` alone, for scale | 4.47 ms | 5.73 ms |

Read the rows, not the ratios. The store is not where Apollo's time goes: its
publish is as fast as Baton's commit. The 317 ms is the materialization, the
response parsed into a tree and the tree walked into generated models and
cache records, and it matches a report the maintainers' own tracker already
held: about 6 ms of JSON deserialization against about 159 ms of type mapping
for an 874 KB response
([apollo-ios#3600](https://github.com/apollographql/apollo-ios/issues/3600),
2024). Then a read pays the mapping again: 228 ms to execute the query against
the cache into a new model tree before a view can read one field. And a
refetch that changes nothing costs 3.99 ms and a new tree, because nothing
compares the old one with the new.

The last row is the one to keep. Tokenizing the bytes is cheap. Foundation
parses the whole response into dictionaries in 4.47 ms; Baton tokenizes and
normalizes it in 2.14 ms, faster than the general-purpose parser, because the
plan tells it which fields to expect, in which order, with which scalar types,
and it builds no tree on the way. The cost that dominates every client in this
comparison is what is built after the tokens, and Baton builds nothing a view
did not read.

## The bill on a phone

Apollo Kotlin is not Apollo iOS. Its write is faster by an order of magnitude,
and its 2026 normalized cache is the best disk cache in this comparison. The
shape is the same. Google Pixel 9, Tensor G4, Android 17, release builds, 7
October 2026, Apollo Kotlin 5.2.0 with the normalized cache 1.0.9, the memory
cache, keys configured as its documentation says
([BENCHMARKS.md](../../BENCHMARKS.md), "Apollo Kotlin 5.2.0, same operation,
same graph").

| Step | Baton | Apollo Kotlin 5.2 |
|---|---|---|
| Response bytes to data in the store | 6.5 ms | 44.6 ms, of which about 30 ms normalize the model tree into records |
| The same payload again, nothing changed | 0.36 ms | 1.1 ms |
| From the store to something a view can read | A 1.2 ms availability check; the lens then reads slots | 25 ms to rebuild the query into models |
| One field | 43 ns | 2 ns, after that rebuild |

Apollo parses the bytes into the generated models, writes the models back to a
map, and normalizes the map into records: 30 ms of the 44, more than three
frames at 120 Hz, off the main thread as its documentation requires. Reading
the query back rebuilds the model tree, 25 ms, and only then is a field a
property load. That property load is faster than Baton's lens read by
twenty-odd times, and the bench says so: where a field is read many times from
data already read, Apollo's model is the faster thing to hold. A screen that
reads every field of its twenty rows, 160 reads, pays 7 µs through the lens
against the 25 ms read that comes first on Apollo's side.

Apollo's own published figures tell the same story at larger sizes. Its Kotlin
performance page measured about 800 ms to normalize a nested query of about
6,000 records into the memory cache and about 530 ms to read them back into
models, on a 2017 Galaxy S8, excluding JSON parsing. A community report
against Apollo iOS 2.1.2 measured a cold read of 4,922 records from SQLite at
6 seconds, later more than 9, against 0.72 seconds from memory ([the
thread](https://community.apollographql.com/t/ios-sqlitenormalizedcache-cold-start-can-be-slower-than-reloading-data-from-backend/9344)).
Those are not numbers from this repository, and they are the same bill,
itemized by the people who pay it.

## What a user feels

Store benches are not screens. The end-to-end entry drives the Kotlin sample
and its Apollo Kotlin twin, the same two Compose screens over each client, on
the same Pixel 9 on 8 October 2026, against a server in the app's own process
so that every run gets the same bytes ([BENCHMARKS.md](../../BENCHMARKS.md),
"end to end on a phone").

| Scenario | Baton | Apollo Kotlin |
|---|---|---|
| Cold start over a warm store, the list on screen | 239.6 ms, the first frame | 272.1 ms, after a spinner |
| Tap a row to the detail's first frame, header from the store | 22.1 ms | 33.2 ms |
| Tap Next to the second page's first frame | 40.1 ms | 56.1 ms |
| Scrolling, frame CPU time at P50 / P90 | 3.09 / 7.31 ms | 3.07 / 7.32 ms |

Scrolling is a tie, and it should be: the rows are the same composables over
data already read, and neither client is on the scroll path. The differences
are where the clients are: the first frame after a launch, a tap into a detail
whose header is already in the store, a page turn. On Apollo's side the first
frame of a warm start and of a detail is a spinner, because its cache is read
off the main thread and the collected `watch()` starts at `null`; the data
followed 63 ms later in that run. On Baton's side the data is in the first
frame, because the read is synchronous.

## The three steps, and what replaces them

**No model tree.** The compiler emits a normalization plan per operation: one
selection per distinct selection set, each field with its storage key and its
kind. The ingest follows the plan through the bytes, off the main actor, keys
each object by its type's key fields, and writes a change set of slots. String
values stay as byte ranges into the response until the commit decides which
entry won, so a value the store already holds is compared as bytes and never
allocated. There is no `Codable`, no dictionary and no `Any` on the read path,
in either runtime.

**No re-execution.** Each slot of each record is an invalidation channel. A
commit on the main actor writes the slots that changed, nothing for a slot
whose value is equal, and notifies the observed fields that changed, once,
when the batch ends. A refetch of an unchanged page notifies nobody. A
connection page merges into one list and notifies once, on the connection,
rather than once per row on screen: 41 pages, 2,100 nodes, 41 notifications in
the 0.4.0 entry. An optimistic cycle, a layer applied, the server's answer
landing and the layer resolved, costs 413 µs on the Mac and notifies only what
differs in the end.

**No waiting.** Reads are synchronous on the main actor. A handle resolves
against the store before the first body runs, so a screen whose data is in the
store renders it in its first frame, and after a launch the image on disk is
read before the first body. The availability check that decides whether the
store can answer costs 115 µs for the whole fixture's plan on the Mac and 1.2
ms on the Pixel 9.

## How the numbers are kept honest

Every number above is in [BENCHMARKS.md](../../BENCHMARKS.md) with the
revision, the machine, the OS and the date, and that file is appended to,
never edited. The comparison harnesses, `benchmarks/apollo-comparison` for
Swift and `kotlin/benchmarks/apollo-comparison` for Kotlin, are in the
repository with the commands that run them. CI gates structure rather than
wall-clock time: the bytes of generated code per accessor line, and a file of
deterministic counts, such as the notifications a commit sends, diffed on
every run. A claim without a bench does not ship.

The caveats matter and they are in the file. The iOS numbers are from a Mac,
not a phone. It is one fixture, large and repetitive, chosen because it is
public and reproducible. Apollo iOS is measured with default options and no
SQLite; Apollo Kotlin with its memory cache, both clients called directly with
no network, no interceptor chain and no watcher; and Apollo's response is 24%
larger by construction on both. On the phone Baton's Kotlin runtime runs three
to four times slower than the same code on the JVM, which is ART's allocation
cost and the next thing the profile names. Where Apollo is ahead, the disk
policy on Kotlin, the install base and the deployment floor on iOS, [the
comparison](../comparison.md) says so.

What the shape gives an app is not a ratio. It is a response in the store a
few milliseconds after the bytes arrive, a refetch that changes one field
re-rendering one row, and a screen the app has seen rendering from the store
in its first frame. Those are the things a data layer can promise a product
team, and they are the things this one measures.
