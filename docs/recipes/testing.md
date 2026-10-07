# Previews and tests: a store without a server

Baton's store is filled from a payload as well as from the network, and a
transport is a protocol with one verb, so a preview, a test and a benchmark
each get a store the way an app does and never a mock of Baton's types.
This page is the catalogue; every piece lives in `BatonTesting`, a product
of the package nothing in the app links, except `commitPayload`, which is
the environment's own.

## A preview: a fixture committed as a response

```swift
let environment = Environment(transport: SilentTransport())
try await environment.commitPayload(CharacterQuery(id: "1"), fixture)
```

`commitPayload` runs the operation's plan over bytes in a response's shape
and commits them as a fetch's response is committed, so the preview draws
from the fixture through the same lenses, and `SilentTransport` never
answers, so nothing behind the preview waits on a network. The payload may
carry part of what the operation selects; what it leaves out reads as
missing, as a partial response would.

## A test over recorded responses

```swift
let transport = RecordedTransport([CharacterQuery.name: fixture("character-1")])
let environment = Environment(transport: transport)
```

`RecordedTransport` answers each operation by name, or through a responder
that sees the whole request, and keeps the requests it was sent
(`requests`, `requestCount`), so a test asserts what the app asked for. An
operation with nothing recorded fails with a `TransportError` of status 0
that says so.

## A test that holds a mutation or drives a subscription

```swift
let transport = ScriptedTransport([CharacterQuery.name: fixture("character-1")])
let environment = Environment(transport: transport, subscriptions: transport)
let task = Task { try await environment.mutate(SetFavorite(id: "1", favorite: true), optimistic: optimistic) }
await wait(until: { transport.held.count == 1 })
// The optimistic layer is applied; the server has not answered.
transport.held[0].respond(fixture("set-favorite-1"))
```

`ScriptedTransport` holds a mutation, or any operation the test names, until
the test replies or refuses it, so the window between an optimistic apply
and the server's answer is observable; it drives a subscription's events by
hand (`driven[i].send`, `complete`, `fail`); and it lists its requests by
kind. `wait(until:)` waits on the main actor for a handle or a store to
settle, with a timeout, yielding between checks.

## A rule tested with a value

```swift
func isSeriesRegular(_ character: CharacterValue_character) -> Bool {
    character.status == "Alive" && character.episode.count > 10
}

#expect(!isSeriesRegular(CharacterValue_character(id: "1", name: "Rick", status: "Dead", origin: nil, episode: [])))
```

A rule outside a view takes the value an `@inline` fragment compiles to,
so its test builds one with the value's initializer, field by field, and
needs no store at all; the app hands it the value the spread's accessor
read. The same rule over a lens would need a store to read from.

## The log in tests

A debug build prints a missing field, a value a reader's type cannot hold,
an ambiguous id and a null `@required(action: LOG)` field through the
environment's `log`. A test silences them with `environment.log = nil`, or
collects them:

```swift
let seen = Events()
environment.log = { event in seen.append(event) }
```

The events are value-free, names and counts, so a test asserts
`.missing(type: "Character", field: "name")` and never a record.

## A bug report that becomes a fixture

`StoreExport.text(of: environment.store)`, from `BatonInspector`, writes the
store in the dump format the fixtures under `spec/` use: every record by
key, sorted, one a line. A dump from a debug menu or the inspector's share
button is a fixture a test can start from, and a diff of two dumps is a
reviewable change to identity or layout.

## What these are not

Not mocks. Each is a transport like any other, and nothing behind it can
tell: the environment, the store, the handles and the lenses run the code
the app runs. A test of the app's own layer over Baton therefore tests that
layer, not a stand-in for the library.
