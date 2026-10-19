# Derived state outside views

A model that is not a view sometimes wants a value computed from the
store: a badge count over a connection, a sort of rows by a field, a flag
over several lenses. Baton adds no API for it. A lens's fields and a
handle's phase are observable, and `Observations`, on the 26 floor, turns
what a closure reads into a sequence that yields when any of it changes.
The model reads through that sequence and keeps the derived value itself.

## The shape

```swift
@MainActor
@Observable
final class TriageBadge {
    private(set) var open = 0
    private let retention: Retention
    private let handle: OperationHandle<TriageQuery>
    private var observation: Task<Void, Never>?

    init(environment: Environment) {
        handle = environment.handle(for: TriageQuery())
        retention = handle.retain()
        observation = Task { [weak self] in
            guard let self else { return }
            for await count in Observations<Int, Never> { self.count() } {
                open = count
            }
        }
    }

    /// Open items assigned to the viewer that are pull requests: a number
    /// no field holds, derived from the rows.
    private func count() -> Int {
        guard case .ready(let data) = handle.phase else { return 0 }
        return data.assigned.nodes?.filter { $0.asPullRequest != nil }.count ?? 0
    }
}
```

`count()` reads the phase, the search's rows, and each row's type. The
sequence yields when any of them changes, once per commit, after the
commit's notifications, and it does not yield for a commit that touched
nothing it read. Spell the element type in the generic parameters, as
above, because Swift 6.3's compiler crashes on a closure that states
`@MainActor () -> Int` itself. The retention keeps the operation's data
alive for the model's life, as a view's storage would.

## The same in Kotlin

Compose's snapshot state records what a block reads, as Observation does.
`snapshotFlow` turns the block into a flow that emits when any of it
changes. The model reads the handle inside the block and keeps the value,
in this shape:

```kotlin
class TriageBadge(environment: Environment) {
    private val handle = environment.handle(TriageQuery())
    private val hold = handle.retain()

    /** Open items assigned to the viewer that are pull requests. */
    val open: Flow<Int> = snapshotFlow {
        val phase = handle.phase
        if (phase is Phase.Ready) phase.data.assigned.nodes.orEmpty().count { it.asPullRequest != null } else 0
    }

    fun close() = hold.release()
}
```

Collect the flow on the main dispatcher, where the store is read, and
release the hold with the model. [Views and view models](views.md) is
this page's Kotlin twin, with the model compiled and proven.

## A derivation over a whole operation

A model that derives one value from every entry of a large operation, a
panel over a user's whole list, reads thousands of entries and dozens of
fields each. Every field it reads inside the closure registers on that
slot's channel, as a view body's read does. At this size the
registrations cost more than the reads. Budget the pass before you build
it: a pass of N entries by M fields costs N × M field reads, at what one
read costs tracked or untracked.

Measured on the list recorded under `spec/anilist/`, 1,000 entries, on an
M1 Pro: a reading of every field of the row's fragment is 44 slots an
entry, 44,006 over the list, and the model below reads seven slots an
entry for its five values. The entry *The AniList list* in
[BENCHMARKS.md](../../BENCHMARKS.md), 18 October, has the rest:

| | Swift | Kotlin, the JVM |
|---|---|---|
| One field read, untracked | 20 ns | 14 ns |
| One field read, tracked | 647 ns | 57 ns |
| The whole list, untracked | 0.89 ms | 0.65 ms |
| The whole list, tracked, to the first value of `Observations` or `snapshotFlow` | 28.3 ms | 2.2 ms |
| One chunk of 500 entries, tracked, every field | 14.2 ms | 1.2 ms |
| One chunk of 500 entries, tracked, five values an entry | 2.6 ms | 0.26 ms |

A tracked read in Swift is Observation's registrar: a key path registered
with the record, and an observer installed on it when the scope ends. It
costs what an `@Observable` property costs, 585 ns a field in a row body
of eight in the same runs, and it stays linear from one chunk to the
whole list. Compose's read observer adds the slot's state to a set, which
costs about a tenth as much. The untracked read costs tens of nanoseconds
on both runtimes. A frame at 120 Hz, 8.3 ms, holds about 13,000 tracked
field reads in Swift and about 145,000 on the JVM.

The composition keeps the tracked work off the launch and scopes each
change to one operation value:

- One `Observations` per operation handle, so a change in one chunk
  re-reads that chunk alone. A list fetched as chunks is one operation
  value a chunk, and each has its own handle.
- The first reading at launch is untracked and synchronous, taken before
  the streams start. A handle the image answers is ready in the turn it is
  made, so the model has the whole list in the same turn, at the untracked
  cost.
- A reading is applied only when it differs from the last. Each stream's
  first value is the tracked reading of its chunk, equal to the untracked
  one, and it changes nothing.
- The closure reads what the derived value needs, not the row's whole
  fragment. Every field read is registered, so seven slots an entry cost
  about a sixth of forty-four.

```swift
/// What the model derives from one entry: a value, so two readings compare.
struct Entry: Equatable {
    let id: Int
    let status: MediaListStatus?
    let progress: Int?
    let title: String?
    let nextEpisodeAt: Int?
}

@MainActor
@Observable
final class ListModel {
    /// The entries of every chunk, in order: the derived value.
    private(set) var entries: [Entry] = []
    private var readings: [[Entry]]
    private let handles: [OperationHandle<ListQuery>]
    private let retentions: [Retention]
    private var observations: [Task<Void, Never>] = []

    init(environment: Environment, userId: Int, chunks: Int) {
        handles = (1...chunks).map { environment.handle(for: ListQuery(userId: userId, mediaType: .ANIME, chunk: $0)) }
        retentions = handles.map { $0.retain() }
        // The first reading, untracked and in this turn: a handle the image
        // answered is ready before any stream starts.
        readings = handles.map(Self.read)
        entries = readings.flatMap(\.self)
        // One stream a handle, so a change in one chunk re-reads that chunk.
        for (index, handle) in handles.enumerated() {
            observations.append(Task { [weak self] in
                for await reading in Observations<[Entry], Never>({ Self.read(handle) }) {
                    guard let self else { return }
                    self.apply(reading, at: index)
                }
            })
        }
    }

    /// Applies a chunk's reading only when it differs from the last, so the
    /// streams' first readings, equal to the untracked one, change nothing.
    private func apply(_ reading: [Entry], at index: Int) {
        guard reading != readings[index] else { return }
        readings[index] = reading
        entries = readings.flatMap(\.self)
    }

    /// What the derived value needs of one chunk: five fields an entry, not
    /// the row's whole fragment, since every field read is registered.
    private static func read(_ handle: OperationHandle<ListQuery>) -> [Entry] {
        guard case .ready(let data) = handle.phase else { return [] }
        var entries: [Entry] = []
        for group in data.MediaListCollection?.lists ?? .empty {
            for entry in group.entries ?? .empty {
                let row = entry.entryRow
                let card = row.media?.mediaCard
                entries.append(Entry(id: row.id, status: row.status, progress: row.progress, title: card?.title?.userPreferred, nextEpisodeAt: card?.nextAiringEpisode?.airingAt))
            }
        }
        return entries
    }
}
```

In Kotlin the stream is `snapshotFlow` over each handle, and the derived
value a `StateFlow`. `snapshotFlow` drops a reading equal to its own last
one, but it delivers its first, so the model compares as the Swift one
does:

```kotlin
data class Entry(val id: Int, val status: MediaListStatus?, val progress: Int?, val title: String?, val nextEpisodeAt: Int?)

class ListModel(environment: Environment, scope: CoroutineScope, userId: Int, chunks: Int) {
    private val handles = (1..chunks).map { environment.handle(ListQuery(userId = userId, mediaType = MediaType.ANIME, chunk = it)) }
    private val holds = handles.map { it.retain() }

    // The first reading, untracked and in this call: a handle the image
    // answered is ready before any flow starts.
    private val readings = handles.map(::read).toMutableList()
    private val derived = MutableStateFlow(readings.flatten())

    /** The entries of every chunk, in order: the derived value. */
    val entries: StateFlow<List<Entry>> = derived

    // One flow a handle, so a change in one chunk re-reads that chunk.
    private val collection = scope.launch {
        handles.forEachIndexed { index, handle ->
            launch { snapshotFlow { read(handle) }.collect { apply(it, index) } }
        }
    }

    private fun apply(reading: List<Entry>, index: Int) {
        if (reading == readings[index]) return
        readings[index] = reading
        derived.value = readings.flatten()
    }

    fun close() {
        collection.cancel()
        holds.forEach { it.release() }
    }
}
```

`read` is the Swift one's twin. The scope runs on the store's thread.
Both models are compiled in this repository, as `ListModel` beside the
AniList tests under `swift/Tests/BatonAniListTests` and
`kotlin/baton/src/jvmTest/kotlin/baton/anilist`, and `ListModelTests`
beside each proves that the whole list is in hand in the turn the model is
made, with no request, that the streams' first readings change nothing,
and that a save of one entry changes that entry alone.

What the composition costs is a chunk's tracked re-read on a change. After
a one-field save in a chunk of 500 entries, the chunk's reading arrives
15.6 ms after the commit in Swift when it reads every field, and 2.7 ms
when it reads the model's five values; on the JVM, 1.16 ms and 0.31 ms.
A smaller chunk is the other lever, since the operation value is the unit
of a re-read.

## What it is not

- Not a commit signal. Caton asked twice for one. A model that observes
  what it reads does not need to know that a commit happened. It needs to
  know that a value it derives from changed, and `Observations` says
  exactly that.
- Not a second read API. The closure reads the same lenses a view reads,
  synchronously, on the main actor or on the store's thread.
- Not a cache in the store. The derived value belongs to the model that
  derives it, and the store holds what the server said.

See [UIKit and AppKit](uikit.md) for the same pattern driving a controller
and a cell, and
[the decision](../decisions/the-store-numbers-what-it-renders.md)
for why a read registers per field.
