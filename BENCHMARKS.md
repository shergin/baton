# Benchmarks

Performance here is a measurement, not a speed you can promise on another
machine. Every number comes from `swift run -c release BatonBenchmarks` (or
the comparison package named in its section), recorded with the revision,
machine, OS and date. Append; never edit a past entry.

Figures are those tables drawn again, by [`benchmarks/charts`](benchmarks/charts),
with malevich, the library behind `kaz`. The plot panel is that library's
pixel raster; the axes stay text. `cargo run --manifest-path
benchmarks/charts/Cargo.toml` rewrites the SVG files. A figure does not
replace the table it sits under.

## Across releases

Best ingest and best commit of the fixture at each release below.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="benchmarks/charts/read-path.svg">
  <source media="(prefers-color-scheme: light)" srcset="benchmarks/charts/read-path-light.svg">
  <img alt="Ingest and commit, best, from 0.1.0 through 0.6.0" src="benchmarks/charts/read-path.svg">
</picture>

## Unreleased, a cell judged by its kind in the check — 2026-10-09

Revision: the working tree on top of `b41f2ca`. The availability walk
counts a scalar cell as present only when its value fits the field's kind
(`Record.holds` in Swift, `fits` in `Availability.kt`), so a cell the image
wrote under a schema that since gave the field another kind reads as
absent and the operation fetches. The cost is one switch per waited scalar
cell of the walk, read on the Apple M1 Pro, macOS 26.5.2, best of one run
each, the median in parentheses, on a machine busier than the 8 October
entry's:

| Measurement | Before, 9 October | First spelling | Judged in place, non-recursive |
|---|---|---|---|
| The check of the fixture plan against the store | 127 µs (127) | 278 µs (279) | 137 µs (138) |
| Hydration of 898 rows | 1.78 ms (1.84) | 1.99 ms (2.13) | 1.88 ms (1.98) |
| Commit into an empty store, 899 records | 470 µs (505) | 481 µs (517) | 509 µs (531) |

The first spelling passed the cell's value to a function that judged it
and recursed for a list, and the check doubled: Swift does not inline a
recursive function, so each cell paid a call with the enum copied and its
payload retained; reading the cell in place inside the record, with the
list's elements judged by a function of their own, brought the check to
137 µs, the 10 µs over the baseline being the switch over 18,000 cells.
Hydration and the commit moved with the machine, whose commit row is
40 µs over the baseline in the same run.

## Unreleased, the entity key once per record, by the profile — 2026-10-09

Revision: the working tree on top of `419e08e`, in both runtimes. The
Kotlin ingest was profiled on the Pixel 9 (Tensor G4, Android 17, API 37)
before anything was built: the benchmark application made `profileable`
from the shell, `simpleperf record --app baton.benchmarks -f 4000
--call-graph fp` over the `IngestBenchmark` run of the entry below, 10,580
samples, 88% of them on the benchmark's thread, 11% on ART's
`HeapTaskDaemon` and 1% on the JIT; the medians under the profiler were
5.27 ms ingest and 0.98 ms commit. Self time by symbol, of all samples:

| Share | Where |
|---|---|
| 12.3% | `Scanner.scanString`, the string scan |
| 11.7% | `Cursor.objectAt`, the object walk |
| 6.1% | `madvise`, the collector returning the change set's large arrays, on its own thread |
| 4.4%, 4.1% | `ChangeSet.group`, `ChangeSet.addEntry` |
| 4.2%, 1.5%, 1.3% | `Scanner.skipWhitespace`, `expect`, `peek` |
| 8.2% inclusive | UTF-8 bytes into a `String` (`StringFactory`, the allocation of its chars) |
| 5.8% inclusive | `StringBuilder` appends and their allocations |
| 1.4%, 1.4% | `String.hashCode`, `HashMap.getNode` |
| 1.7%, 1.5%, 1.5% | `Cursor.scalarValue`, `Store.apply`, `Cursor.entity` |

The fixture names 6,533 entities for its 899 records, since every episode
of a character names the episode's characters, and the ingest built the
record key `Type:id` once per occurrence: the id decoded into a string,
the concatenation, the hash and the probe of the change set's index, for
a record it had seen six times before. The strings, the builders and the
hashing above were mostly that. A table keyed by the bytes now stands in
front of the change set's string index, in both runtimes: open addressing
over four ints a slot, the record, where the key field's bytes start and
end, and their hash, with the string index as the record of truth, so a
key is built once per record and a spelling the table does not hold, an
escaped id, a key of several fields, still finds its record through the
string. The commit is untouched, and the Kotlin store's count of strings
is the same, since the record's key is made at first sight either way.

The Kotlin `IngestBenchmark`, three runs of 300 after 200 warm-ups on the
Pixel 9, against the entry of 2026-10-08 on the same device:

| Runtime | Ingest | Commit | Ingest allocates | Commit allocates |
|---|---|---|---|---|
| `86ca4c2`, the 8 October rows | 5.21, 5.19 ms | 0.97, 0.97 ms | 1,856 KB | 424 KB |
| The entity table | 4.32, 4.32, 4.33 ms | 0.97, 0.97, 0.98 ms | 1,604 KB | 448 KB |

The Swift suite on the Apple M1 Pro, macOS 26.5.2, three runs in one
sitting, the first without the change for today's baseline, since the
machine was not the quiet one of the 8 October entry (an Android emulator
idling and other sessions building); best, with the median in
parentheses:

| Measurement | Today without the table | With the table, two runs |
|---|---|---|
| Response bytes into a change set | 2.09 ms (2.24) | 1.73 ms (1.80), 1.72 ms (1.86) |
| Commit into an empty store, 899 records | 499 µs (536) | 470 µs (505), 471 µs (499) |
| Commit of the same payload again | 115 µs (120) | 113 µs (118), 114 µs (115) |
| Commit with one field changed, 20 rows observing | 117 µs (123) | 116 µs (116), 116 µs (119) |
| The check of the fixture plan against the store | 129 µs (131) | 127 µs (127), 128 µs (131) |
| Hydration of 898 rows | 1.78 ms (1.89) | 1.79 ms (1.84), 1.78 ms (1.94) |
| A pass over one root reaching 50,004 records | 1.60 ms (1.77) | 1.56 ms (1.93), 1.55 ms (1.77) |
| Untracked lens read, per field | 20.7 ns | 20.3 ns, 20.3 ns |

The ingest: 1.73 ms from 2.09 today, and from the 2.06 ms the 8 October
entry recorded on the quiet machine; the rows the change does not touch
are within the day's noise of that entry, the commit's 499 against its
468 to 472 among them.

The Apollo Kotlin comparison run again the way the entry of 2026-10-08
describes, the device three times and the JVM (OpenJDK 27, Homebrew, on
the same Mac under load averages of 5 to 7) three times, all three runs
in a cell. Apollo's device rows are within two percent of that entry, the
device standing still; its JVM `JsonReader` control ran 22% faster than
there on the same JDK, so the JVM columns compare within this entry only.

| Step | Baton, JVM | Apollo Kotlin, JVM | Baton, Pixel 9 | Apollo Kotlin, Pixel 9 | Ratio, Pixel 9 |
|---|---|---|---|---|---|
| Response bytes → change set / records | 1.12, 1.10, 1.08 ms | 8.06, 8.10, 8.33 ms (parse 2.24, 2.14, 2.13 + normalize 5.82, 5.96, 6.20) | 4.35, 4.36, 4.34 ms | 41.4, 42.2, 42.4 ms (parse 11.83, 12.08, 12.01 + normalize 29.55, 30.13, 30.36) | 9.7× |
| Commit / merge into an empty store | 168, 167, 162 µs | 636, 671, 662 µs (`MemoryCache`) | 989, 988, 987 µs | 2.24, 2.30, 2.28 ms | 2.3× |
| Bytes → data in the store, in one run | 1.29, 1.27, 1.24 ms | 8.76, 8.80, 9.01 ms | 5.34, 5.35, 5.32 ms | 43.74, 44.65, 44.69 ms | 8.4× |
| Same payload again, nothing changes | 178, 183, 176 µs | 295, 420, 292 µs (the records merged again) | 303, 307, 300 µs | 1.12, 1.17, 1.14 ms | 3.8× |
| From the store to readable data | 0 + 134, 133, 129 µs availability check | 6.03, 6.38, 5.88 ms (`readOperation`) | 0 + 747, 894, 748 µs | 24.90, 25.02, 25.25 ms | — |
| One field read, per field | 21.8, 22.6, 22.0 ns (lens, untracked) | 5.59, 5.66, 5.49 ns | 47.2, 47.6, 46.9 ns | 1.67, 1.68, 2.44 ns | 0.04× |
| Apollo's `JsonReader` alone, every token read, for scale | 1.50, 1.46, 1.49 ms (686 KB) | 1.89, 1.83, 1.83 ms (849 KB) | 8.41, 8.37, 8.35 ms | 10.75, 10.70, 10.69 ms | — |

`writeOperation` whole into an empty cache took 6.47, 6.68 and 6.85 ms on
the JVM and 31.38, 31.97 and 31.95 ms on the Pixel 9; the same data
written again through it 5.90, 6.26 and 6.39 ms, and 31.39, 31.90 and
31.75 ms. On Baton's side the phone moved where the table is: the ingest
4.34 to 4.36 ms where it was 5.28 and 5.26, and so the response into the
store 5.32 to 5.35 ms where it was 6.27 and 6.22; the commit, the same
payload again and the check stand where they were, the check's 894 µs
being one run's outlier against two of 747 and 748.

What the profile says next, not built: the scanner's loops read and write
the position field per byte where a local would do; the collector's share
is the change set's arrays, sized by the response's bytes and returned
each ingest; and the commit's main-thread time is a third the decoding of
the strings that changed, which the ingest could do off the main thread
at the cost of decoding strings a warm store compares away without one,
a trade the refetch case has to be benched for before it is taken.

## Unreleased, the store's heap, measured without the change set — 2026-10-09

Revision: the working tree on top of `7f81f7b`, with the change set's
entity table the entry above describes. The Kotlin `IngestBenchmark`'s
"a store holds" figure is the heap in use after a collection with the
store alive, less the heap in use after a collection before the store was
made. Until today the ingest and the commit ran in the measuring frame
itself, `store.commit(Ingest.normalize(...))`, which runs once and so is
interpreted, and an interpreted frame keeps alive whatever its registers
still hold: the change set counted as the store's. The commit now happens
in a frame of its own, `committedStore`, gone before the heap is read;
`dexdump` of the test APK shows the call is not inlined and the measuring
frame holds the store alone afterwards. One diagnostic build measured the
four ways in one process on the Pixel 9, Android 17 (API 37), twice:

| Measured | Run 1 | Run 2 |
|---|---|---|
| A store, the commit in its own frame | 328 KB | 328 KB |
| The old measuring frame, store and change set | 956 KB | 956 KB |
| An uncommitted change set alone | 652 KB | 656 KB |
| A store again, the commit in its own frame | 328 KB | 328 KB |

So a store holds 328 KB after the commit of the fixture, and the column
"A store holds" of the entry of 2026-10-08 on the record's channels and
sizing, 1,100, 896 and 884 KB, was the store and a change set of about
560 KB, 64 KB smaller then than today's with its entity table. None of
the changes between those rows touched the change set, so the row-to-row
differences there were the store's own; the rows were not re-measured.
The three runs of the benchmark after the fix:

| Run | Ingest | Commit | Ingest allocates | Commit allocates | A store holds |
|---|---|---|---|---|---|
| 1 | 4.32 ms | 0.97 ms | 1,604 KB | 448 KB | 328 KB |
| 2 | 4.32 ms | 0.97 ms | 1,604 KB | 448 KB | 328 KB |
| 3 | 4.33 ms | 0.98 ms | 1,604 KB | 448 KB | 328 KB |

The benchmark app's manifest declares it `profileable` from the shell, so
`simpleperf` on the device can record the release process the benchmark
runs in; ART compiles it as it does any app, and the medians did not move.

## Unreleased, the ingest and the commit, by the profile — 2026-10-08

Revision: the working tree on top of `bb93aff`. A time profile of the
suite (Instruments at 10 kHz over the first two seconds, twelve launches,
entry closures isolated by frame) put the ingest's largest cost, 28%, on
copying the 144-byte `ResolvedField` struct once per JSON key at two
sites of the cursor, each copy retaining its lists; and the commit's on
three things: the `ObservationRegistrar` each record makes with itself
(a sixth), the records table hashed twice per key and regrown as it
filled (a fifth), and the dynamic exclusivity checks on the record's
value array and the store's table (an eighth). String hashing was real
and secondary; bounds checks were nothing. Three changes follow the
profile: the cursor reads a matched field's members through the list
and never copies the struct; `Record.values` and `Store.records` are
`@exclusivity(unchecked)`, isolated to the main actor as the rendered
lists already were; and the table is reserved for the change set's
records before a commit grows it. The registrar stays as it was: four
spellings that make it at the first read were measured to cost every
read 45 to 150 ns, since the registrar's layout is its library's and
only a stored constant is used in place, and the read is the thesis.
`swift run -c release BatonBenchmarks`, the whole suite, twice before
(at `bb93aff`) and twice after, back to back on a quiet Apple M1 Pro,
macOS 26.5.2, Xcode 26.6, Swift 6.3.3; best (median).

| Measurement | `bb93aff`, two runs | After, two runs |
|---|---|---|
| Response bytes into a change set | 2.92 ms (3.26), 2.93 ms (3.08) | 2.06 ms (2.20), 2.06 ms (2.16) |
| Commit into an empty store, 899 records | 594 µs (606), 603 µs (648) | 472 µs (485), 468 µs (472) |
| Commit of the same payload again | 128 µs (128), 130 µs (130) | 114 µs (114), 113 µs (114) |
| Commit with one field changed, 20 rows observing | 130 µs (131), 133 µs (134) | 116 µs (120), 115 µs (116) |
| The check of the fixture plan against the store | 138 µs (138), 138 µs (138) | 127 µs (127), 127 µs (127) |
| Hydration: the check reads 898 rows into an empty store | 1.92 ms (2.08), 1.93 ms (2.16) | 1.79 ms (1.81), 1.78 ms (1.94) |
| Untracked lens read, per field | 25.7 ns (25.8), 25.8 ns (25.8) | 20.9 ns (21.0), 20.5 ns (20.5) |
| Tracked read, a row body of 8 fields, per field | 589 ns (637), 565 ns (600) | 579 ns (628), 580 ns (606) |
| Untracked value read, per field | 33.2 ns (33.4), 33.3 ns (34.1) | 28.2 ns (29.2), 28.3 ns (28.4) |
| Field selected on an interface, untracked | 22.2 ns (22.4), 22.9 ns (23.1) | 18.8 ns (18.9), 18.8 ns (18.8) |
| `@catch` read of a field without an error | 85.8 ns (88.9), 86.5 ns (89.3) | 78.8 ns (79.0), 78.6 ns (79.0) |
| Nodes of the merged connection, 2,100 lenses, untracked | 88.9 µs (89.1), 89.0 µs (91.8) | 80.9 µs (81.0), 80.8 µs (80.9) |
| A pass that keeps none of 50,000 records | 24.7 ms (28.6), 29.2 ms (33.9) | 22.0 ms (25.2), 20.4 ms (26.1) |
| A spread with `@arguments`, the control that reads no record | 10.2 ns, 10.7 ns | 10.3 ns, 10.3 ns |

The ingest is 30% faster, the commit a fifth, and the untracked reads
nine to twenty percent, since the value array's exclusivity check was on
their path too; the marking passes do not move. The collection's sweep,
the noisiest entry, moves within its spread.

## Unreleased, the collection walk's regression, bisected — 2026-10-08

The entry below found the pass over one root reaching 50,004 records at
2.4 times what the keys step recorded. A bisect over `fcec2ce..f0b8328`,
each step the whole suite at that commit built with that commit's
compiler, on the same Apple M1 Pro, macOS 26.5.2, Xcode 26.6, Swift 6.3.3,
names the commit and the shape of the loss; the one-root pass, best
(median):

| Commit | What it did | One-root pass |
|---|---|---|
| `e32a412`, the parent | | 2.52 ms (2.84) |
| `3b468bb`, "Give a resolved variant the lists its walks need", 2026-10-06 | `ResolvedVariant` became a struct of ten lists, and every walk looked it up by value | 23.50 ms (23.61); the pass over 301 roots 24 ms from 2.6, the pass over 300 roots reaching one record each 290 µs from 34, the ingest 7.0 ms from 3.0 |
| `0c9c0d6`, "Key a record by the fields the configuration names" | | 5.12 ms (5.93); the ingest 3.21 ms, the 300-root pass 67 µs |
| `c7d3e7e` to `de29024`, four commits | | 5.08 ms to 6.25 ms |
| `f0b8328` | | 6.38 ms (6.53) |

The sweep, "a pass that keeps none of 50,000 records", stayed between
21.9 and 26.4 ms best at every step. The cause is a struct copy: a
`ResolvedVariant` holds ten lists and a string, `variant(for:)` returned
it by value, and a lookup per record retained each of them and released
them at the end of the step, in the collector's walk and in the ingest's.
The fix makes `ResolvedVariant` a final class, so a lookup retains one
object. The whole suite twice, back to back, before (the epoch-marks
commit `f8c4b88`, the two runs of the entry below) and after, best
(median):

| Measurement | `f8c4b88`, two runs | With the class, two runs |
|---|---|---|
| A pass over one root reaching 50,004 records | 4.71 ms (5.22), 4.68 ms (5.02) | 1.58 ms (1.67), 1.62 ms (1.64) |
| A pass over 301 roots, 50,304 records | 4.99 ms (5.22), 4.75 ms (5.11) | 1.63 ms (2.11), 1.66 ms (1.71) |
| A pass over 300 roots reaching one record each | 70.9 µs (72.7), 72.1 µs (72.6) | 25.4 µs (26.2), 25.6 µs (26.5) |
| A pass that keeps none of 50,000 records | 21.3 ms (22.6), 24.4 ms (29.4) | 24.7 ms (28.6), 29.2 ms (33.9) |
| The lifetime step's pass, best / median / worst | 0.56 / 6.27 / 11.08, 0.67 / 6.37 / 9.58 ms | 0.14 / 1.99 / 2.84, 0.15 / 2.01 / 2.76 ms |
| The check of the fixture plan against the store | 605 µs (615), 602 µs (638) | 138 µs (138), 138 µs (138) |
| Hydration: the check reads 898 rows into an empty store | 2.41 ms (2.63), 2.43 ms (2.64) | 1.92 ms (2.08), 1.93 ms (2.16) |
| Response bytes into a change set | 3.23 ms (3.40), 3.27 ms (3.70) | 2.92 ms (3.26), 2.93 ms (3.08) |
| Commit into an empty store, 899 records | 594 µs (606), 603 µs (648) | the same |
| Untracked lens read, per field, the control | 25.8 ns | 25.7, 25.8 ns |
| The session's footprint, 61,308 records | +28.0, +28.1 MB | +20.3, +20.4 MB |
| A new character given name (slot 1), for 50,000 | +28.8, +27.0 MB | +22.0, +21.5 MB |

The marking passes are three times faster and below what the keys step
recorded (2.49 to 2.80 ms, 31.7 to 36.0 µs), the lifetime step's median
pass 2.0 ms where that step recorded 2.53 to 2.71, and the same copy had
been taxing every walk that looks a variant up per record: the
availability check is 4.4 times faster, back near the 105 to 110 µs the
earlier entries hold, hydration a fifth faster and the ingest a tenth. The
sweep moves within its spread, the noisiest entry in the suite. The
session's footprint is 8 MB smaller, which says the copies also left
memory behind; the slot-1 line stands 2 MB above its `f0b8328` reading,
which the mark on the record does not explain and the entry below leaves
with the allocator.

## Unreleased, the collection pass marks with an epoch — 2026-10-08

Revision: the working tree on top of `f0b8328`. The collector marks every
record it reaches with the store's epoch, a number on the record, where it
inserted each into a `Set<ObjectIdentifier>`; the sweep reads the mark,
and a root prunes its links to swept records by the record's own `swept`
flag, so a pass allocates nothing. The walk is unchanged: a record two
paths reach is still walked under each, since each follows its own links.
`swift run -c release BatonBenchmarks`, the whole suite, on an Apple M1
Pro (MacBook Pro), macOS 26.5.2, Xcode 26.6, Swift 6.3.3; best (median);
the baseline twice at `f0b8328` and the change twice, back to back, on a
machine running nothing else. The first baseline run overlapped a Gradle
compile and read 6.79 ms (7.17) on the one-root pass; it is left out.

| Measurement | Before | After, two runs |
|---|---|---|
| A pass over one root reaching 50,004 records | 6.38 ms (6.53) | 4.71 ms (5.22), 4.68 ms (5.02) |
| A pass over 301 roots, 50,304 records | 6.48 ms (7.17) | 4.99 ms (5.22), 4.75 ms (5.11) |
| A pass over 300 roots reaching one record each | 82.2 µs (82.3) | 70.9 µs (72.7), 72.1 µs (72.6) |
| A pass that keeps none of 50,000 records | 24.8 ms (28.1) | 21.3 ms (22.6), 24.4 ms (29.4) |
| The lifetime step's pass, best / median / worst | 0.82 / 8.05 / 8.95 ms | 0.56 / 6.27 / 11.08 ms, 0.67 / 6.37 / 9.58 ms |
| Untracked lens read, per field, the control | 25.8 ns | 25.8 ns, 25.8 ns |

The mark takes a quarter off the pass that reaches 50,004 records and a
seventh off the one over 300 roots; the pass that keeps none is the sweep,
and moves within its spread. Two things this run says beyond the change.
The one-root pass at `f0b8328` is 6.38 ms where the keys step recorded
2.68 ms (3.10) and the lifetime step 2.49 ms (2.77) on this machine: the
walk, not the sweep, slowed by about 2.4 times somewhere in the Swift
commits since `fcec2ce`, which a bisect is owed. And the long session's
"a new character given name (slot 1)" footprint reads +27.0 and +28.8 MB
after the change where it read +19.7 and +19.8 MB before, while the
session's footprint over 61,308 records stays at +28 MB in all four runs;
a four-byte mark costs at most one allocation quantum per record, 0.8 MB
over 50,000, so what moved is the attribution: the collection section
before it leaves no freed set behind for the allocator to reuse.

## Unreleased, Apollo Kotlin again after the record's channels — 2026-10-08

Revision: `86ca4c2`. The comparison of the 7 October entry run again the
same way (`kotlin/benchmarks/apollo-comparison`: `runComparison` on the
JVM, and the instrumented test of its release-built application on the
Pixel 9, which `dumpsys package` shows without a `DEBUGGABLE` flag; 300
runs after 200 warm-up runs; each machine twice, both runs in a cell),
after the two commits that made a record's cells plain values with a
channel per slot read (`939b525`) and sized its arrays by what it holds
(`86ca4c2`). Apollo Kotlin 5.2.0 and the normalized cache 1.0.9, as
before. The Pixel 9 (Tensor G4, Android 17, API 37) is the device of the
7 October entry on the same OS, so its columns compare across the two
entries; the JVM is OpenJDK 27 (Homebrew) where that entry ran
OpenJDK 21.0.12.1, on the same Apple M1 Pro under macOS 26.5.2, so the
JVM columns compare within this entry only.

| Step | Baton, JVM | Apollo Kotlin, JVM | Ratio | Baton, Pixel 9 | Apollo Kotlin, Pixel 9 | Ratio |
|---|---|---|---|---|---|---|
| Response bytes → change set / records | 1.21, 1.21 ms | 8.81, 8.50 ms (parse 2.67, 2.65 + normalize 6.14, 5.85) | 7.2× | 5.28, 5.26 ms | 42.2, 42.5 ms (parse 12.01, 12.10 + normalize 30.23, 30.41) | 8.0× |
| Commit / merge into an empty store | 165, 168 µs | 656, 667 µs (`MemoryCache`) | 4.0× | 985, 957 µs | 2.24, 2.28 ms | 2.3× |
| Bytes → data in the store, in one run | 1.38, 1.38 ms | 9.48, 9.17 ms | 6.8× | 6.27, 6.22 ms | 44.61, 44.83 ms | 7.2× |
| Same payload again, nothing changes | 178, 180 µs | 260, 322 µs (the records merged again) | 1.6× | 310, 316 µs | 1.13, 1.12 ms | 3.6× |
| From the store to readable data | 0 (lenses read slots) + 128, 129 µs availability check | 5.96, 6.47 ms (`readOperation`, the whole query into models) | — | 0 + 737, 758 µs | 24.57, 24.70 ms | — |
| One field read, per field | 21.9, 21.6 ns (lens, untracked) | 5.55, 5.50 ns (a property of the read `Data`) | 0.25× | 46.6, 47.7 ns | 1.65, 1.68 ns | 0.04× |
| Apollo's `JsonReader` alone, every token read, for scale | 1.91, 1.89 ms (686 KB) | 2.42, 2.41 ms (849 KB) | — | 8.32, 8.36 ms | 10.63, 10.69 ms | — |

`writeOperation` whole into an empty cache took 6.73 and 6.72 ms on the
JVM and 32.22 and 32.50 ms on the Pixel 9; the same data written again
through it 6.24 and 6.19 ms, and 31.73 and 32.00 ms.

What moved on the phone since 7 October, on Baton's side: the commit, 985
and 957 µs where it was 1.28 and 1.37 ms; the availability check, 737 and
758 µs where it was 1.20 and 1.22 ms, since the store's own reads of a
record no longer go through snapshot state either; and so the response
into the store, 6.27 and 6.22 ms where it was 6.38 and 6.62 ms. The
untracked field read pays for the second array it loads, the channel's
beside the value's: 46.6 and 47.7 ns where it was 43.2 and 43.8 ns.
Apollo's side is within a percent or two of 7 October on every row, which
is the device standing still.

## Unreleased, the Kotlin record's channels and sizing on a device — 2026-10-08

Revision: the working tree on top of `47bdcca`. The Kotlin `IngestBenchmark`
(`kotlin/benchmarks/android`, the release build that is not debuggable, run
as the entry below describes) now also takes the medians of what the
runtime's `art.gc.bytes-allocated` counter grows by during the ingest and
during the commit, which is good to one allocation buffer since the counter
moves as buffers are handed out, and measures once what one store holds
after the commit: the heap in use after a collection with the store alive,
less the heap in use after a collection before the store was made. Each row
is two runs of 300 after 200 warm-ups on the Pixel 9, Android 17 (API 37),
in one sitting; the first row is the runtime at `47bdcca` under the
extended benchmark.

| Runtime | Ingest, off the main thread | Commit, on the main thread | Ingest allocates | Commit allocates | A store holds |
|---|---|---|---|---|---|
| `47bdcca`: a cell is snapshot state, one per written slot; arrays sized by the type's slot count | 5.23, 5.25 ms | 1.35, 1.36 ms | 1,820 KB | 672 KB | 1,100 KB |
| A channel per slot read, made at the first read; cells plain values | 5.25, 5.27 ms | 0.95, 0.94 ms | 1,828 KB | 448 KB | 896 KB |
| And the arrays sized by what the record holds | 5.21, 5.19 ms | 0.97, 0.97 ms | 1,856 KB | 424 KB | 884 KB |

The channel is the change: the commit takes 0.95 ms where it took
1.35 ms, allocates 448 KB where it allocated 672 KB, and a store holds
896 KB where it held 1,100 KB, because a slot nobody has read is a store
into an array and no snapshot state object with its record of writes. The
ingest does not touch records and does not move; its allocation column
wobbles by less than one buffer across the rows and is not a reading. The
sizing moves little here by construction: the benchmark's process holds
one document, so a type's slot count is close to what its records render;
24 KB less allocated by the commit and 12 KB less held, for a time within
0.02 ms. Its case is a process with many documents on a type, which no
bench holds yet.

## Unreleased, the Kotlin ingest on a device — 2026-10-07

Revision: `436da2b`. The Kotlin runtime's `IngestBenchmark`
(`kotlin/baton/src/androidDeviceTest`), run with
`adb shell am instrument -w -e class baton.IngestBenchmark
baton.test/androidx.test.runner.AndroidJUnitRunner` and read from
`adb logcat -d -s BatonIngest:I`: the Fixture response (686,254 bytes,
899 records) tokenized by the generated plan into a change set, then
committed into an empty store; the medians of 300 runs after 200 warm-up
runs, twice. The device test APK is a debuggable build, which is how the
Android Gradle plugin builds a device test; the number from a build that
is not debuggable is the second table. The JVM row is `IngestTiming` in
`jvmTest`, not a benchmark, for scale.

| Where | Ingest, off the main thread | Commit, on the main thread |
|---|---|---|
| Google Pixel 9, Tensor G4, Android 17 (API 37), 120 Hz display | 19.03 ms, 19.18 ms | 6.82 ms, 6.68 ms |
| The `baton` emulator, arm64 Android 16 image on an M1 Pro | 12.16 ms, 12.57 ms | 4.36 ms, 5.61 ms |
| The JVM, JDK 21 on an M1 Pro | 1.71 ms | 0.32 ms |

From the debuggable build, the commit, which is the main thread's share,
fits a frame at 60 Hz (16.7 ms) and at 120 Hz (8.3 ms), and the ingest
does not fit one and does not run on one; that reading is superseded by
the release build's table below, where both fit a frame. The debuggable
device was eleven times the JVM on the ingest and twenty on the commit; the
release build shows how much of that was the build and how much is ART's
allocation cost (`docs/decisions/native-runtimes.md`).

The same benchmark from a build that is not debuggable, revision
`5a2a0af`: `kotlin/benchmarks/android`, an application built with the
release build type (signed with the debug key, not minified) whose
instrumented test is `IngestBenchmark`, run with
`adb shell am instrument -w -e class baton.IngestBenchmark
baton.benchmarks.test/androidx.test.runner.AndroidJUnitRunner`;
`adb shell dumpsys package baton.benchmarks` shows no `DEBUGGABLE` flag.
The same device, the same day, the same 300 runs after 200; the
debuggable rows are the table above, and the debuggable build run again
beside the release one gave 19.11 ms and 6.73 ms on the Pixel 9.

| Where | Build | Ingest, off the main thread | Commit, on the main thread |
|---|---|---|---|
| Google Pixel 9, Tensor G4, Android 17 (API 37) | debuggable device test | 19.03 ms, 19.18 ms | 6.82 ms, 6.68 ms |
| Google Pixel 9, Tensor G4, Android 17 (API 37) | release, not debuggable | 5.11 ms, 5.18 ms | 1.32 ms, 1.30 ms |
| The `baton` emulator, arm64 Android 16 image on an M1 Pro | debuggable device test | 12.16 ms, 12.57 ms | 4.36 ms, 5.61 ms |
| The `baton` emulator, arm64 Android 16 image on an M1 Pro | release, not debuggable | 4.33 ms | 1.10 ms |

Most of the gap to the JVM was the debuggable build: on the Pixel 9 the
release build ingests 3.7 times as fast as the debuggable one and commits
5.2 times as fast, which leaves the device three times the JVM on the
ingest and four times on the commit. The commit takes a sixth of a 120 Hz
frame.

### Apollo Kotlin 5.2.0, same operation, same graph

Revision: `194a104`. Measured with `kotlin/benchmarks/apollo-comparison`,
which runs both clients in one process, one after the other, on one
thread: on the JVM with `gradle :benchmarks:apollo-comparison:runComparison`
(OpenJDK 21.0.12.1, Apple M1 Pro, macOS 26.5.2), and on the Pixel 9
(Tensor G4, Android 17, API 37) as the instrumented test of
`kotlin/benchmarks/apollo-comparison/android`, an application built with
the release build type, signed with the debug key and not minified, with
`adb shell am instrument -w -e class baton.comparison.ComparisonBenchmark
baton.comparison.android.test/androidx.test.runner.AndroidJUnitRunner`;
`adb shell dumpsys package baton.comparison.android` shows no
`DEBUGGABLE` flag. Every number is a median of 300 runs after 200 warm-up
runs; each machine ran the whole bench twice, and a cell gives both runs.
Same machine, same day as each other: 7 October 2026.

Apollo Kotlin 5.2.0 with the normalized cache 1.0.9 (`com.apollographql.cache`),
the latest stable releases on Maven Central that day, configured as their
documentation says: the Gradle plugin compiles the same query text as the
Apollo iOS comparison (`benchmarks/apollo-comparison/operations`) against
`spec/rickandmorty/schema.graphql`, the cache's compiler plugin reads
`@typePolicy(keyFields: "id")` on `Character`, `Location` and `Episode`
from `extra.graphqls`, and the client is
`ApolloClient.Builder().cache(MemoryCacheFactory(maxSizeBytes = 10 MB))`
through the extension that plugin generates, the store
`apolloClient.apolloStore`, the memory cache, no SQL. The cache's compiler
plugin adds `__typename` first to every selection set below the root, which
is what `benchmarks/apollo-comparison/fixture-apollo.json` holds: 849,101
bytes against Baton's 686,254, the same data, every one of its 6,535
objects with `__typename` first and nothing else different. Baton's side
is the plan `batonc` generates from `spec/sources/Fixture.graphql`.

Apollo's write is timed in the pieces `ApolloStore.writeOperation` is made
of, since the store exposes them: the bytes parsed into the generated
`Operation.Data` by `parseResponse` over its own `JsonReader` (the call its
HTTP transport makes); the data written back to a map
(`withErrors`) and normalized into records (`ApolloStore.normalize`); and
the records merged into an empty `MemoryCache` (`accessCache { merge }`
with the `DefaultRecordMerger` the store uses). `writeOperation` whole
into an empty cache, normalization and merge together, took 6.34 and
6.33 ms on the JVM and 32.67 and 32.38 ms on the Pixel 9, the sum of its
pieces. We found no path from bytes to records that skips the model:
`writeToCacheAsynchronously` moves the write after the response is
emitted and does not shorten it. Apollo's normalizer keys the eleven
locations whose `id` is null as one record, `Location:null`, so its store
holds 889 records where Baton's holds 899, those eleven keyed by their path.

| Step | Baton, JVM | Apollo Kotlin, JVM | Ratio | Baton, Pixel 9 | Apollo Kotlin, Pixel 9 | Ratio |
|---|---|---|---|---|---|---|
| Response bytes → change set / records | 1.41, 1.44 ms | 8.20, 8.16 ms (parse 2.53, 2.49 + normalize 5.67, 5.67) | 5.7× | 5.11, 5.25 ms | 42.3, 42.1 ms (parse 11.86, 11.75 + normalize 30.41, 30.38) | 8.1× |
| Commit / merge into an empty store | 204, 212 µs | 679, 671 µs (`MemoryCache`) | 3.2× | 1.28, 1.37 ms | 2.21, 2.24 ms | 1.7× |
| Bytes → data in the store, in one run | 1.64, 1.67 ms | 8.92, 8.90 ms | 5.4× | 6.38, 6.62 ms | 44.62, 44.64 ms | 6.9× |
| Same payload again, nothing changes | 164, 169 µs | 262, 263 µs (the records merged again) | 1.6× | 356, 375 µs | 1.12, 1.11 ms | 3.1× |
| From the store to readable data | 0 (lenses read slots) + 205, 209 µs availability check | 7.22, 7.49 ms (`readOperation`, the whole query into models) | — | 0 + 1.20, 1.22 ms | 25.11, 24.92 ms | — |
| One field read, per field | 20.4, 20.3 ns (lens, untracked) | 4.19, 4.38 ns (a property of the read `Data`) | 0.21× | 43.2, 43.8 ns | 1.95, 1.65 ns | 0.04× |
| Apollo's `JsonReader` alone, every token read, for scale | 1.80, 1.78 ms (686 KB) | 2.20, 2.24 ms (849 KB) | — | 8.25, 8.18 ms | 10.55, 10.47 ms | — |

The same data written again through `writeOperation`, which normalizes
before it merges, took 6.12 and 6.11 ms on the JVM and 32.22 and 31.86 ms
on the Pixel 9; the row above is the merge alone, as Baton's is the commit
alone.

Apollo Kotlin is not Apollo iOS: on the same data its write is 8.9 ms on
the JVM against Apollo iOS's 318 ms on the same Mac (the 0.1.0 entry), and its cache merge is
within a few times Baton's commit. The shape is the same. Apollo builds
the model tree from the bytes, writes it back to a map and normalizes the
map, and the normalization is the larger part: 30 ms of the 44 on the
phone, more than three frames at 120 Hz, off the main thread as its
documentation asks. Reading the query back rebuilds the model tree, 25 ms
on the phone, and only then is a field a property load, 2 ns, faster than
Baton's lens read by twenty-odd times on the phone and five on the JVM. Baton materializes nothing a view did
not read: the response is in the store in 6.5 ms, the availability check
answers in 1.2 ms, and a lens pays 43 ns for each field a view reads, so a
screen that reads every field of the twenty rows, 160 reads, pays 7 µs
against the 25 ms read that comes first on Apollo's side. Where a field
is read many times from data already read, Apollo's model is the faster
thing to hold.

Caveats: one fixture; the memory cache only; both clients called directly,
with no network, no interceptor chain and no watcher; Apollo's suspend
calls run in `runBlocking` on the calling thread, where its memory cache
does not switch threads; Apollo's response is 24% larger by construction.
The harness is in the repository beside the Swift one so anyone can rerun
or correct it:

```bash
cd kotlin
gradle :benchmarks:apollo-comparison:runComparison
gradle :benchmarks:apollo-comparison:android:installRelease \
  :benchmarks:apollo-comparison:android:installReleaseAndroidTest
adb shell am instrument -w -e class baton.comparison.ComparisonBenchmark \
  baton.comparison.android.test/androidx.test.runner.AndroidJUnitRunner
```

## Unreleased, end to end on a phone — 2026-10-08

Revision: `1ad451a`. What a user feels, from launch or a tap or a response
to the frame that shows it, for Baton and Apollo Kotlin on the same phone
with the same bytes: `kotlin/benchmarks/macro`, a Macrobenchmark module
(`androidx.benchmark:benchmark-macro-junit4` 1.5.0, UiAutomator 2.4.0),
driving the Baton sample (`kotlin/samples/android`, `baton.sample.android`)
and its Apollo Kotlin twin (`kotlin/samples/apollo-android`,
`baton.sample.apollo`) on a Google Pixel 9 (Tensor G4, Android 17, API 37,
build CP3A.260905.009, 120 Hz display), 8 October 2026, both apps in one
run, one after the other.

The apps. The same two screens, the characters a page at a time and a
character's detail on tap, with the same Compose layout (Compose 1.12.1,
Material 3 1.9.0), each over its own client: Baton through `rememberQuery`
with its default fetch policy, store or network, and a store that keeps
its image (`Persistence.named`); Apollo Kotlin 5.2.0 with the normalized
cache 1.0.9, the memory cache chained in front of the SQL cache
(`MemoryCacheFactory(10 MB).chain(SqlNormalizedCacheFactory(context,
"rickandmorty.db"))`) through the `cache` extension its compiler plugin
generates, `@typePolicy(keyFields: "id")` on the three entity types,
`@fieldPolicy(forField: "character", keyArgs: "id")` so a detail's header
is read from the cache, and each query read through `watch()` collected as
Compose state, its default fetch policy cache first. Neither app asks the
network for data its store holds, which is what makes the warm start a
start from the store. Both are release builds, signed with the debug key,
not minified, `profileable`; `adb shell dumpsys package` shows
`pkgFlags=[ HAS_CODE ALLOW_CLEAR_USER_DATA ALLOW_BACKUP KILL_AFTER_RESTORE ]`
for both, no `DEBUGGABLE`. Both are compiled with `CompilationMode.Full()`.

The server. A launch whose intent carries `baton.macro.fixedServer`
starts `kotlin/benchmarks/macro/server`'s HTTP server on `127.0.0.1` in
the app's own process and fetches everything from it, so no run touches
the network and the same request gets the same bytes every run. Each
client gets the text recorded for its own query, as the store-level
comparison above reads them: the first page is
`spec/rickandmorty/characters-page-1.json` for Baton (686,254 bytes) and
`benchmarks/apollo-comparison/fixture-apollo.json` for Apollo (849,101
bytes); the second page (165,777 and 204,674 bytes), character 9's
episodes (125 and 173 bytes) and one avatar (39,323 bytes, served for
every character) were recorded once from the live API on 7 October and
are the server's assets. The sample's list query selects less than the
Fixture text answers, so both clients skip the rest of each page.

The marks. Both apps emit the same asynchronous trace sections
(`Sections`), read with `TraceSectionMetric`: the list's from the
response's first byte, as the server starts writing it, and from its last
byte, once the write returns, to the first draw of the list; the detail's
from the tap's click handler to the first draw of the header; the page
turn's from the tap on Next to the first draw of the second page's list;
and the client's construction on the main thread. A first draw is a
`drawWithContent` modifier on the list or the header, which also reports
the activity fully drawn at the first list, so `timeToFullDisplayMs` is
the time from launch to the frame with the list.

The scenarios, fifteen iterations each: a cold start with the app's data
cleared (`pm clear`); a cold start over the store a priming launch left on
disk; a tap on the ninth row, Agency Director, in a process that has just
shown the first page from an empty store; a tap on Next in the same state;
and the first page, from the warm store with its avatars loaded, flung
down and up twice (`FrameTimingMetric` and `FrameTimingGfxInfoMetric`).
Each cell is the median, then the minimum and maximum of the fifteen;
the ratio is Apollo Kotlin's median over Baton's, so above 1 Baton is
faster.

| Scenario, metric | Baton | Apollo Kotlin | Ratio |
|---|---|---|---|
| Cold start, empty store: first frame (`timeToInitialDisplayMs`) | 231.0 ms (212.1–238.9) | 207.5 ms (199.5–220.1) | 0.90× |
| Cold start, empty store: the list on screen (`timeToFullDisplayMs`) | 271.2 ms (260.5–281.8) | 314.2 ms (293.7–338.7) | 1.16× |
| Cold start, empty store: response's first byte to the list's frame | 57.9 ms (48.1–69.8) | 42.3 ms (27.4–52.5) | 0.73× |
| Cold start, empty store: response's last byte to the list's frame | 57.5 ms (47.6–68.1) | 42.0 ms (24.2–51.7) | 0.73× |
| Cold start, empty store: client construction | 2.18 ms (2.14–2.29) | 1.76 ms (1.68–2.07) | 0.81× |
| Cold start, warm store: first frame (`timeToInitialDisplayMs`) | 239.6 ms (226.4–266.6) | 209.3 ms (201.2–221.6) | 0.87× |
| Cold start, warm store: the list on screen (`timeToFullDisplayMs`) | 239.6 ms (226.4–266.6), the first frame | 272.1 ms (260.3–287.1) | 1.14× |
| Cold start, warm store: client construction | 2.10 ms (2.03–2.54) | 1.76 ms (1.71–2.50) | 0.84× |
| Tap a row to the detail's first frame, header from the store | 22.1 ms (12.3–27.5) | 33.2 ms (17.8–52.7) | 1.50× |
| Tap Next to the second page's first frame | 40.1 ms (19.0–44.4) | 56.1 ms (37.2–68.2) | 1.40× |

| Scrolling the list | Baton | Apollo Kotlin |
|---|---|---|
| Frame duration, CPU, P50 / P90 / P95 / P99 | 3.09 / 7.31 / 8.02 / 13.05 ms | 3.07 / 7.32 / 7.94 / 12.21 ms |
| Frame overrun, P50 / P90 / P95 / P99 | −10.38 / −6.38 / −5.43 / −1.72 ms | −10.37 / −6.17 / −5.36 / −2.80 ms |
| Frames per iteration (`frameCount`) | 135 (132–136) | 133 (130–136) |
| Janky frames (`gfxFrameJankPercent`) | 0.74% (0–0.75%), about one frame of 135 | 0.75% (0–1.47%), about one frame of 134 |
| gfxinfo frame time, 50th / 90th / 95th / 99th percentile | 5 / 10 / 11 / 13 ms | 6 / 10 / 11 / 12 ms |
| gfxinfo frames (`gfxFrameTotalCount`) | 135 (133–137) | 134 (131–137) |

An earlier run the same morning, from the build before `1ad451a`, which
timed the list from the response's last byte only, gave the same shape:
the list on screen from an empty store in 279.8 ms and 318.0 ms, from the
warm store in 241.1 ms (the first frame) and 271.2 ms, the response's last
byte to the list in 59.1 ms and 45.7 ms, the tap to the detail in 16.8 ms
and 33.8 ms, the page turn in 32.5 ms and 44.9 ms, and the scrolled
frames 3.10 and 2.96 ms at P50 and 7.33 and 7.41 ms at P90, Baton first
each time.

What each difference comes from, as far as these marks show:

- **The list from a warm store.** Baton's list is in the first frame: the
  handle's availability check reads what memory lacks from the image on
  the main thread before the first composition. Apollo's first frame is
  the spinner, since its cache is read off the main thread and the
  collected `watch()` starts at `null`; its list follows 63 ms later. The
  user sees the list 32 ms sooner with Baton.
- **The first frame.** Baton's first frame comes later in both cold
  starts, 23 ms with an empty store and 30 ms with a warm one. The
  construction of the environment and store is 2.2 ms against Apollo's
  1.8 ms, so that is not it; with an empty store the image holds nothing
  to read, so if the rest is the same, the image's read is the 7 ms
  between the two. The rest is not traced apart in this run.
- **The list from an empty store.** Baton's list is on screen 43 ms sooner
  from launch, although Apollo's first frame comes 23 ms sooner and Apollo
  goes from the response to the list's frame 16 ms faster. Launch to
  the response's first byte is 213 ms for Baton and 272 ms for Apollo:
  Apollo's request reaches the server about 59 ms later. These marks do
  not say where those 59 ms go; a cache-first query that asks the SQL
  cache before the network is the candidate, and the traces are kept.
- **The response to the frame.** Apollo turns the response into the
  list's frame in 42 ms, Baton in 58 ms. This is not the transfer: on the
  loopback interface the first-byte and last-byte sections differ by
  under a millisecond for both clients. It is also not what the
  store-level bench above would predict (6.4 ms against 44.6 ms into the
  store), since the sample's list query selects twenty characters' rows
  and headers out of the page, so neither client builds or normalizes the
  899-record graph here. Where Baton's 58 ms go in a cold process, between
  its ingest, its commit, the image's first write on its own thread and
  the first composition of the list, is not traced apart in this run.
- **Tap to the detail.** Both read the header from the store. Baton's
  header query resolves against the record the list already holds in
  the detail's first composition, so the header is in the detail's first
  frame, 22 ms after the tap. Apollo's collected `watch()` starts at
  `null`, so the detail's first frame is a spinner and the header follows
  once the cache read on a coroutine emits, 33 ms after the tap.
- **The page turn.** The second page's response, 166 KB and 205 KB, goes
  through each client as the first page's does; Baton is 16 ms ahead.
- **Scrolling.** The same. The rows are the same composables over data
  already read, and neither client is on the scroll path: the CPU time of
  a frame is 3.1 ms at the median and 7.3 ms at P90 for both, no frame
  misses its deadline at P99, and each run has about one janky frame of
  135.

Caveats: one device, one day, fifteen iterations; the server is in the
measured process and shares its CPU; the list query is the sample's, not
the Fixture's, so the store-level gap above does not appear here at its
size; a fling's end is not an accessibility event Compose sends, so each
scroll iteration waits out UiAutomator's 5 s timeout, idle time that adds
no frames. To run it again, on a phone with both apps and the test
installed (`gradle :samples:android:installRelease
:samples:apollo-android:installRelease :benchmarks:macro:installBenchmark`):

```bash
adb shell am instrument -w -r -e tests_regex '.*' \
  baton.macro/androidx.test.runner.AndroidJUnitRunner
```

## Unreleased, the verdict on the root — 2026-10-07

Revision: the working tree of the verdict change on top of `039aa2d`,
against `039aa2d` itself built the same way, run back to back, `--quick`
(three samples). Machine: Apple M1 Pro (MacBook Pro), macOS 26.5.2,
release build; load average 7, not a quiet machine, so read each row
against its neighbour from the same pair of runs.

The handle stores no phase: the root holds whether the store has the
operation's data and the verdict on it, settled by the store at the end of
a batch that changed a null, a link, an error or a deletion, by the handle's
generated walk, which the root asks for through a protocol
(`docs/decisions/the-verdict-is-the-roots.md`). The gate: the commit with a
retained `@throwOnFieldError` handle within the spread of the chain it
replaced, and the deterministic counts unchanged.

| Measurement | Before | Now |
|---|---|---|
| Commit of the errors, no handle retained | 141 µs | 141 µs |
| The same commit, a `@throwOnFieldError` handle retained | 1.01 ms | 958 µs |
| The commit that clears them, the handle retained | 784 µs | 745 µs |
| The same two, the root asking a closure the handle installed | | 1.19 ms, 965 µs |
| The same two, the judge answering sound without a walk | | 180 µs, 175 µs |

The counts in `benchmarks/counts.txt` did not change. The first shape,
a closure made in the handle's generic initializer and stored on the root,
cost the same walk about 200 µs more than the handle's own method did; a
protocol the handle conforms to, which the root holds weakly and asks,
costs what the chain cost. The mechanism without the walk is 35 µs over
the plain commit: the walk is the cost, as it was.

## Unreleased, an `@inline` fragment read as a value — 2026-10-06

Revision: the working tree of the `@inline` build on top of `500db24`, one
`--quick` run. Machine: Apple M1 Pro (MacBook Pro), macOS 26.5.2, release
build. Not a quiet machine; read each row against its neighbour from the
same run.

A fragment marked `@inline` compiles to a struct of its fields, built by
the spread's accessor in one call through the readers a lens's accessors
use (`docs/decisions/a-fragment-has-one-reading.md`). The value rows read
the 20 characters of the fixture page, 8 fields each (7 scalars and the
name behind a link), as the lens rows beside them do.

| Measurement | Lens | Value |
|---|---|---|
| Untracked read of 8 fields per row, per field | 34.9 ns | 41.6 ns |
| Tracked read, one row body of 8 fields, per field | 662 ns | 653 ns |

The value's 6.7 ns per field over the lens is the struct: the same eight
slot loads, then the strings retained into stored properties. Inside a
tracking body the registration dominates and the two are the same.

Generated code, measured on a fragment of 7 scalars and one link with one
field compiled both ways: 1,225 bytes and 19 lines as a lens, 1,832 bytes
and 43 lines as a value. The value's memberwise initializer and its
reading initializer are the difference; a lens has one accessor line per
field.

## Unreleased, the writer merges a record memory has not read — 2026-10-06

Revision: the working tree of the merge change on top of `89364b0`, one
`--quick` run each, the column before from `89364b0` built the same way.
Machine: Apple M1 Pro (MacBook Pro), macOS 26.5.2, release build. Not a
quiet machine; read each row against its neighbour from the same pair of
runs.

The writer merges the snapshot of a record memory has not read from the
image into the record's row, rather than replace the row with it
(`docs/decisions/the-image-is-sqlite.md`). The cost is one keyed read of
the old row per such record that has one, off the main actor; a record
without a row, as on a first launch, pays nothing. The write-behind rows
below rewrite 898 records the image already holds, from stores that never
read them, so every row is merged.

| Measurement | Before | Now |
|---|---|---|
| Commit into an empty store, image on (899 records), on the main actor | 696 µs | 689 µs |
| Write-behind of that commit, off the main actor, 898 rows merged | 1.11 ms | 1.62 ms |
| Write-behind of one changed record, merged | 49.0 µs | 52.0 µs |
| A launch's first write-behind of the fixture: aging, the names sweep and 898 rows merged | 1.29 ms | 1.88 ms |
| Hydration: the check reads 898 rows into an empty store | 2.51 ms | 2.54 ms |

The main actor's share of a commit and the read path are unchanged; the
merge adds about 0.6 µs per existing row to the writer.

## Unreleased, a plan's selections declared once — 2026-10-06

Revision: the working tree on top of `c8ca8cc`. Machine: Apple M1 Pro
(MacBook Pro), macOS 26.5.2, Swift 6.3.3, debug, one job. Not from
`BatonBenchmarks`: the generator of issue 34 writes a schema and a document
of S sections, a union, each holding C cards, a union, each holding M
metas, a union; `batonc` writes the operation, and `swiftc -c -wmo
-parse-as-library` compiles it with the shared file against the debug
`Baton` module. Time is wall clock, memory the compiler's maximum resident
set. The column before is the same file as the compiler wrote it at
`c8ca8cc`, one expression; at 4 x 10 x 5 it is the type check alone.

| S x C x M | Selections before | Declared now | Source now | Before | Now |
|---|---|---|---|---|---|
| 4 x 10 x 5 | 370 | 43 | 78 KB | 23.7 s, 3.20 GB | 1.06 s, 0.19 GB |
| 8 x 20 x 10 | 2,258 | 82 | 158 KB | not run; killed at 12 GB in the issue | 1.72 s, 0.24 GB |
| 8 x 40 x 10 | 4,498 | 142 | 273 KB | not run | 3.03 s, 0.30 GB |
| 10 x 50 x 20 | 12,022 | 184 | 359 KB | not run | 4.01 s, 0.36 GB |

The issue's workaround, each copy hoisted into its own declaration without
sharing, type-checks 10 x 50 x 20 in 31.7 s; sharing is what keeps the
plan linear in the document.

## Unreleased, a type's name matched by bytes — 2026-10-11

Revision: the working tree on top of `3c3296e`, one full run before and one
after the change, back to back. Machine: Apple M1 Pro (MacBook Pro), macOS
26.5.2, release build. Not a quiet machine; read the two rows against each
other.

An object under an interface or union names its type in `__typename`, and
the ingest took the type by making a string of the name and asking the
registry under its lock, once per object. The resolved plan now carries the
names of the types it lists as bytes, and an object of a listed type takes
its type from a comparison; an escaped name or one the plan does not list
still asks the registry. The entry ingests a search of 899 results, a third
of each of the union's three types, 51,944 bytes.

| Measurement | Best | Median |
|---|---|---|
| Ingest of 899 objects under a union, before | 541 µs | 561 µs |
| Ingest of 899 objects under a union, after | 508 µs | 510 µs |

About 37 ns an object, a string and a lock, out of 600; the row stays in
the suite as the union ingest's number.

## Unreleased, generated code per accessor — 2026-10-11

Revision: the working tree on top of `a59397d`, measured over the Swift
goldens under `compiler/src/tests/goldens` with the hostile-name corpus left
out, by the test `generated_accessors_stay_under_their_byte_budget`. The
figure is a property of the emitter, not of a machine.

0.1.0 measured 107 bytes of source per accessor line against a budget of 120
and fenced nothing; the compiler's tests now fence it, so a change to the
emitter that pads an accessor fails `cargo test` before it is blessed.

| Measurement | Value |
|---|---|
| Accessor lines in the goldens | 760 |
| Bytes of source per accessor line, without the newline | 106.1 (budget 120) |

## Unreleased, eviction in the image — 2026-10-11

Revision: the working tree of the eviction change on top of `0c61554`, one
`--quick` run. Machine: Apple M1 Pro (MacBook Pro), macOS 26.5.2, release
build. Not a quiet machine; read the row against the plain first use beside
it, from the same run.

An image over its size limit evicts the rows of launches before the last and
keeps the last launch's, where it used to delete the file
(`docs/decisions/the-image-evicts-by-launch.md`). The entry writes the
fixture's 898 characters in one launch and 899 assets in the next, then
opens a third time with a limit between one launch's rows and both.

| Measurement | Time | Rows |
|---|---|---|
| First use in the process (open, create, a read that misses) | 2.41 ms | none |
| Open of an image over its limit, evicting 898 rows and keeping 899 | 3.23 ms | the last launch's kept; 237,568 to 90,112 bytes |

The eviction costs under a millisecond over a plain open, the deletes and
the `VACUUM` together, for a file that keeps the last launch's data instead
of starting cold. Two counts in `benchmarks/counts.txt` fix the outcome:
`eviction-kept-the-last-launch 1`, `eviction-dropped-the-older-launch 1`.

## Unreleased, the log — 2026-10-11

Revision: the working tree of the log change on top of `477266f`, one
`--quick` run. Machine: Apple M1 Pro (MacBook Pro), macOS 26.5.2, release
build. Not a quiet machine; read the second row against the first, measured
back to back.

The environment logs value-free events
(`docs/decisions/the-environment-logs-value-free-events.md`); a commit logs
one `committed` event when a log is installed. The entry commits a one-field
change into the 899-record store with no log, then with a log that counts
every event; the suite's "reports" rows, which installed the three hooks the
log replaces, now install one counting log.

| Measurement | Best | Median |
|---|---|---|
| Commit into the 899-record store, one field changing | 1.04 µs | 1.08 µs |
| The same commit, a counting log installed | 1.00 µs | 1.00 µs |
| Into an empty store with the log set (899 records) | 908 µs | 911 µs |
| Same payload again with the log set | 132 µs | 135 µs |

The log's cost is below the noise of the machine: one closure call per
commit, and none when `log` is nil.

## Unreleased, mapped scalars — 2026-10-11

Revision: the working tree of the mapped-scalars change on top of
`c7d3e7e`, one `--quick` run of the read entries. Machine: Apple M1 Pro
(MacBook Pro), macOS 26.5.2, release build. Not a quiet machine: the
control entry, the untracked lens read, read 31.5 ns against 25.0 on the
lifetime step's quiet run, and the tracked row read 718 ns at the median
against 637; read the mapped entry against the string read beside it.

A mapped scalar converts the stored text at every read
(`docs/decisions/a-mapped-scalar-converts-at-the-read.md`). The entry reads
a `Decimal` field through its mapped accessor over the same 3,200 reads the
string entry makes.

| Measurement | Best | Median |
|---|---|---|
| Untracked lens read, per field (String) | 31.5 ns | 31.6 ns |
| Untracked mapped Decimal read, per field | 567 ns | 589 ns |
| Tracked read, a row body of 8 fields, per field | 636 ns | 718 ns |

A `Decimal` read costs about eighteen string reads, and about what a tracked
read of a field costs: `Decimal(string:locale:)` is the whole of it. This is
the number the decision's reopening line watches; a body that reads many
amounts pays it per amount per evaluation, since nothing is cached on the
record.

## Unreleased, the keys step — 2026-10-07

Revision: `fcec2ce`, the three commits of the keys step (`fee7273`,
`94569ee`, `fcec2ce`). The baseline column is `f1c1fdf`, the commit before
them, built in a worktree and run the same evening, one full run each,
back to back. Machine: Apple M1 Pro (MacBook Pro), macOS 26.5.2, Xcode
26.6, Swift 6.3.3, release build. Not a quiet machine: the load average
stood between 13 and 31 through both runs, and the control entry, the
untracked lens read, read 26.1 ns against 25.1 on the lifetime entry's
quiet run. Read the numbers here against the baseline column, not against
the entries below.

The store numbers the keys its session renders, frees them with its
collector and forgets them at its end; the image sweeps its names with its
rows. Two entries changed definition in this step, because a change set is
now resolved for one store: "into an empty store" makes the store and its
change set in the setup and times the commit alone, where it timed
`Store().commit(changes)` of one change set shared by every store; and
"bytes a row holds" makes and drops the change set inside the measurement,
so a record's key string counts as the record's, 64 bytes a row.

### The gates

| Measurement | `f1c1fdf` | This step | The gate |
|---|---|---|---|
| Root field with a variable argument, untracked read | 31.5 ns (32.8) | 32.8 ns (33.1) | 31.6 ns at the median, set on a quiet machine |
| A commit of one lookup of a new id, at the session's start | 1.88 µs (2.08) | 1.33 µs (1.46) | 2.04 µs |
| The same at the session's end | 2.25 µs (2.62) | 2.12 µs (2.33) | 2.04 µs |
| The newest root field with an argument, untracked, at the start | 36.9 ns (37.0) | 36.8 ns (38.0) | |
| The same at the end, after 50,000 lookups and 500 pages | 51.5 ns (53.8) | 52.2 ns (52.5) | |
| Keys numbered on `Query`: at the start, at the end, after a collection with no roots | 469, 50,672, kept for the process | 0, 50,202, 0 | the size at the start |
| The same on `Character` | 55, 556, kept | 0, 500, 0 | |

Best (median). The read gate's absolute number is met by neither tree on
this machine; relative to the baseline the read did not move, 0.3 ns at
the median, inside a loaded run's spread. The lookup commit is under the
gate at the start and under the baseline at the end. The table is empty
once a long session's roots have left and a collection ran, where the
process kept every key before.

### What the step costs elsewhere

| Measurement | `f1c1fdf` | This step |
|---|---|---|
| Resolve the fixture plan for a page, per resolution | 676 ns (729) | 878 ns (889) |
| A pass over one root reaching 50,004 records | 2.49 ms (2.77) | 2.68 ms (3.10) |
| A pass over 300 roots reaching one record each | 31.7 µs (31.8) | 36.0 µs (36.3) |
| A pass that keeps none of 50,000 records | 31.9 ms (34.3) | 30.0 ms (36.4) |
| `loadNext` with no body reading the nodes, per page of 50 | 195 µs (1.19 ms) | 190 µs (1.18 ms) |
| `loadNext`, a body reading every node, per page of 50 | 273 µs (1.53 ms) | 222 µs (1.80 ms) |
| Hydration: the check reads 898 rows into an empty store | 1.83 ms (1.94) | 1.99 ms (2.21) |
| Write-behind of the fixture's commit, off the main actor | 1.12 ms (1.27) | 1.18 ms (1.41) |
| A launch's first write-behind of the fixture: the aging, the names sweep and 898 rows | | 1.43 ms (1.59) |
| 5,000 rows into an empty store, keys like `labels` | 4.30 ms (4.81) | 3.14 ms (3.32), new definition |
| The same, keys like `labels(first: 3)` | 4.29 ms (4.85) | 3.14 ms (3.35) |
| The same, keys like `labels(first: $count)` | 4.92 ms (5.49) | 3.43 ms (3.61) |
| Bytes a row holds, the three kinds in that order | 356, 356, 452 | 420, 420, 516, new definition |
| Into an empty store (899 records) | 893 µs (947) | 628 µs (646), new definition |

A resolution pays a hold and two locks per rendered key: 200 ns on the
fixture's plan. A pass frees keys after its sweep: 4 µs over 300 roots,
and a walk of the records that kept entries under freed numbers when there
are any. The names sweep and the aging together cost a launch's first
write-behind a quarter of a millisecond over 898 rows; the table of names
is bounded by the rows. By shape, every key with arguments the store's,
would have kept `labels(first: 3)` in the sorted list: 96 bytes a row and
15% on 5,000 rows under either definition. It is not chosen.

## Unreleased, the lifetime step — 2026-10-06

Revision: `e93ea3d` with the two changes this entry's last table names,
which land in the commit after it. Machine: Apple M1 Pro (MacBook Pro),
macOS 26.5.2, Xcode 26.6, Swift 6.3.3, release build. One run on a quiet
machine; the ground entry below is the "before".

The store owns the roots, the release buffer and the collector since this
step, and collects when a root left or a commit dropped a link, once per
turn of the main actor. The age is the root's, stamped by the commit.

### The collector

| Measurement | Best | Median | The ground entry |
|---|---|---|---|
| A pass over one root reaching 50,004 records | 2.49 ms | 2.80 ms | 2.65 ms (2.69) |
| A pass over 301 roots, 50,304 records | 2.56 ms | 2.76 ms | 2.68 ms (2.75) |
| A pass over 300 roots reaching one record each | 33.1 µs | 33.5 µs | 49.3 µs (52.0) |
| A pass that keeps none of 50,000 records | 25.2 ms | 26.7 ms | 21.0 ms (22.7) |
| 42 pages scrolled, release buffer of 10, the pass | 0.18 ms | 2.71 ms | 0.18 ms (2.53) |
| Hydration: the check reads 898 rows into an empty store | 1.58 ms | 1.70 ms | 1.60 ms (1.73) |

### What the schedule costs a page

| Measurement | Best | Median | The ground entry |
|---|---|---|---|
| `loadNext` with no body reading the nodes, per page of 50 | 192 µs | 1.12 ms | 165 µs (205) |
| `loadNext`, a body reading every node, per page of 50 | 228 µs | 1.47 ms | 196 µs (529) |

A page's fetch dates its operation's root, which waits in the release
buffer, as Relay's does; from the eleventh page on each page pushes an
older page's root out, and a root that left runs a pass on the next turn:
about a millisecond over the connection bench's 4,200 records, paid inside
the next page's await. A list that only grew, a page appended or prepended,
drops no link and schedules nothing of its own since this entry. The
decision reopens the schedule, not the owner, when a pass misses a frame at
a store size the project supports; at 50,000 records a pass is 2.8 ms.

### The read, and the fences

| Measurement | Best | Median | The ground entry |
|---|---|---|---|
| Untracked lens read, per field | 25.0 ns | 25.1 ns | 25.8 ns (25.9) |
| Tracked read, a row body of 8 fields, per field | 603 ns | 637 ns | 635 ns (662) |
| Commit into an empty store, 899 records | 645 µs | 687 µs | 648 µs (685) |
| The same payload again | 124 µs | 125 µs | 126 µs (130) |
| Check the fixture plan against the store | 118 µs | 118 µs | 113 µs (113) |

The read had risen to 33.2 ns at the median after the heal landed: the
report of a missing slot and the heal's call were inlined into every
accessor with the reader that calls them. Out of line, as the record's
cold lookups already are, the read is 25.1 ns again.

## Unreleased, the ground step — 2026-10-05

Revision: `2dfae99` with the benches this entry adds, which land in the
commit after it. Machine: Apple M1 Pro (MacBook Pro), macOS 26.5.2, Xcode
26.6, Swift 6.3.3, release build. One run on a quiet machine, so these are
the "before" numbers the plan's spine steps are measured against, not a
record to beat; the entry below took three runs.

No iPhone 12-class device was at hand. The three decision records whose
reopening lines wait for a phone's number say so since this entry.

### Collection, for the lifetime step

| Measurement | Best | Median | Notes |
|---|---|---|---|
| A pass over one root reaching 50,004 records | 2.65 ms | 2.69 ms | marks every record, sweeps none |
| A pass over 301 roots, 50,304 records | 2.68 ms | 2.75 ms | the 300 small roots add 60 µs |
| A pass over 300 roots reaching one record each | 49.3 µs | 52.0 µs | |
| A pass that keeps none of 50,000 records | 21.0 ms | 22.7 ms | a release buffer of zero: what an environment's end will do, above a frame of 16.7 ms |
| 42 pages scrolled, release buffer of 10, the pass | 0.18 ms | 2.53 ms | worst 3.00 ms, as the entry below |

### The re-evaluation a commit runs, for the handle step

The fixture under `@throwOnFieldError`, 899 records, with 20 field errors
landing on the rows' `image`.

| Measurement | Best | Median | Notes |
|---|---|---|---|
| Commit of the errors, no handle retained | 135 µs | 136 µs | |
| The same commit, a `@throwOnFieldError` handle retained | 930 µs | 939 µs | the commit settles the handle's phase: one walk of the selection's field errors |
| The commit that clears them, the handle retained | 713 µs | 716 µs | |
| The verdict: field errors of the operation's own selection, none present | 567 µs | 567 µs | what a derived phase would compute on a read |
| The verdict, 20 errors present | 785 µs | 786 µs | |
| The verdict, in a body's tracking scope | 4.50 ms | 4.56 ms | every slot the walk reads registers |

The handle step's gate proposed a read of the phase under 50 µs on the
largest strict operation in `spec/`. On this one it is 567 µs untracked
and 4.56 ms tracked: the gate fails as proposed, and the step parks at its
first half, the fetch as a value, unless the verdict is made to cost
less than a walk of every record.

### A commit with the report closures set, for the report

| Measurement | Best | Median | Without the closures |
|---|---|---|---|
| The fixture into an empty store, the three report closures set | 625 µs | 633 µs | 648 µs (685) |
| The same payload again, the closures set | 126 µs | 127 µs | 126 µs (130) |

Setting the closures costs a commit nothing: a commit calls none of them.

### The long session, at 50,000 lookups

The bench's session is 50,000 root lookups by id and 500 pages after
cursors, where the entry below's was 2,000.

| Measurement | Best | Median | At 2,000 lookups (the entry below) |
|---|---|---|---|
| Root field with a variable argument, untracked read, at the start | 38.4 ns | 39.2 ns | 36.3 ns (37.0) |
| The same after 50,000 lookups and 500 pages | 54.3 ns | 54.8 ns | 45.4 ns (55.7) after 2,000 |
| A commit of one lookup of a new id, at the session's start and end | 1.83 µs, 2.00 µs | 2.00 µs, 2.21 µs | 1.75 µs, 1.88 µs (1.92, 2.04) |
| A commit of a page of 10, the session's first 50 and last 50 | 20.0 µs, 202 µs | 29.8 µs, 211 µs | 19.6 µs, 196 µs (29.8, 211) |
| 50,000 new characters given a field numbered before the session | 42.6 ms | 48.7 ms | +18.3 MB |
| 50,000 new characters given a field numbered after it | 43.9 ms | 46.1 ms | +34.3 MB |

The session interns keys on `Query` from 469 to 50,672, one per id looked
up, for the life of the process; the root holds 50,202 values, one per
key; and the footprint grows by 22.7 MB over its 61,308 records. The
collector now takes a root's entry with the record it swept, which this
session, retaining everything, never exercises; the table of the process
keeps every key either way until the session-keys step.

## Unreleased at 2ba3d18 — 2026-10-04

Revision: 2ba3d18, the review plan's last changes (#28, #29), before a
release. Machine: Apple M1 Pro (MacBook Pro), macOS 26.5.2, Xcode 26.6,
Swift 6.3.3, release build. Same fixture and image setup as the entry
below. Three runs on a quiet machine; best of the three, median of the
three medians.

### Keys with arguments, and a long session

| Measurement | Best | Median | Notes |
|---|---|---|---|
| 5,000 rows into an empty store, three fields under keys like `labels` | 4.03 ms | 4.10 ms | 356 bytes a row |
| The same, keys like `labels(first: 3)` | 4.02 ms | 4.07 ms | 356 bytes a row: a key the compiler emits as a constant is numbered among its type's dense values |
| The same, keys like `labels(first: $count)` | 4.65 ms | 4.74 ms | 452 bytes a row: a key rendered from a variable is kept in the record's sorted list |
| Root field with a variable argument, untracked read | 30.6 ns | 31.6 ns | 28.1 ns in the entry below, when every key was dense |
| A session's newest root field with an argument, untracked, at its start | 36.3 ns | 37.0 ns | |
| The same after 2,000 lookups and 500 pages | 45.4 ns | 55.7 ns | a search among the root's 2,000-odd keys with arguments |
| A commit of one lookup of a new id, at the session's start and end | 1.75 µs, 1.88 µs | 1.92 µs, 2.04 µs | |
| A commit of a page of 10, the session's first 50 and last 50 | 19.6 µs, 196 µs | 29.8 µs, 211 µs | the merge builds a set and an array of every edge already merged |
| 2,000 new characters given a field numbered before the session | 1.54 ms | 1.55 ms | +0.2 MB |
| 2,000 new characters given a field numbered after it | 1.61 ms | 1.62 ms | +1.0 MB; before keys with variables were kept apart, 5.86 ms and +28.2 MB, measured at that commit |

The session interns keys on `Query` from 169 to 2,372 and on `Character`
from 55 to 556, for the life of the process, and the footprint grows by
20.2 MB over its 13,308 records.

### The paths the entry below measured

| Measurement | Best | Median | The entry below |
|---|---|---|---|
| Response bytes into a change set | 2.88 ms | 3.06 ms | 2.87 ms (2.88) |
| Commit into an empty store, 899 records | 638 µs | 662 µs | 632 µs (653) |
| Commit of the same payload again | 126 µs | 126 µs | 124 µs (125) |
| Untracked read, per field | 25.0 ns | 25.9 ns | 25.0 ns (30.4) |
| Tracked read, a row body of 8 fields, per field | 603 ns | 638 ns | 574 ns (608) |
| Field selected on an interface, untracked | 22.2 ns | 22.3 ns | 22.2 ns (22.3) |
| Spread with `@arguments`, the fragment's lens | 10.2 ns | 10.4 ns | 10.2 ns (10.4) |
| The check of the fixture plan | 109 µs | 110 µs | 107 µs (110) |
| An optimistic `@appendEdge` on 50 edges: apply, revert | 5.79 µs, 4.67 µs | 5.96 µs, 4.79 µs | 5.79 µs, 4.62 µs |
| A commit that deletes one record from 8,965 | 2.13 ms | 2.15 ms | 2.10 ms (2.21) |
| Hydration: the check reads 898 rows | 1.56 ms | 1.68 ms | 1.57 ms (1.59) |
| A launch, open and hydrate at once | 4.01 ms | 4.76 ms | 3.84 ms (4.06) |
| A launch, hydrate after the image opened | 1.78 ms | 1.90 ms | 1.76 ms (1.92) |
| A multipart response of 978 KB, in 16 KB chunks | 482 µs | 491 µs | 483 µs (489) |
| Collection pass over about 9,000 records | 0.18 ms | 2.58 ms | 0.17 ms (2.4) |
| Scroll footprint at page 42 | +4.4 MB | — | +4.3 MB |

What it means: the plan's last changes move the paths a screen takes by no
more than the spread between runs, a few percent, except a read through a
key with a variable, which pays a search: 31.6 ns against 28.1 ns. In
exchange a long session no longer widens every record of a type by the keys
its cursors and ids made. A field first used after 2,000 lookups and 500
pages costs 2,000 records 1.0 MB, where it cost 28.2 MB, and a key with
constant arguments costs what a key without them costs.

## Unreleased at 418ceff — 2026-10-03

Revision: 418ceff, the improvements after 0.6.0, before a release. Machine:
Apple M1 Pro (MacBook Pro), macOS 26.5.2, Xcode 26.6, Swift 6.3.3, release
build. Same fixture, same image setup as 0.6.0. Three runs of each tree,
alternating, the same evening; the 0.6.0 column is the 0.6.0 tree run again
that evening, so the two columns share the day. Best of the three runs,
median of the three medians.

### The paths 0.6.0 measured, same day

| Measurement | 0.6.0 best (median) | This revision best (median) | Notes |
|---|---|---|---|
| Response bytes into a change set | 2.74 ms (2.89) | 2.87 ms (2.88) | the ingest now groups each record's entries off the main actor, one per slot, which the commit used to do |
| Commit into an empty store, 899 records | 1.36 ms (1.42) | 632 µs (653) | |
| Commit of the same payload again | 185 µs (190) | 124 µs (125) | a list that did not change allocates nothing |
| Untracked read, per field | 28.3 ns (28.3) | 25.0 ns (30.4) | one run read 25.0 ns and two 30.4 ns, with nothing else moving between them |
| Tracked read, a row body of 8 fields, per field | 527 ns (569) | 574 ns (608) | exact channels: one key path per slot, built on first use |
| The check of the fixture plan | 105 µs (105) | 107 µs (110) | |
| `@catch` read of a field without an error | 123 ns (127) | 83.1 ns (83.4) | |
| `satisfied` of a lens with one `@required` field | 28.6 ns (29.8) | 20.0 ns (20.2) | |
| `nodes` of 2,100 merged edges, untracked | 123 µs (127) | 84.9 µs (85.3) | one pass, no array of anchors in between |
| `nodes` of 2,100 merged edges, tracked | 1.12 ms (1.24) | 1.16 ms (1.25) | |
| Commit into an empty store with the image on | 1.47 ms (1.50) | 721 µs (746) | |
| Write-behind of that commit, off the main actor | 1.15 ms (1.17) | 1.15 ms (1.16) | |
| Write-behind of one changed record | 45.9 µs (49.7) | 43.2 µs (46.6) | |
| Hydration: the check reads 898 rows | 1.69 ms (1.72) | 1.57 ms (1.59) | |
| The check once the records are in memory | 105 µs (106) | 106 µs (107) | |
| A launch, open and hydrate at once | 3.89 ms (4.24) | 3.84 ms (4.06) | |
| A launch, hydrate after the image opened | 1.76 ms (1.84) | 1.76 ms (1.92) | |
| First use in a process: open, create, a read that misses | 2.74 to 2.77 ms | 2.68 to 2.95 ms | one shot per run; 0.6.0's entry recorded 1.6 to 2.3 ms on its own day |
| Collection pass over about 9,000 records, from 10 roots | 0.20 ms (2.9), worst 3.7 | 0.17 ms (2.4), worst 3.2 | the lifetime bench below |
| Scroll footprint at page 42 | +4.1 to +4.3 MB | +4.3 MB | one run read +0.5 MB, a resident-size reading after the system reclaimed pages |

0.6.0's bench printed the image's file alone, 167,936 bytes; this
revision's prints the file and its write-ahead log together, 4,440,384
bytes, because the log is what the disk holds until a checkpoint.

### New measurements

| Measurement | Best | Median | Notes |
|---|---|---|---|
| Resolve the fixture plan for another page | 676 ns | 678 ns | 8.5 µs before the plan kept its resolutions |
| One field changed, 20 rows observing their name, one commit | 127 µs | 128 µs | one notification; 0.6.0 timed two commits and no observer here (368 µs) |
| A root field with a variable argument, untracked | 28.1 ns | 28.2 ns | 232 ns before keys with variables resolved once per owner |
| The same, tracked, one body per read | 952 ns | 981 ns | |
| A field selected on an interface, untracked | 22.2 ns | 22.3 ns | 56 ns before abstract slots |
| A spread with `@arguments`, the fragment's lens | 10.2 ns | 10.4 ns | 453 ns before, for the read and one variable of the child's scope |
| Apply an optimistic layer, 20 rows observing | 3.00 µs | 3.21 µs | one notification |
| Revert it | 2.21 µs | 2.33 µs | one notification |
| Commit the fixture under the layer | 126 µs | 127 µs | no notification |
| Resolve the layer with the server's answer | 1.21 µs | 1.38 µs | no notification |
| Ingest a 64-byte mutation payload | 2.42 µs | 2.50 µs | 4.5 µs before reservations followed the response's size |
| Commit it into the 899-record store, one field changing | 791 ns | 834 ns | |
| A 69-byte subscription frame, its envelope read | 334 ns | 375 ns | 2.21 µs before the scanner stood apart from the cursor |
| Ingest with 20 field errors | 2.89 ms | 2.89 ms | 20 placed, 20 uncaught |
| Commit the errors, 20 rows observing their image | 151 µs | 151 µs | 20 notifications |
| Commit that clears them | 149 µs | 150 µs | 20 notifications |
| A commit that deletes one record from 8,965 | 2.10 ms | 2.21 ms | the pass that tells every slot linking to it |
| Wakes of a body reading one root field while 64 others are written | 0 | — | |
| `loadNext` with no body on the nodes, per page of 50 | 167 µs | 218 µs | page 2 about 200 µs, page 21 about 200 µs, page 41 230 to 340 µs |
| `loadNext` with a body reading every node, per page of 50 | 185 µs | 556 µs | page 2 185 to 230 µs, page 21 516 to 558 µs, page 41 0.88 to 1.16 ms |
| An optimistic `@appendEdge` on a connection of 50 edges: apply | 5.79 µs | 5.96 µs | |
| Revert it | 4.62 µs | 4.71 µs | |
| A multipart response of 20 parts, 978 KB, parsed in 16 KB chunks | 483 µs | 489 µs | 14.6 ms before the reader scanned whole chunks |
| The same response read through `URLSessionTransport` | 1.10 ms | 1.38 ms | 6.1 ms before the transport read its data task's chunks |

The "before" figures in the notes were measured at the commit that made
the change, on this machine, alternating the two builds; each is in that
commit's message and in the changelog.

What it means: a commit of the fixture costs half of what it did, and a
read through a key with variables, an interface or a spread with arguments
costs what a plain read costs. A tracked read costs about a tenth more,
the price of a channel per slot instead of channels shared by slots.

A correction to 0.4.0, which said a page costs the main actor a merge
"whatever the number of pages already merged". Split by page, with no body
reading the nodes, a page costs about the same at page 21 as at page 2 and
up to two thirds more at page 41: the merge builds a set and an array of
every edge already merged. A body that reads every node pays for reading
them again on every page, which grows with the connection, to about 1 ms
at page 41. The merge is left as it is until a phone shows it in a frame.

## 0.6.0 — 2026-10-03

Revision: the 0.6.0 tree. Machine: Apple M1 Pro (MacBook Pro), macOS 26.5.2,
Xcode 26.6, Swift 6.3.3, release build. Same fixture as 0.1.0. The image is
a SQLite file in the temporary directory of the internal disk, through the
system's SQLite 3.51.0, with the page cache warm.

The earlier numbers, same day as 0.5.0's: ingest 2.76 ms (2.76), commit into
an empty store 1.37 ms (1.35), same payload again 183 µs (187), one field
changed 368 µs (376), untracked read 28.3 ns (29), tracked read 544 ns (536),
check 105 µs (126), the optimistic cycle 413 µs (413), a connection page
285 µs best (320), the scroll footprint +4.4 to +4.7 MB (+4.7). Nothing on
the paths a store without an image takes moved; the check is the 0.3.0
figure again.

### Persistence: the fixture's 898 records and the root, through the image

| Measurement | Best | Median | Notes |
|---|---|---|---|
| Commit into an empty store with the image on (899 records) | 1.49 ms | 1.55 ms | 1.37 ms without: the commit takes a snapshot of each changed record for the writer |
| Write-behind of that commit, off the main actor | 1.16 ms | 1.25 ms | 898 rows encoded and one transaction; the file is 168 KB, against 686 KB of response |
| Write-behind of one changed record | 46 µs | 50 µs | the hop to the writer and back included |
| Hydration: the check reads 898 rows into an empty store | 1.72 ms | 1.78 ms | 1.9 µs a record: a lookup by key, a decode, a fill, inside one read transaction |
| The check once the records are in memory | 105 µs | 106 µs | the image is not consulted |
| Hydration right behind a commit of 899 records | 2.87 ms | 3.00 ms | the read writes the pending batch first, so it never sees less than memory knew |
| First use in a process: open, create the tables, a read that misses | 2.1 ms | — | one shot; 1.6 to 2.3 ms across runs |
| A launch in a new process, the store asked the moment the image's handle exists | 4.68 ms | 5.36 ms | the main actor waits for the open: SQLite's first use, the file, the launch's own bookkeeping, then the 898 rows |
| A launch in a new process, the store asked after the image has opened | 1.78 ms | 1.87 ms | the open ran off the main actor, as it does when an app makes its environment before its first view |

What it means: a screen an earlier launch fetched is in the store 1.8 ms
after its handle asks, with nothing from the network, when the app made its
environment early enough for the file to open on another thread, and under
5 ms when it did not. Hydration costs a third more than committing the same
records from a response (1.72 ms against 1.37 ms): that third is the image.
Keeping the image costs a commit a tenth of a millisecond on the main actor
and a millisecond off it. A read that lands behind a write waits for it,
which is the one place the main actor meets the disk's writer.

The sample, launched twice against the public API: the first launch left 41
rows, one root field and one fetch time in its image; the second read all 41
(their generation moved from 1 to 2) before its refetch landed.

Caveats: a Mac, not a phone, and a warm page cache: flash latency on a cold
launch is not in these numbers, and the roadmap's exit asks for them on an
iPhone 12-class device.

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
