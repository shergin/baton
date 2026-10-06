# UIKit and AppKit: a handle held by a controller

Baton's reads are synchronous on the main actor and its handles are
`@Observable` classes, so a view controller or an `NSViewController` uses
them without SwiftUI: it asks the environment for the handle, holds the
retention that keeps the handle's data alive, and re-renders when what it
read changes. Nothing here is a second API; it is the same handle the
`@Query` wrapper resolves.

## The handle and its retention

```swift
@MainActor
final class CharacterViewController: UIViewController {
    private let environment: Environment
    private let handle: OperationHandle<CharacterQuery>
    private var retention: Retention?

    init(environment: Environment, id: String) {
        self.environment = environment
        handle = environment.handle(for: CharacterQuery(id: id))
        super.init(nibName: nil, bundle: nil)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        retention = handle.retain()
        observe()
    }
}
```

`handle(for:)` returns the one handle every holder of an equal operation
value shares, and attaches with the fetch policy given (`storeOrNetwork`
by default). `retain()` returns a `Retention`: while the controller holds
it, the operation's root is the store's and its records stay; when the
controller goes, so does the retention, and the collector may reclaim what
nothing else keeps. Hold it in a property, never in a local.

## Rendering on change

The handle's `phase` is `.loading`, `.ready(data)` or `.failed(error)`, and
a lens's fields are observable. `Observations`, on the 26 floor, turns what
a closure reads into a sequence that yields when any of it changes:

```swift
private func observe() {
    observation = Task { [weak self] in
        guard let self else { return }
        for await phase in Observations { self.handle.phase } {
            render(phase)
        }
    }
}

private func render(_ phase: Phase<CharacterQuery.Data>) {
    switch phase {
    case .loading: spinner.startAnimating()
    case .failed(let error): show(error)
    case .ready(let data):
        spinner.stopAnimating()
        nameLabel.text = data.character?.name
    }
}
```

Reading `data.character?.name` inside the closure adds that field to what
the sequence watches, so a commit that changes the name yields again and a
commit that changes something else does not. `withObservationTracking` does
the same for one render at a time where a sequence does not fit.

## A cell

A cell takes a lens, not a model: the fragment's generated struct, handed
down from the row's parent as a view's would be.

```swift
final class CharacterCell: UITableViewCell {
    private var observation: Task<Void, Never>?

    func bind(_ character: CharacterRow_character) {
        observation?.cancel()
        observation = Task { [weak self] in
            for await (name, status) in Observations { (character.name, character.status) } {
                self?.nameLabel.text = name
                self?.statusLabel.text = status
            }
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        observation?.cancel()
    }
}
```

The lens is a value over the store; it reads synchronously and costs
nothing to hold. The cell cancels its observation on reuse so a recycled
cell does not render the row it left.

## Writes, staleness and the foreground

- `try await environment.mutate(SetFavorite(id: id, favorite: true), optimistic: ...)`
  from an action; the optimistic layer shows in the turn of the call.
- `handle.isStale` and `handle.refetch()` behind a pull-to-refresh;
  `handle.retry()` on a failed phase.
- `environment.isActive = false` when the scene resigns and `true` when it
  returns, so retained subscriptions park and resume, and
  `environment.revalidate()` on return to refetch what is stale or failed.

## AppKit

The same, with `NSViewController`, `NSTableCellView` and the scene phase
replaced by `NSApplication`'s activation notifications. Nothing in the
runtime imports UIKit or AppKit; `Observations` and the handles are
Foundation and Observation.
