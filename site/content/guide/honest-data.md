# Honest data

Nullability is what the schema says. Missing data is reported and healed, never invented silently. A field error survives caching and is visible where it occurred. Staleness is a phase a view can read. This chapter is the directives and the types that make those four sentences true, each with the fixture or the lens that shows it.

## Types follow the schema

A non-null field is a non-optional property, and a nullable one is optional. That is the whole rule. A view stops guarding what the server promises, and stops trusting what the server does not promise. The lens plate on any page shows it. `title` on GitHub's `Issue` is `String!` in the schema and a `String` in Swift. `name` on Rick and Morty's `Character` is `String`, and it reads as an optional.

{{lens catch RepositoryQuery | A lens with the three shapes this chapter is about. `repository` reads a `Result` under `@catch`. The row's spread reads as optional because the row requires an author. `description` is optional because the schema says so.}}

## `@required`: a field the view cannot do without

Some nulls the schema allows are nulls the product has no use for. A row for an issue whose author is gone has nothing to show. `@required(action:)` moves the null up to where the product wants to handle it.

- `NONE` and `LOG` make the field non-optional and bubble the null to the lens boundary. The accessor that produces the lens produces nil instead, and `LOG` logs the path through the environment's log. A null that bubbles all the way to an operation's root fails the operation, with the path of the first required field that was null.
- `THROW` makes the field's accessor throw a required-field error, at the read.

{{host catch RepositoryScreen | The row requires its author. An issue without one reads as no row, and the screen's `if let row` skips it. The environment logs where.}}

## `@catch`: an error the view shows

A field error is a server's failure to resolve one field. It is stored beside the field in the record, with its message, its path, and its `extensions`, so a cached read sees the same error the network read saw. A plain read sees null. `@catch` reads a `Result`, success with the value or failure with the errors, so the view can say what went wrong.

```swift tab
switch data.repository {
case .failure(let errors): Text("Could not load the repository: \(errors.description)")
case .success(nil): Text("No such repository")
case .success(let repo?): RepositoryBody(repo)
}
```

```kotlin tab
val caught = data.repository
val repo = caught.getOrNull()
when {
    caught.exceptionOrNull() != null -> Text("Could not load the repository")
    repo == null -> Text("No such repository")
    else -> RepositoryBody(repo)
}
```

`@catch(to: NULL)` keeps the optional type and reads errors as null, for a field the view would rather blank. `@throwOnFieldError` on a fragment or an operation is the strict policy. An uncaught error inside fails the read, or the operation, with the errors. Fields the schema marks `@semanticNonNull` read non-optional under it. An app that wants a server's `onError` behaviour states it once in `baton.json`. The compiler writes it into every operation, and the runtime sends it.

{{script notifications steps=5,6 | Field errors are data. A response that carries errors for three fields notifies those three slots, and a response that answers them notifies them again. A view reading through `@catch` sees the error, then the value.}}

A response with errors and no data at all is not a field error. It is a request error, and the whole fetch fails. With nothing in the store, the phase reads failed, with the server's errors, and a retry is one call away. With data already there, the data stays and the fetch carries the failure.

## Missing data heals

Missing data is the one case the types cannot express. It arises when another operation retargets a link to a record fetched with fewer fields. A list fetched a location's name, and a detail fetched its dimension. A later response points the character's `origin` at a location the store knows only by name, so a read of `dimension` finds no slot. Baton does not invent a value. The lens reads nil, the event is logged with the type and the field, and the owning operation is marked stale and refetched once. The view shows a blank for a moment, and then the truth.

{{script heal steps=1,2,3,4 | A read that finds `Location.dimension` missing logs it and refetches the owner. The refetch restores the value. A second miss, after the heal's own refetch, is logged as unexpected and healed no further.}}

A value the generated type cannot hold is logged as unexpected. That is a null in a non-null field, or a string where an integer was promised, and it reads as nil, or as the zero value where the type has no nil. A mapped scalar that does not convert never reads as a zero at all.

## Enums

A schema enum compiles to an enum of its own, with a case per value the build knows and one more case carrying the text of a value it does not. A value the schema gained after the build reads as itself, rather than failing the read. Swift's case is `unknown(String)`, and Kotlin's is `Undeclared(scalarText)`.

```swift tab
extension IssueState {
    var word: String {
        switch self {
        case .OPEN: "open"
        case .CLOSED: "closed"
        case .unknown(let text): text.lowercased()
        }
    }
}
```

```kotlin tab
val IssueState.word: String
    get() = when (this) {
        IssueState.OPEN -> "open"
        IssueState.CLOSED -> "closed"
        is IssueState.Undeclared -> scalarText.lowercase()
    }
```

## Custom scalars

A custom scalar is stored as its text, exactly as the server wrote it, and it reads as a string, or `customScalarTypes` in `baton.json` maps it to a type of the app's. In Swift, `Decimal`, `Date`, `URL`, and `UUID` already are such types, and in Kotlin the mapping takes a converter object. The text is converted at the read. A conversion can fail, so the accessor is optional wherever the schema puts the field, unless `@required` or `@throwOnFieldError` says what a failure does. A text that does not convert is reported as unexpected, never read as a zero.

```json
{
  "customScalarTypes": {
    "DateTime": { "swift": "Foundation.Date", "kotlin": { "type": "java.time.Instant", "converter": "app.DateTimes" } }
  }
}
```

## Input objects

An input object compiles to a value type with a field per field, typed as the schema types it. A misspelled input field is a compile error, where before it was a server's error. A field left unset is absent from the request, and GraphQL distinguishes absent from null.

```swift tab
try await addComment(input: AddCommentInput(body: body, subjectId: subjectID), connections: [connectionID])
```

```kotlin tab
addComment(input = AddCommentInput(body = body, subjectId = subjectID), connections = listOf(connectionID))
```

## Staleness is a phase

A handle reads `isStale` beside its phase, true when the data is older than the operation's expiration or was marked stale by an invalidation. The age survives a launch, because the image keeps it. Stale data stays visible. A `storeOrNetwork` attach refetches it, and a revalidation on the app's return refetches whatever went stale meanwhile. [Reads](../reads/) has the policies.

## The principle behind it

[Honest data](../../principles/honest-data/) is the principle: why every client lies in small ways that compound, and the mechanisms, fixtures, and events that keep this one from doing so.
