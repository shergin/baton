# How a fast store stays honest

A normalized store is a long chain of clever steps: a one-pass tokenizer,
driven by a plan; storage keys interned to slots; records shared by many
operations; optimistic overlays, rebased on every commit; a persisted image,
read back on the next launch; and strings kept as byte ranges until
something needs them.

Each step is a place to lose a value, to merge two records that are not the
same thing, or to show one operation's data through another's selection. The
clients that broke in production broke here: identity without stable keys,
cache misses after a key-generator change, and stale data served as fresh.

Speed work is where a store earns distrust. Baton's answer is not to go
slower, but to make every fast path prove it gives the same answer as the
slow one, and to publish the proof.

## The response is the oracle

For data this client fetched, the truth is the response as it arrived. That
is the whole rule. A value may pass through the ingest, the interned slots,
an optimistic overlay, or the image. Reading it through a lens must equal
reading the raw response at the same path. Anything faster than the naive
reading has to reproduce it exactly. A fixture proves that it does ([the
principle](../principles/response-is-the-oracle.md)).

A naive reference reader exists only to be the oracle. It walks a response's
JSON, as `JSONSerialization` reads it, by the same resolved plan a lens
would follow, and walks the store's records by the same plan. The two walks
must yield the same leaves, for every response in the specification that has
data and a document that reads it.

They are compared after the commit, from the image in a second store over
the same file, and under an optimistic layer that overrides one leaf, and
again after that layer is reverted. For a deferred or streamed response,
they are compared as its first part, with the later parts merged in at their
paths.

The opposite failure is to trust the chain because each step was tested in
isolation. The bugs are between the steps. The oracle is the only test that
spans them.

## The fixtures are server responses, not tests

The specification under `spec/` holds the files no language owns: the
schemas, the authors' documents with their client directives, the recorded
responses, the records a store must hold after each one, and the reads a
generated lens must answer ([the specification](../../spec/README.md)).

Beside each response the oracle reads, a store dump freezes what the commit
must produce: every record by key, links written as Relay writes them,
sorted, one record a line.

Scripts freeze behaviour over time: phases and fetches, which commits notify
which slots, lifetime through a release buffer, an optimistic layer applied,
resolved, and reverted, connection pages merged, the availability check
across a relaunch, the heal, and a stream growing in its slot. A list of
malformed responses says what outcome each must have.

The rule of the project is that these are server responses, not tests. A
change to the store, the tokenizer, or the record layout is frozen under
them, and none is edited to fit code. A reviewed change to identity or layout
rewrites the dumps through one command, in a commit that says so.

That is why the store's internals could change release after release in the
project's first two weeks: slots numbered by the process, the change set
reshaped, and strings kept as bytes. The answer to any read did not change.

Both runtimes pass the same files. The Kotlin runtime's first milestone was
every case's dump matching byte for byte, before it had a lens, a handle, or
a transport. The scripts run on it through the same scripted transport the
Swift tests use.

## Relay's own tests, measured against

Relay's runtime tests state, for a document, variables, and a payload, the
records Relay's store holds afterwards. A harvest records those calls under
Relay's own test suite and translates the records into Baton's keys. Baton's
store can then be compared with Relay's, on inputs nobody here chose.

The first harvest of the normalizer's tests gave 60 cases: 13 where Baton
agreed, 10 where it did not, and the rest using features Baton does not
have, or a store the test seeded by hand.

The decision was to measure, not obey ([the
decision](../decisions/relays-tests-are-measured-not-obeyed.md)). A case
Baton disagrees with carries a status, a note saying how the two differ,
and, once decided, what is to be done. It runs as a known issue and fails
when it starts passing, so a status is revisited rather than parked.

Where GraphQL does not specify the behaviour, Baton documents it and copies
Relay, unless that costs performance. A test that seeded its store by hand
is harvested as the response the seeded store stands for, and kept only when
Relay, normalizing that response into an empty store, answers as it did on
the seeded one. Baton is compared with Relay on a response, never on a store
built by hand. The `@stream` cases of that harvest compile and pass on both
runtimes since 0.16.0.

## Honest data is part of the same rule

Nullability is what the schema says. A non-null field is a non-optional
property. A nullable one is optional. The lens types follow the schema
exactly, so product code stops handling permutations that never happen, and
stops pretending a value is there when it is not.

`@required` moves a null to where the product wants it, `@catch` turns a
field's error into a `Result`, and `@throwOnFieldError` fails the operation
or the spread. Field errors are stored beside the field, in memory and in the
image, so a cached read sees the same error the network read saw. The
fixtures hold responses with errors on them.

Missing data is the one case the types cannot express, and it is never
invented. It arises only when another operation retargets a link to a record
fetched with fewer fields. Then a lens returns the type's zero value for
that read, the environment logs a `missing` event naming the record and the
field, and the owning operation is marked stale and refetched once. A debug
build is loud about it.

A server response that omits a field the operation selected fails the fetch
as malformed, rather than leaving a hole. The principle has the list of
small lies clients tell, and the mechanism that refuses each ([Honest
data](../principles/honest-data.md)).

## Claims are measured

Every advertised number has a bench behind it.
[BENCHMARKS.md](../../BENCHMARKS.md) records it with the revision, the
machine, the OS, and the date. The file is appended to, and never edited. A
claim without a bench does not ship.

When a plan proposed a gate of 50 µs for a derived verdict, and the bench
measured 567 µs untracked, the step parked at its first half, and the file
says so. When a closure stored on a root cost the collection walk 200 µs
more, it was refused and recorded.

CI gates structure rather than wall-clock time, because wall-clock time
depends on the machine. It gates the bytes of generated code per accessor
line, a file of deterministic counts such as the notifications a commit
sends, and bounds on the samples' type-checking time. It also reports public
API breakage against a tagged release, in the log, and not yet enforced.
Before 1.0 a breaking change is expected, and listed in the changelog.

The benches catch regressions the tests cannot. When the heal was built, the
untracked lens read rose from 25 ns to 33 ns. The report of a missing slot,
and the heal's call, had been inlined into every accessor. The bench
noticed. The call went out of line, and the read is 25.1 ns again.

A regression in the collection walk was bisected to its commit and recorded
under its own heading. A collection pass's median, 3.8 ms over about 9,000
records on an M1 Pro, stands in the file as the trigger that would reopen
the decision to run it on the main actor.

## The build that finds what the tests miss

Two more habits belong here, because they found real defects. Tests run in
release builds as well as debug. The optimizer merges identical getters, and
the key paths that serve as invalidation channels then collide. The spike
that measured the design found exactly that. The rule is written into the
project's instructions.

Generated code is also compiled against a corpus of hostile schema names:
fields spelled like keywords, and types named like generated members. A
sweep runs that in CI, so a schema that calls a field `init` does not find
the bug in production.

## What this buys an adopter

An adopter gets a store that is fast because it skips steps, and a proof,
for every skipped step, that the answer did not change. A second runtime is
held to the same files, so the Android app and the iOS app normalize the
same response into the same records and surface the same error in the same
place.

There is a record of every number, with what it was measured on, and the
harness to rerun it, and a vocabulary for what the store does when something
is wrong: stale, failed, missing, in error. Each is a value a view can read,
rather than a surprise it cannot.

Every claim can be checked. That is the second of the three commitments in
[the vision](../vision.md), and the one that lets the other two be believed.
