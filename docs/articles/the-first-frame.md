# The first frame has the data

Open a screen the app has already shown, and the first frame is a spinner.
On both Apollo clients that is not a bug to file, but the design.

Apollo Kotlin documents that its cache operations are `suspend` functions,
and that they must not run on the main thread. Its Compose helper collects a
flow that starts at `null`. Apollo iOS 2 reads its store through `async`
functions, each hop through an actor and a new task.

A cache that must be awaited cannot answer a view body. A view body is
synchronous, so the body runs once without the data and once with it. Baton
exists to remove that frame. The way it does so is a chain of decisions,
each with a number behind it.

## Why the frame matters

The apps that publish on this all show cached content first. Facebook's 2012
iOS rebuild rendered the cached feed at launch, and read only what the first
layout needed from disk ([Under the hood: Rebuilding Facebook for
iOS](https://engineering.fb.com/2012/08/23/ios/under-the-hood-rebuilding-facebook-for-ios/)).
Its 2015 Android work measured a story loading from the disk cache at 35 ms,
over a 16.6 ms frame, and brought it to 4 ms with a format that is read in
place ([Improving Facebook's performance on Android with
FlatBuffers](https://engineering.fb.com/2015/07/31/android/improving-facebook-s-performance-on-android-with-flatbuffers/)).

Vrbo's Android app fetched everything a flow needed in one orchestrated
query, then read the detail screens from the cache alone, with no network
loading states ([How Apollo-Android client cache works at
Vrbo](https://medium.com/expedia-group-tech/how-apollo-android-client-cache-works-at-vrbo-73334d98af43)).
Threads measured the cost of not doing so. 0.29 to 0.36 seconds of injected
navigation latency cost 0.54 to 0.81% of daily active users ([How we think
about Threads' iOS
performance](https://engineering.fb.com/2024/12/18/ios/how-we-think-about-threads-ios-performance/)).

The first frame is where a data layer is judged.

## Reads are synchronous on the main actor

A view body is a synchronous function on the main actor. For the first body
to have the data, the read has to be a synchronous function on the main
actor too. That decides where the store lives.

In Baton the records are the main actor's state, observable objects whose
slots a lens loads directly. A read is a slot load: 26 ns on an Apple M1
Pro, about half a microsecond inside a body under Observation's tracking,
and 47 ns a field on a Pixel 9, through the Kotlin runtime
([BENCHMARKS.md](../../BENCHMARKS.md)).

The handle does its work before the first body. When a view appears, its
operation value resolves against the store. An availability check walks the
operation's plan over the records and answers whether the store can render
it. For the whole 899-record fixture, that check costs 115 µs on the Mac and
1.2 ms on the phone.

If it can, the phase is `ready` in the first body, and no request is sent
under the default policy. If it cannot, the phase is `loading`, and the
environment fetches. Under `storeAndNetwork`, the first body renders what is
there and a refresh runs behind it. The previous data stays on screen, and
`isRefreshing` says so.

There is no asynchronous read API for views, and there will not be one,
which is rule two of the vision. The refusal is what keeps the first frame
honest. Nothing a view can call returns a promise of data.

## What runs on the main actor, and what does not

The posture, written before the store existed, was that the main actor does
reads and commits and nothing else. Building it moved three more things
there, on evidence: the availability check, with hydration from the image;
collection; and the normalization of an optimistic response.

The decision record says why, and gives the numbers ([the
decision](../decisions/the-check-and-collection-run-on-the-main-actor.md)).
A check on another actor could not fill a record from the image without
coming back to the main actor before the handle could be ready. A ready that
waits is the asynchronous read the rule forbids. An optimistic response
normalized elsewhere would show a frame late. A collection mark from a
snapshot would copy every reachable record's links each pass.

Everything else runs off it. A response's bytes are decoded and normalized
in the fetch's own task, the image is written behind on its own queue, and
the image is opened off the main actor when the app makes its environment.

The numbers that keep the main-actor work there come from the Mac. A
collection pass over about 9,000 records takes 0.24 ms at best, and 3.8 ms
at the median. Hydration of the fixture's 898 rows into an empty store
takes 1.72 ms. The same check, with the records already in memory, takes
105 µs. Each is under a third of a frame on that
machine. The reopening condition is written down: a pass, or a hydration,
that takes longer than a frame on an iPhone 12-class device.

## The image, and the next launch

A warm start is the launch after a kill. For its first frame to have the
data, the store has to outlive the process.

The image is one SQLite file, through the library the system ships, and
nothing is vendored. It holds a binary row per record, keyed by the record's
key; the query root, a row per field; the time each operation last fetched;
and a table of names, because slot numbers belong to a process.

Every server batch is written behind the commit, by one writer, in WAL mode
with `synchronous=NORMAL`. A crash may lose the last moments, and never the
file's consistency. Optimistic layers never reach it.

Reading is the availability check. When memory cannot answer, the walk runs
again with the connection at hand, inside one read transaction, and fills
what memory lacks. On the Mac, a launch in a new process has the fixture in
the store 1.78 ms after its handle asks, when the file was opened off the
main actor before the first view, and 4.68 ms when the main actor had to
wait for the open. Keeping the image costs a commit 0.12 ms on the main
actor and 1.16 ms off it. The file is 168 KB for the 686 KB response
([BENCHMARKS.md](../../BENCHMARKS.md), the 0.6.0 entry).

The image is a cache, not a database, and three rules keep it one. An entry
that cannot be read is a miss, never a migration. An image written under
another schema, another format, or another identity configuration starts
again. That is LinkedIn's rule from 2016, and the reason a schema change
cannot strand an app.

A row that goes one whole launch unread is dropped at the next, and a size
limit is checked at launch ([the
decision](../decisions/the-image-evicts-by-launch.md)). The image belongs to
one store: a sign-out ends the environment, which closes the image, and the
next environment starts its own ([the
decision](../decisions/the-environment-is-the-session.md)).

SQLite was chosen over a memory-mapped B-tree, and over a file format of
Baton's own. The record says why ([the
decision](../decisions/the-image-is-sqlite.md)). The spike measured the
alternatives hydrating faster on the Mac. The decision went to the simplest
engine anyway, because hydration was already the smaller part of a launch.
The alternatives cost vendored C, a licence notice in every binary, I/O
errors that arrive as signals, and crash consistency that would be Baton's
to prove. The rule was that a Mac's numbers can only show whether engines
differ radically. Unless they do, the simplest one wins.

## What a phone measured

The measurement is the Kotlin sample and its Apollo Kotlin twin, the same
two Compose screens, on a Google Pixel 9, on 8 October 2026: fifteen cold
starts each, over a store a priming launch had left on disk
([BENCHMARKS.md](../../BENCHMARKS.md), "end to end on a phone").

Baton's list is in its first frame, 239.6 ms from launch. The check read
what memory lacked from the image, on the main thread, before the first
composition. Apollo's first frame comes at 209 ms, and it is the spinner.
Its list follows at 272 ms, from the SQL cache, once the collected flow
emits. A tap into a detail whose header the list already holds shows the
header in the detail's first frame, 22 ms after the tap, against 33 ms and a
spinner first.

The same run found something against Baton, and the file says that too. Its
first frame came 23 to 30 ms after Apollo's. The traces, read with Perfetto
on the phone the next day, put it in the first composition. The main thread
slept for 23 ms behind the image's writer, creating the file under the
disk's lock, a cost every first launch of an app paid.

0.15.0 fixed it. A read of a file that did not exist at construction now
answers from memory alone. On the same phone, the cold start's first frame
came 26 ms sooner, level with the twin's. The list came 24 ms sooner: 255 ms
from launch, against the twin's 327. That is the discipline the first frame
needs. Measure on a device, trace where the time goes, and fix the cause.
Then measure again, and leave the record in the file.

## Staleness is a phase, not a surprise

Data in the first frame is a virtue only if the view can tell how old it is.
A handle's `phase` is `loading`, `ready`, or `failed`. Beside it,
`isRefreshing` and `isStale` keep their meaning across a launch, because the
image stores when each operation last fetched.

An operation states its own expiration in its document,
`@cacheExpiration(seconds:)`. That is the one directive Baton has that Relay
does not, because neither Relay nor the specification has a word for it
([the
decision](../decisions/an-operation-states-its-expiration.md)).

The last fetch is a value a view can read: idle, in flight, or failed with
its kind. A refresh that fails behind data is seen, without the data going.
`revalidate()` is one call the app makes when it returns to the foreground.
It refetches what is stale. The policy stays with the holder ([the
decision](../decisions/revalidation-is-the-apps-call.md)).

## What it costs

The main actor does hydration, so an image far larger than the benches model
is a cost the frame would feel. That is the reopening condition above.
Eviction by launch, and the size limit, are what keep the image near the
screens the app actually shows.

One process uses a file, so an extension or a widget cannot share the image.
Eviction is by launch and by a size limit, not a trim of the largest
records. Apollo Kotlin's cache has TTL, partial reads, and a trim. Those are
the open edges, and [the comparison](../comparison.md) lists them beside
what Apollo is ahead on.

In exchange, the screen you left is the screen you get back, before any
request. The detail you tap into has its header in the first frame. There is
no loading flash for a screen the app has seen.
