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

## What it is not

- Not a commit signal. Caton asked twice for one; a model that observes
  what it reads does not need to know that a commit happened, only that a
  value it derives from changed, and `Observations` says exactly that.
- Not a second read API. The closure reads the same lenses a view reads,
  synchronously, on the main actor.
- Not a cache in the store. The derived value belongs to the model that
  derives it; the store holds what the server said.

See [UIKit and AppKit](uikit.md) for the same pattern driving a controller
and a cell, and [the decision](../decisions/the-store-numbers-what-it-renders.md)
for why a read registers per field.
