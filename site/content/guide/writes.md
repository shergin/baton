# Writes

A mutation is an action: called with one argument per variable, asynchronous, able to fail, returning the payload's lens. What it changes is what its payload selects; what it adds to or removes from a list is an edge directive; what it shows before the server answers is its optimistic response. There is no cache updater, because a payload for an operation says every write.

## A mutation is an action

{{host star StarButton | A star toggle. The fragment is what the button reads; the two mutations are what it does. The optimistic response is a typed value of the payload's selection, with the concrete type named because `starrable` is an interface.}}

The call is `try await addStar(input:optimistic:)` in Swift and `addStar(input = …, optimistic = …)` in a coroutine in Kotlin; `isInFlight` says the server has not answered. The payload selects `viewerHasStarred` and `stargazerCount` on the repository, so when the server answers, the record the button reads is updated and the button re-renders, and so does any other view reading those fields, on any screen.

{{lens star StarButtonAddStar | The action's result: the payload as a lens, with the concrete type's fields under a condition.}}

## Optimistic responses

An optimistic response is rendered to a payload by a generated builder, ingested like a server's response, and applied as a layer with an undo log. The layer shows in the turn of the call, on the main actor, so the star fills before the request leaves. A commit under live layers lifts them, applies the response, re-applies them, and notifies only the slots whose value differs in the end. The server's answer replaces the layer; a failure reverts it.

{{script optimistic | The specification's optimistic script: a rename applied as a layer, a server commit underneath it, the layer resolved, a second layer reverted, and a deleted note revived by a layer and deleted again when the layer goes.}}

What the view does when the server refuses is the view's: the layer is already gone, so a button reads its old state again, and the action's error says why. The Kotlin GitHub sample's comment composer empties its field at once and puts the text back on a refusal; the Swift one clears it when the server answers.

## Adding to a list

A payload field that is an edge or a node carries an edge directive naming the connections to add to, through a `connections` variable the view fills from its lens's `connectionID`:

{{host comments CommentComposer | `@appendEdge` on the payload's `commentEdge`. The composer never touches the list; it names it.}}

{{operation comments CommentComposerAddComment | The directive is the client's business and stays out of the text the server receives, and so does the `$connections` variable only it used; the request's variables still carry `connections`, which the server ignores.}}

Removing is `@deleteEdge(connections:)` on a field holding the removed node's id, or `@deleteRecord` on a field holding the id of a record to delete outright. [Lists](../lists/) shows the edit in the store.

## A payload committed by hand

The same door a server's response comes through takes a payload from anywhere else: a REST response, a socket's tick, a preview's fixture, a test's seed. `environment.commitPayload(operation, payload)` runs the operation's plan over the bytes and commits them as a fetch's response is committed. A payload may carry part of what the operation selects, and it alone writes client fields.

```swift tab
try await environment.commitPayload(CharacterQuery(id: "1"), Payload(json: fixture))
```

```kotlin tab
environment.commitPayload(CharacterQuery(id = "1"), Payload(fixture))
```

A mutation outside any view is `environment.mutate(operation, optimistic:)`, with the same optimistic payload.

## What never to write

- **A cache updater.** No function edits the store after a mutation. What a mutation changes is what its payload selects; a list it changes is an edge directive; what it shows first is its optimistic response.
- **A model that copies a lens's fields** to hold them across the call. Read the lens inside the action's closure, on the main actor; the values are a slot load away.
- **A write the server does not know about.** Client fields are described in a schema extension and committed as a payload; nothing is set on a record by hand.

[Porting from Relay](../../recipes/porting-from-relay/) lists the Relay write APIs that are not here and the reason for each.
