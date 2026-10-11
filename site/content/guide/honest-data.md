# Honest data

Nullability is what the schema says. Missing data is reported and healed, never invented silently. A field error survives caching and is visible where it occurred. Staleness is a phase a view can read. This chapter is the directives and the types that make those four sentences true, each with the fixture or the lens that shows it.

## Types follow the schema

A non-null field is a non-optional property; a nullable one is optional. That is the whole rule, and it means a view stops guarding what the server promises and stops trusting what it does not. The lens plate on any page shows it: `title` on GitHub's `Issue` is `String!` in the schema and a `String` in Swift; `name` on Rick and Morty's `Character` is `String` and reads as an optional.

{{lens catch RepositoryQuery | A lens with the three shapes this chapter is about: `repository` reads a `Result` under `@catch`; the row's spread reads as optional because the row requires an author; `description` is optional because the schema says so.}}

## `@required`: a field the view cannot do without

Some nulls the schema allows are nulls the product has no use for: a row for an issue whose author is gone has nothing to show. `@required(action:)` moves the null up to where the product wants to handle it:

- `NONE` and `LOG` make the field non-optional and bubble the null to the lens boundary: the accessor that produces the lens produces nil instead, and `LOG` logs the path through the environment's log.
- `THROW` makes the field's accessor throw a required-field error, and a root that throws fails the operation with the path of the first required field that was null.

{{host catch RepositoryScreen.swift | The row requires its author; an issue without one reads as no row, and the screen's `if let row` skips it. The environment logs where.}}

## `@catch`: an error the view shows

A field error, a server's failure to resolve one field, is stored beside the field in the record, with its message, its path and its `extensions`, so a cached read sees the same error the network read saw. A plain read sees null; `@catch` reads a `Result`, success with the value or failure with the errors, so the view can say what went wrong:

```swift tab
switch data.repository {
case .failure(let errors): Text("Could not load the repository: \(errors.description)")
case .success(nil): Text("No such repository")
case .success(let repo?): RepositoryBody(repo)
}
```

```kotlin tab
val caught = data.repository
when {
    caught.exceptionOrNull() != null -> Text("Could not load the repository")
    caught.getOrNull() == null -> Text("No such repository")
    else -> RepositoryBody(caught.getOrThrow())
}
```

`@catch(to: NULL)` keeps the optional type and reads errors as null, for a field the view would rather blank. `@throwOnFieldError` on a fragment or an operation is the strict policy: an uncaught error inside fails the read, or the operation, with the errors, and fields the schema marks `@semanticNonNull` read non-optional under it. An app that wants a server's `onError` behaviour states it once in `baton.json`, and the compiler sends it with every operation.

{{script notifications steps=4,5,6 | Field errors are data: a response that carries errors for three fields notifies those three slots, and a response that answers them notifies them again. A view reading through `@catch` sees the error, then the value.}}

A response with errors and no data at all is not a field error but a request error: the whole fetch fails, the phase reads failed with the server's errors, and a retry is one call away.

## Missing data heals

Missing data is the one case the types cannot express. It arises when a link is retargeted by another operation to a record fetched with fewer fields: a list fetched a location's name, a detail fetched its dimension, and a later response points the character's `origin` at a location the store knows only by name. Then a read of `dimension` finds no slot. Baton does not invent a value: the lens reads nil, the event is logged with the type and the field, the owning operation is marked stale and refetched once, and the view shows a blank for a moment and then the truth.

{{script heal steps=1,2,3,4 | A read that finds `Location.dimension` missing logs it and refetches the owner; the refetch restores the value; a second miss after the heal's own refetch is logged as unexpected and healed no further.}}

A value the generated type cannot hold, a null in a non-null field or a number where a string was promised, is logged as unexpected in the same way, and never read as a zero that looks like data.

## Enums

A schema enum compiles to an enum of its own, with a case per value the build knows and one more carrying the text of a value it does not, so a value the schema gained after the build reads as itself rather than failing the read. Swift's case is `unknown(String)`; Kotlin's is `Undeclared(scalarText)`.

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

A custom scalar is stored as its text, exactly as the server wrote it, and reads as a string; or `customScalarTypes` in `baton.json` maps it to a type of the app's, `Decimal`, `Date`, `URL` and `UUID` out of the box, and the read converts the text at the read. Because a conversion can fail, the accessor is optional wherever the schema puts the field, unless `@required` or `@throwOnFieldError` says what a failure does; a text that does not convert is reported as unexpected, never read as a zero.

```json
{
  "customScalarTypes": {
    "DateTime": { "swift": "Foundation.Date", "kotlin": { "type": "java.time.Instant", "converter": "app.DateTimes" } }
  }
}
```

## Input objects

An input object compiles to a value type with a field per field, typed as the schema types it, so a misspelled input field is a compile error where it was a server's error before. A field left unset is absent from the request, as GraphQL distinguishes absent from null.

```swift tab
try await addComment(input: AddCommentInput(body: body, subjectId: subjectID), connections: [connectionID])
```

```kotlin tab
addComment(input = AddCommentInput(body = body, subjectId = subjectID), connections = listOf(connectionID))
```

## Staleness is a phase

A handle reads `isStale` beside its phase: true when the data is older than the operation's expiration or was marked stale by an invalidation, and the age survives a launch because the image keeps it. Stale data stays visible; what to do about it is the app's call, a refresh on appearance or a revalidation on return. [Reads](../reads/) has the policies.

## The principle behind it

[Honest data](../../principles/honest-data/) is the principle: why every client lies in small ways that compound, and the mechanisms, fixtures and events that keep this one from doing so.
