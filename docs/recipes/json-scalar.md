# A `Json` scalar read as a value

Some schemas declare a scalar for JSON and use it wherever a value has no
type of its own. AniList's is `Json`. It carries `MediaList.customLists`,
the user's custom lists and whether an entry is in each, and
`MediaList.advancedScores`, a map keyed by the names the user gave their
scoring sections. It also carries `ThreadComment.childComments`, a tree of
replies.

A custom scalar is stored as its text, the bytes the server wrote, an
array or an object included. Unmapped, it reads as that text, a `String`.
Mapped under `customScalarTypes` to a type of the app's, it reads as that
type, converted from the text at every read. That is the whole mechanism.
This page is the type for `customLists`.

## Ask for the array

`customLists` without arguments is an object keyed by the user's list
names, `{"Up Next": true}`. With `asArray: true` it is an array of
objects, one per custom list of the user's, each with its name and
whether the entry is in it:

```json
[{"name": "Up Next", "enabled": true}]
```

That is what AniList's API answered on 2026-10-18, and what its schema
describes: "an array of objects". The type that reads it needs no keys of
the user's, only a name and a flag in each element.

## In Swift

The type conforms to `MappedScalar`: an initializer from the text, which
returns nil when the text does not convert, and the text a server
receives for the value. The type is `public`, because the generated lens
is public and its accessor names the type:

```swift
import Baton
import Foundation

/// `MediaList.customLists(asArray: true)`: each of the user's custom lists,
/// and whether the entry is in it.
public struct CustomLists: MappedScalar {
    public struct List: Hashable, Sendable, Codable {
        public let name: String
        public let enabled: Bool
    }

    public let lists: [List]

    /// The names of the lists the entry is in.
    public var names: [String] { lists.filter(\.enabled).map(\.name) }

    public init?(scalarText: String) {
        guard let lists = try? JSONDecoder().decode([List].self, from: Data(scalarText.utf8)) else { return nil }
        self.lists = lists
    }

    public var scalarText: String {
        String(decoding: (try? JSONEncoder().encode(lists)) ?? Data("[]".utf8), as: UTF8.self)
    }
}
```

## In Kotlin

A Kotlin type the runtime does not own cannot implement an interface of
the runtime's, so the type is a plain data class, and an `object`
implementing `ScalarConverter` parses and renders it. The parse here uses
kotlinx.serialization's JSON tree, `Json.parseToJsonElement`, from
`org.jetbrains.kotlinx:kotlinx-serialization-json`, which needs no
compiler plugin. That `Json` is the library's object; AniList's scalar of
the same name is not a type in the generated code.

```kotlin
import baton.ScalarConverter
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put

/** `MediaList.customLists(asArray: true)`: each of the user's custom lists, and whether the entry is in it. */
data class CustomLists(val lists: List<CustomList>) {
    data class CustomList(val name: String, val enabled: Boolean)

    /** The names of the lists the entry is in. */
    val names: List<String> get() = lists.filter { it.enabled }.map { it.name }
}

/** Reads AniList's `Json` as [CustomLists] at the read, and writes it back. */
object CustomListsConverter : ScalarConverter<CustomLists> {
    override fun parse(text: String): CustomLists? = runCatching {
        CustomLists(
            Json.parseToJsonElement(text).jsonArray.map {
                val list = it.jsonObject
                CustomLists.CustomList(list.getValue("name").jsonPrimitive.content, list.getValue("enabled").jsonPrimitive.boolean)
            },
        )
    }.getOrNull()

    override fun render(value: CustomLists): String =
        JsonArray(value.lists.map { buildJsonObject { put("name", it.name); put("enabled", it.enabled) } }).toString()
}
```

## The configuration

`baton.json` names the type for each language. Swift's entry is the type,
and Kotlin's is the type and its converter, each by its full name:

```json
{
  "schema": "schema.graphql",
  "customScalarTypes": {
    "Json": {
      "swift": "CustomLists",
      "kotlin": { "type": "app.CustomLists", "converter": "app.CustomListsConverter" }
    }
  }
}
```

A fragment then selects the field as it always did, and the accessor
reads the type:

```graphql
fragment EntryRow_mediaList on MediaList {
  id
  status
  progress
  hiddenFromStatusLists
  customLists(asArray: true)
  media { id episodes title { romaji } }
}
```

`entry.customLists?.names` is the lists the entry is in, in Swift and in
Kotlin. The accessor is optional wherever the schema puts the field,
because a mapped scalar is a fallible read
([the decision](../decisions/a-mapped-scalar-is-a-fallible-read.md)). A
text that does not convert reads nil and is logged as the `unexpected`
event. It is never treated as missing data, which would refetch it
forever.

## One type for the scalar

`customScalarTypes` maps a scalar, not a field, as Relay's does. Every
`Json` field the app's documents select reads as `CustomLists`. A field of
another shape, `advancedScores` say, then reads nil and is logged as
unexpected: the log says the type does not hold that shape. An app that
reads two shapes gives the type a case for each, an enum in Swift and a
sealed interface in Kotlin, and each place that reads a field takes the
case it expects.

## A map stays a type of the app's

`advancedScores` is a map keyed by the user's own words. It reads as a
type of the app's too, made from the text by the app's code, with reads
in the app's terms, such as a score for a section. Baton has no JSON value
type and never reads a `Json` field as a dictionary. Its read path holds
slots and values that are enums, and a dictionary keyed by a user's words
would be a record with no schema behind it.

## What a read costs

The conversion runs at every read, and nothing caches it
([the decision](../decisions/a-mapped-scalar-converts-at-the-read.md)).
A JSON decode is the app's code, and it costs what the decoder costs. A
body that reads `customLists` for five hundred rows decodes five hundred
times each time it runs. Read it where it is shown, or derive from it in
one place, as [the unpaged collection](unpaged-collection.md) does when
it groups a list.

A variable of a mapped type is sent as its text. AniList takes no `Json`
argument where an app writes custom lists: `SaveMediaListEntry` takes
`customLists: [String]`, the names the entry should be in. So
`scalarText` renders the array for the protocol's sake, and no request
carries it.

The code on this page was compiled in both runtimes against AniList's
schema on 2026-10-18, with the configuration above.
