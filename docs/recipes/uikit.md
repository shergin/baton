# UIKit and AppKit: a handle held by a controller

Baton's reads are synchronous on the main actor and its handles are
`@Observable` classes, so a `UIViewController` or an `NSViewController`
uses them without SwiftUI: it asks the environment for the handle, holds
the retention that keeps the handle's data alive, renders what it reads,
and renders again when that changes. Nothing here is a second API; it is the
same handle the `@Query` wrapper resolves.

The code below is compiled in this repository, as the `Controllers` target
under [`examples/Controllers`](../../examples/Controllers): what both
platforms share in `Content.swift`, and a list, a detail, a cell and the
app's lifecycle for each under `UIKit/` and `AppKit/`. CI builds the UIKit
half for the iOS Simulator and the AppKit half for macOS, and
`ControllersTests` proves on macOS what this page says of them.

## Where the GraphQL lives

`@Query` on a property is a view's storage: it resolves the handle from
SwiftUI's environment, which a controller does not have. A controller's
operations go in a `.graphql` file in the target, which the build plugin
compiles with the target's Swift sources:

```graphql
query CharactersQuery($page: Int) {
  characters(page: $page) {
    results {
      id
      ...CharacterCell_character
    }
  }
}

fragment CharacterCell_character on Character {
  name
  status
  species
}

query CharacterQuery($id: ID!) {
  character(id: $id) {
    name
    status
    species
    origin { name }
  }
}
```

The fragment is here because two cells read it, the UIKit one and the
AppKit one. An app with one cell can keep it beside the cell instead:
`@Fragment` is only a marker the compiler reads the text from, so it works
on a property of any type, not only a view's.

## The handle and its retention

```swift
@MainActor
public final class CharacterViewController: UIViewController {
    private let handle: OperationHandle<CharacterQuery>
    private var retention: Retention?
    private var observation: Task<Void, Never>?

    public init(environment: Environment, id: String) {
        handle = environment.handle(for: CharacterQuery(id: id))
        super.init(nibName: nil, bundle: nil)
    }

    isolated deinit {
        observation?.cancel()
    }
}
```

`handle(for:)` returns the one handle every holder of an equal operation
value shares, and attaches with the fetch policy given (`storeOrNetwork`
by default). `retain()`, called when the view loads, returns a `Retention`:
while the controller holds it, the operation's root is the store's and its
records stay; when the controller goes, so does the retention, and the
collector may reclaim what nothing else keeps. Hold it in a property, never
in a local. The AppKit controller is the same, over `NSViewController`.

## Rendering on change

The handle's `phase` is `.loading`, `.ready(data)` or `.failed(error)`, and
a lens's fields are observable. `Observations`, on the 26 floor, turns what
a closure reads into a sequence that yields when any of it changes. What it
watches is what the closure reads, and nothing else: the phase reads
whether the data is there, not the fields in it. So the closure computes
what the controller shows, reading every field it displays, and the loop
only applies it. The computation is plain Swift over the lens, the same on
both platforms:

```swift
public enum CharacterContent: Sendable, Equatable {
    case loading
    case failed(String)
    case ready(name: String, details: String, origin: String)

    @MainActor
    public init(_ phase: Phase<CharacterQuery.Data>) {
        switch phase {
        case .loading:
            self = .loading
        case .failed(let error):
            self = .failed(String(describing: error))
        case .ready(let data):
            guard let character = data.character else {
                self = .failed("No such character")
                return
            }
            self = .ready(
                name: character.name ?? "Unknown",
                details: [character.status, character.species].compactMap { $0 }.joined(separator: " · "),
                origin: character.origin?.name ?? "Unknown"
            )
        }
    }
}
```

and the controller observes it:

```swift
public override func viewDidLoad() {
    super.viewDidLoad()
    retention = handle.retain()
    render(CharacterContent(handle.phase))
    observation = Task { [weak self, handle] in
        for await content in Observations({ CharacterContent(handle.phase) }) {
            self?.render(content)
        }
    }
}
```

A commit that renames the character yields once; a commit that changes a
field the controller does not show yields nothing. A loop that observed
`handle.phase` alone and read the fields in its body would render the
first response and never the rename.

The first `render` call is not redundant. `Observations` is a sequence and
delivers its first value after a suspension, so a controller that waited
for it would show one blank frame even when the store already holds the
data; the synchronous read draws that frame from the store. The sequence's
first value then renders the same thing again.

`retry()` on the handle after a failed phase, `refetch()` behind a refresh
control, and `isStale` to decide whether to show one are the handle's, as
they are a view's.

## A cell

A cell takes a lens, not a model: the fragment's generated struct, handed
down by the controller as a parent view hands it to a child. The list's
content reads the rows' ids and lenses, not their fields, so a commit that
renames one character renders that character's cell and does not reload
the table.

```swift
@MainActor
public final class CharacterCell: UITableViewCell {
    private var observation: Task<Void, Never>?

    public func bind(_ character: CharacterCell_character) {
        observation?.cancel()
        render(CharacterCellContent(character))
        observation = Task { [weak self] in
            for await content in Observations({ CharacterCellContent(character) }) {
                self?.render(content)
            }
        }
    }

    public override func prepareForReuse() {
        super.prepareForReuse()
        observation?.cancel()
        observation = nil
    }

    private func render(_ content: CharacterCellContent) {
        var configuration = defaultContentConfiguration()
        configuration.text = content.name
        configuration.secondaryText = content.details
        contentConfiguration = configuration
    }
}
```

The lens is a value over the store; it reads synchronously and costs
nothing to hold, so a bound cell renders in the call. The cell cancels its
observation on reuse so a recycled cell does not render the row it left.
The AppKit cell is an `NSTableCellView` with the same `bind` and
`prepareForReuse`, rendering into two labels.

## The app's lifecycle

`environment.isActive` parks the retained subscriptions while it is false
and resumes them when it is true again; `environment.revalidate()` refetches
the retained operations that went stale or failed. Each platform says when
from its own notifications, and the app holds one `Activation` for as long
as the environment lives.

On iOS the application's notifications, not a scene's: the environment is
the app's, and one scene leaving the screen while another stays does not
make the app inactive.

```swift
observers = [
    center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
        MainActor.assumeIsolated { environment.isActive = false }
    },
    center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { _ in
        MainActor.assumeIsolated {
            environment.isActive = true
            environment.revalidate()
        }
    },
]
```

On macOS a window stays on screen while another app is frontmost, so
resigning active parks nothing: hiding does, and returning revalidates.

```swift
observers = [
    center.addObserver(forName: NSApplication.didHideNotification, object: nil, queue: .main) { _ in
        MainActor.assumeIsolated { environment.isActive = false }
    },
    center.addObserver(forName: NSApplication.didUnhideNotification, object: nil, queue: .main) { _ in
        MainActor.assumeIsolated { environment.isActive = true }
    },
    center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
        MainActor.assumeIsolated { environment.revalidate() }
    },
]
```

Writes are the environment's whatever hosts them:
`try await environment.mutate(SetFavorite(id: id, favorite: true), optimistic: ...)`
from an action, and the optimistic layer shows in the turn of the call.

Nothing in the runtime imports UIKit or AppKit; `Observations` and the
handles are Foundation and Observation.
