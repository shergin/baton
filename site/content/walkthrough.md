# One screen, end to end

A character's header, small enough to follow every step: a name, a status, a species, a picture, and where the character is from. Every step on this page is program output. The compiler compiled the documents below when the page was built, and the response is one the specification recorded from the API. The records are dumps the runtime wrote under the specification's fixtures, and the notifications and the phases are what the specification requires of both runtimes.

## 1. A fragment beside the view

The view declares the fields it reads, next to its body, and takes a lens as its one input. A lens is a typed window onto one record, so the view cannot read a field it did not declare: the lens has no accessor for one.

{{host header CharacterHeader | The header's fragment and its body. `origin { name }` reads through a link to another record. The lens makes that a nested lens.}}

## 2. One query for the screen

The screen declares one query and spreads the header's fragment into it. The parent never lists the header's fields. It hands the header its lens through the spread's accessor, `characterHeader`.

{{host header CharacterScreen | The screen's query, with one variable, and the three cases of its phase. `@cacheExpiration(seconds: 300)` says data older than five minutes reads as stale.}}

## 3. What the compiler makes of them

The compiler reads the schema and every document in the module, validates them, assembles the operation from the fragments it reaches, and adds the fields identity needs. This is the text the app will send, printed on one line as the compiler prints it.

{{operation header CharacterQuery | The operation's text, the fragment printed after it. The compiler added `id` to the character and under `origin`, because both types are keyed by id and the store needs the keys to make the records. The directive on the query stays out of the text, since it is the client's business.}}

For each fragment and each operation, the compiler emits a lens. You get one accessor per declared field, typed as the schema types it.

{{lens header CharacterHeader_character | The header's lens. `name` is optional because the schema says so. `origin` is a nested lens. Nothing else exists on the type.}}

The compiler writes the code too. The generated Swift is one line per field, plus the data tables the runtime walks a response by, and there is no model, no decoder, and no cache policy in it.

{{generated header | What the compiler wrote for the two files above. The lens reads a slot per field through the anchor it holds. A slot is one field of one record. The anchor is the record the lens is looking at. The operation value carries its variables, its text, and its plan.}}

## 4. The request

The view appears, and its handle checks the store. Nothing is there yet, so the environment sends the operation through the transport. The request is the text above, with `{"id": "9"}` as the variables, as a standard GraphQL-over-HTTP request. Under `persistConfig` it would send the id of the text instead, and the server would look the text up.

While the request is out, the view reads `phase` as `loading`. Here is what a handle shows at each moment, from the specification's script of phases.

{{script phase steps=1,2,3,4,5 | A handle attached with nothing in the store is loading with a fetch in flight. The answer makes it ready. A second attach of the same operation is ready at once, with no fetch. One attached under `storeAndNetwork` is ready and refreshing. When its refresh fails, the data stays and the fetch records the failure.}}

## 5. The response

The server answers in the document's shape.

{{json spec/rickandmorty/character-header-9.json | The recorded response for `id: "9"`. Five values, two objects, and the two ids the compiler asked for.}}

## 6. The records

The response's bytes are decoded straight into record slots, off the main actor, by the plan the compiler emitted. They are committed on the main actor as one batch. Hover a field to see where it went.

{{normalize spec/rickandmorty/character-header-9 | Three records: `Character:9`, `Location:20`, and the root that links to the character under its storage key, `character(id:"9")`. The `origin` slot holds a link, not a copy.}}

## 7. The reads

The specification's manifest says what the lens must read at each path after that commit. Both runtimes are held to it.

{{case rickandmorty/character-header-9 | The reads the fixture requires, and the override below them. Under an optimistic response that changes the name, the lens reads the new name until the server answers.}}

The view's body runs. `character.name` loads a slot. So do `status`, `species`, and `image`. `origin` follows the link, and `origin.name` loads a slot of the other record. Each read registers with Observation. The body now depends on exactly six slots of those two records: five on the character, the `origin` link among them, and one on the location.

## 8. A field changes

Later a refetch, another screen's query, a mutation's payload, or a subscription's event changes a record. The commit compares each slot before it writes, and notifies only the slots that changed. The specification scripts this on a character with notes.

{{script notifications steps=1,2,3 | The same response committed again notifies nothing. A response that renames the character notifies one slot, `Character:1.name`. The bodies that read it run. A body that read only the notes does not.}}

That is the whole re-render story. No watcher re-executes the query. No snapshot is diffed. A body that read a field is invalidated when that field of that record changes, and at no other time.

## 9. A write, seen at once

A mutation's optimistic response is a typed value that goes through the same ingest as a server's answer. Ingest is how a payload becomes records. The value is applied as a layer, shows in the turn of the call, and is replaced by the server's answer or reverted if the server refuses. The store notifies only what differs in the end.

{{script optimistic steps=2,4,5,6 | A rename applied optimistically notifies `name`. The server's answer resolves it with no further notification, since the value is the same. A second layer applied and reverted leaves the resolved name in place.}}

## 10. The image, and the next launch

Every server batch is written behind to an image, one SQLite file, off the main actor. When the app launches again, the handle's availability check reads what memory lacks from the image, before the first body runs. The screen the user left is the screen they get back, before any request.

{{script check steps=1,2,3,4,5,7 | A commit writes records. The check for an operation whose data is in memory answers `memory`, and for one it lacks, `miss`. After a relaunch the first check answers `image`, and the lens reads the same value. The miss is still a miss, which a handle would fetch.}}

The image is a cache, not a database. An image written under another schema, another format, or another identity configuration starts again. A record that goes a whole launch unread is dropped at the next. Optimistic layers never reach it.

## 11. Signing out

The environment is the session. Ending it cancels what it started, closes the image, and leaves every handle failed as gone. A new environment makes its own store, on the same file or another.

{{script end steps=1,2,3,4 | Two handles attached, one still fetching, and an optimistic rename applied. Then the environment ends. Every handle reads as gone, the records are cleared, and nothing is logged. Signing out is `await environment.end()` and a new environment.}}

## Run it

The screen on this page is a trimmed copy of the Rick and Morty sample, which is in the repository.

```sh
swift run RickAndMorty
```

Quit it, launch it again, and the characters are there before the network answers. Then change the header's fragment, add `type`, and build. The lens gains an accessor. The operation's text gains a field. Nothing else in the app moves. Or do the same without leaving this site, in [the playground](../playground/).
