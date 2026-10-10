# Derived state outside views

A model that is not a view sometimes wants a value computed from the store:
a badge count over a connection, a sort of rows by a field, a flag over
several lenses. Baton adds no API for it. A lens's fields and a handle's
phase are observable, and `Observations`, on the 26 floor, turns what a
closure reads into a sequence that yields when any of it changes; the model
reads through that and keeps the derived value itself.

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

`count()` reads the phase, the search's rows and each row's type; the
sequence yields when any of them changes, once per commit, after the
commit's notifications, and not for a commit that touched nothing it read.
Spell the element type in the generic parameters, as above: Swift 6.3's
compiler crashes on a closure that states `@MainActor () -> Int` itself. The retention keeps the operation's data alive for the model's life,
as a view's storage would.

## The same in Kotlin

Compose's snapshot state records what a block reads as Observation does,
and `snapshotFlow` turns the block into a flow that emits when any of it
changes; the model reads the handle inside the block and keeps the value.
The shape:

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

The flow is collected on the main dispatcher, where the store is read, and
the hold is released with the model. [Views and view models](views.md) is
this page's Kotlin twin, with the model compiled and proven.

## What it is not

- Not a commit signal. Caton asked twice for one; a model that observes
  what it reads does not need to know that a commit happened, only that a
  value it derives from changed, and `Observations` says exactly that.
- Not a second read API. The closure reads the same lenses a view reads,
  synchronously, on the main actor or on the store's thread.
- Not a cache in the store. The derived value belongs to the model that
  derives it; the store holds what the server said.

See [UIKit and AppKit](uikit.md) for the same pattern driving a controller
and a cell, and [the decision](../decisions/the-store-numbers-what-it-renders.md)
for why a read registers per field.
