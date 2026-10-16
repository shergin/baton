# Settled stays settled

A library's claims are worth exactly what the process behind them would do
if a claim were false. Baton makes strong ones. Cached data in the first
frame. One re-render per changed field. A response in the store in
milliseconds. Two runtimes with one behaviour.

This page is about the process, because the process is what you are actually
betting on. It has seven habits. Each has the mechanism that fails when the
habit is dropped.

## Research first, and an honest verdict

Before a line was written, the GraphQL client field was read across native,
web, and cross-platform, and so were the data layers that large apps built
for themselves. [The acknowledgements](../../ACKNOWLEDGEMENTS.md) are the
record. Each project named there taught this one something specific, and the
line says what.

The verdict of that reading was not flattering, and it was kept. No
maintained native client ships the combination Baton is. The public asks for
its pieces are few ([the comparison](../comparison.md)). The demand that
sustains the project is the owner's own products, whose web clients run
Relay ([the record](../decisions/relay-front-end.md)). [The
vision](../vision.md) says the rest. Adoption may follow, and is never
chased. No parity race. No feature bazaar.

A project that knows why it exists can refuse things. Most of what follows
is refusing.

## Principles with a mechanism each

Eight principles constrain every decision. A fragment is a lens. The store
is the UI's state. The response is the oracle. The compiler decides. Honest
data. What earns a concept. Relay's words. Two runtimes and one compiler.

Each file has the same shape. The failure the principle avoids. The idea.
The consequences. What it is not. A last section, "Spelled today", that
names the types and may rot, while the rest must not.

The rule behind the shape is that a principle without a mechanism that fails
when it rots is a wish. So the runtime has no GraphQL parser, and a check in
CI limits what the runtime may import. A lens holds one anchor and nothing
else, and a test asserts its size. A commit's notifications equal the fields
that changed, and a count in CI diffs it.

## Decisions with the condition that reopens them

Choices made among real alternatives live in [decisions/](../decisions/).
Fifty-six records at this writing, one file each, all the same shape. A
status line, with the date, the principle served, and what would reopen it.
The context. The decision. The evidence. What was not chosen.

The reopening line is the part that matters. The image is SQLite, and the
line says: reopen if a measurement on a phone shows the engine, not the
records, keeping a cached screen out of its first frame ([the
record](../decisions/the-image-is-sqlite.md)). Collection runs on the main
actor, and the line names the device class and the frame budget that would
move it ([the
record](../decisions/the-check-and-collection-run-on-the-main-actor.md)). A
retention budget per type was refused, and the line says "reopen a rule per
type never" ([the record](../decisions/the-image-evicts-by-launch.md)).

Settled stays settled unless new evidence arrives. A record that is
overtaken is not edited. It is superseded, says so in its status line, and
stays, so the history reads as it happened. Lookups were superseded whole.
The derived phase, in part. Taste is not relitigated.

When a review of 0.6.0 proposed that the compiler should write slot numbers
into generated code, the answer was a record explaining why the process
numbers them instead, with the measurement. That record is public ([the
record](../decisions/slots-are-numbered-by-the-process.md)).

## Spikes before the first release, with gates written first

Nothing central was built on faith. Before 0.1.0, the two mechanisms
everything else depends on were spiked, with their pass and kill conditions
written down first.

The front end: Relay's compiler crates, behind Baton's own driver, on stable
Rust. The record keeps the result. A stripped binary of 4.3 MB. 500 fragments
compiled in 8 ms warm. Relay's own error for a misspelled field, landing on
the exact character inside a Swift literal ([the
record](../decisions/relay-front-end.md)).

The ingest: response bytes decoded straight into records by a plan, measured
against Foundation's parser plus a hand-written mapping. The 0.1.0 entry of
the same day shows the shape of the result. 2.14 ms to tokenize and
normalize the fixture, against 4.47 ms for `JSONSerialization` alone
([BENCHMARKS.md](../../BENCHMARKS.md)).

A gate that fails parks the plan, rather than negotiating it. When a later
plan proposed a 50 µs budget for a derived verdict, and the bench measured
567 µs, the step parked at its first half, and the benchmark file says so.

## Fixtures as the oracle, benches before claims

The two habits that keep a fast store honest have [a page of their
own](how-a-fast-store-stays-honest.md). In one paragraph: the specification
under `spec/` holds schemas, documents, recorded responses, the store dumps
a commit must produce, the reads a lens must answer, and scripts over time.
Sixty-seven cases and thirteen scripts at this writing. Both runtimes pass
the same files. A naive reference reader is the oracle for every fast path.
Relay's own store tests are harvested and measured against, with a status
per disagreement.

Every advertised number has a bench.
[BENCHMARKS.md](../../BENCHMARKS.md) records it with the revision, the
machine, the OS, and the date. The file is appended to, never edited. A
claim without a bench does not ship.

## Issues as direction, not as axioms

The first outside adopter filed twenty-one issues. Nineteen were answered on
the issues on 4 October 2026, with what stands and what is refused. Each
refusal has a reopening trigger. The two that asked for a Kotlin runtime
were answered by building one.

The answers became decision records. Those records were then ordered into
one spine: the handle, the write, the lifetime, the session, and the keys.
That spine was built before any feature, one release a step ([the
record](../decisions/the-decided-architecture-is-built-first.md)).

The need in an issue sets the direction. The shape of the answer is judged
against the principles. When the shape asked for would have been a policy
object, or a second way to do something, the answer said no, with a reason
and a trigger. That is slower than saying yes. It is why the vocabulary is
still twelve words.

## Releases whenever there is something to use

Sixteen releases shipped between 2 and 13 October 2026, from 0.1.0 to
0.16.0. A release is cut when the changelog's Unreleased section holds
something an adopter can use, and the local checks pass. It waits for no
batch.

Since 0.9.0, its name is taken from a list without asking anyone. A bread of
Russian, Ukrainian, and Belarusian baking, so that a release never waits on
a question with no technical content. The eight before it were named one at
a time, on a relay theme ([the
record](../decisions/releases-are-frequent-and-named-for-bread.md)).

The release commit touches the manifests, the changelog, and the version the
Gradle recipe quotes, and nothing else. The workflow reads the version and
the name from the changelog's heading. The compiler's prebuilt bundle ships
in the tag, so that a package can depend on Baton by its tag.

The changelog is written for a person. Before 1.0, breaking changes are
listed without apology. CI reports public API breakage against a tagged
release, so that a reviewer can see the list is whole.

The same habit holds the docs. Public docs are updated in the same change
that makes them stale: the README, the changelog, the terminology, the
samples. The terminology names a concept before code does, and marks what is
planned. The documentation site types nothing by hand. Every generated file,
operation text, diagnostic, and store on it is produced by the compiler or
the runtime when the site is built. A page cannot show code the compiler
would not write.

## Two more habits, and who wrote the code

Two habits found real defects, and are rules now. Tests run in release
builds as well as debug, because the optimizer merges identical getters and
the key paths that serve as invalidation channels then collide. A spike
found it. The rule is in the project's instructions. Generated code is
compiled against a corpus of hostile schema names, in every position a name
can take, by a sweep that runs in CI, in both languages.

The code was written with agentic tools. The design, the API, and every
decision are the owner's, and each is recorded in the files linked from this
page. The habits above are what make that arrangement safe. A fixture that
cannot be edited to fit code. A golden for every emitter. A bench for every
claim. A sweep for every name. A release build for every test. A record for
every choice.

They would be the right habits for code written any other way. They are the
necessary ones for code written this way. Baton's own documentation is
written so that an agent integrating it reads [the same
page](../recipes/agents.md) first.

## What this does not claim

This does not claim that nothing is wrong. The API will break before 1.0,
and the changelog says where. Several decision records carry the line that
no device of the class they name was at hand when the plan asked for the
number. The line stands until one is. The Kotlin runtime is days old, and
shipped by no app yet.

What the process claims is narrower, and worth more. What is wrong is found
by a mechanism, not by a user. It is recorded where anyone can read it. It
is reopened on evidence, not on taste. That is what production grade
means for a library at 0.16. It is the standard the next release is held to.
