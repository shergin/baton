# UIKit and AppKit: a handle held by a controller

Baton's reads are synchronous on the main actor and its handles are
`@Observable` classes, so a view controller or an `NSViewController` uses
them without SwiftUI: it asks the environment for the handle, holds the
retention that keeps the handle's data alive, renders what it reads, and
renders again when that changes. Nothing here is a second API; it is the
same handle the `@Query` wrapper resolves.

The AppKit code below is compiled in this repository, as the `Controllers`
target under [`examples/Controllers`](../../examples/Controllers), and
`ControllersTests` proves what this page says of it. UIKit is the same code
with UIKit's types; [UIKit](#uikit) lists the differences.

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

query CharacterQuery($id: ID!) {
  character(id: $id) {
    name
    status
    species
    origin { name }
  }
}
```

`@Fragment` is only a marker the compiler reads the text from, so a
fragment can stay beside the cell that reads it, on the property that holds
its lens (see [A cell](#a-cell)). Both files generate the same operation
values and lenses a view's markers do.

## The handle and its retention

```swift
@MainActor
public final class CharacterViewController: NSViewController {
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
in a local.

## Rendering on change

The handle's `phase` is `.loading`, `.ready(data)` or `.failed(error)`, and
a lens's fields are observable. `Observations`, on the 26 floor, turns what
a closure reads into a sequence that yields when any of it changes. What it
watches is what the closure reads, and nothing else: the phase reads
whether the data is there, not the fields in it. So the closure computes
what the controller shows, reading every field it displays, and the loop
only applies it:

```swift
enum Shown: Sendable {
    case loading
    case failed(String)
    case ready(name: String, details: String, origin: String)
}

public override func viewDidLoad() {
    super.viewDidLoad()
    retention = handle.retain()
    render(Self.shown(handle.phase))
    observation = Task { [weak self, handle] in
        for await shown in Observations({ Self.shown(handle.phase) }) {
            self?.render(shown)
        }
    }
}

static func shown(_ phase: Phase<CharacterQuery.Data>) -> Shown {
    switch phase {
    case .loading:
        return .loading
    case .failed(let error):
        return .failed(String(describing: error))
    case .ready(let data):
        guard let character = data.character else { return .failed("No such character") }
        return .ready(
            name: character.name ?? "Unknown",
            details: [character.status, character.species].compactMap { $0 }.joined(separator: " · "),
            origin: character.origin?.name ?? "Unknown"
        )
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
down by the controller as a parent view hands it to a child. The list
controller's closure reads the rows' ids and lenses, not their fields, so a
commit that renames one character renders that character's cell and does
not reload the table.

```swift
@MainActor
public final class CharacterCell: NSTableCellView {
    @Fragment("""
        fragment CharacterCell_character on Character {
          name
          status
          species
        }
        """)
    private var character: CharacterCell_character?

    private var observation: Task<Void, Never>?

    public func bind(_ character: CharacterCell_character) {
        observation?.cancel()
        self.character = character
        render(Self.shown(character))
        observation = Task { [weak self] in
            for await shown in Observations({ Self.shown(character) }) {
                self?.render(shown)
            }
        }
    }

    public override func prepareForReuse() {
        super.prepareForReuse()
        observation?.cancel()
        observation = nil
        character = nil
    }

    static func shown(_ character: CharacterCell_character) -> (name: String, details: String) {
        (
            name: character.name ?? "Unknown",
            details: [character.status, character.species].compactMap { $0 }.joined(separator: " · ")
        )
    }
}
```

The lens is a value over the store; it reads synchronously and costs
nothing to hold, so a bound cell renders in the call. The cell cancels its
observation on reuse so a recycled cell does not render the row it left.

## The app's lifecycle

`environment.isActive` parks the retained subscriptions while it is false
and resumes them when it is true again; `environment.revalidate()` refetches
the retained operations that went stale or failed. A Mac app's window stays
on screen while another app is frontmost, so resigning active parks
nothing: hiding does. Returning to the app revalidates.

```swift
@MainActor
public final class Activation {
    private let center: NotificationCenter
    private var observers: [any NSObjectProtocol] = []

    public init(environment: Environment, center: NotificationCenter = .default) {
        self.center = center
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
    }

    isolated deinit {
        for observer in observers { center.removeObserver(observer) }
    }
}
```

The app delegate holds one for as long as the environment lives. Writes
are the environment's whatever hosts them:
`try await environment.mutate(SetFavorite(id: id, favorite: true), optimistic: ...)`
from an action, and the optimistic layer shows in the turn of the call.

## UIKit

The same code, with these types:

| AppKit | UIKit |
|---|---|
| `NSViewController`, `viewDidLoad()` | `UIViewController`, `viewDidLoad()` |
| `NSTableCellView`, `prepareForReuse()` | `UITableViewCell` or `UICollectionViewListCell`, `prepareForReuse()` |
| `NSTextField(labelWithString:)` | `UILabel` |
| `NSApplication.didHideNotification` and `didUnhideNotification` | `UIScene.didEnterBackgroundNotification` and `willEnterForegroundNotification` |
| `NSApplication.didBecomeActiveNotification` | `UIScene.willEnterForegroundNotification` |

Nothing in the runtime imports UIKit or AppKit; `Observations` and the
handles are Foundation and Observation.
