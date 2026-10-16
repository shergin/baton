# Reads

A screen declares one query and reads its data through a lens. A view declares one fragment and reads through its own. This chapter is the read side: the handle a query resolves to, the phase it reads, what a parent hands a child, and the policies that decide when the network is asked.

## A query per screen

The screen's document is a query with variables, carried by a marker. The compiler turns it into an operation value, a struct of the variables in Swift and a class in Kotlin. The parent constructs it, and the view resolves it when it appears.

{{host header CharacterScreen | A screen with one variable. In Swift the operation value is the view's stored property, resolved by the `@Query` macro. In Kotlin `rememberQuery` resolves it in the composable.}}

Resolving works like this. The environment makes or shares a handle for that value, and the handle checks the store. If the store holds everything the operation selects, the first body renders it. Otherwise the environment fetches, and the body renders `loading` until the answer is committed. Two views that resolve equal values share one handle and one fetch.

## The phase

A handle's phase is `loading`, `ready(data)`, or `failed(error)`. You can always read it, and you never await it. Beside it sit three more values. `isRefreshing` is true while a fetch runs behind data. `isStale` is true when the data is older than the operation's expiration, or was marked stale. `fetch` is the last fetch as a value: idle, in flight, or failed with a kind. A view switches over the phase and renders each case, and a retry is a call on the handle.

{{script phase | Every phase the specification scripts, with the fetch beside it. Note the handles that read `ready` while refreshing, the one whose refresh fails and keeps its data, and the one attached under `storeOnly` with nothing in the store. That one fails with missing data and fetches nothing.}}

## Fetch policies

You pick one of Relay's four where a handle is attached. `storeOrNetwork` is the default: it renders what the store has and fetches when the store cannot answer or the data is stale. `storeAndNetwork` renders and fetches. `networkOnly` shows loading until its own response, unless another holder already shows the handle. `storeOnly` never fetches. In Swift the policy is an argument of `@Query`, and in Kotlin it is an argument of `rememberQuery`.

```swift tab
@Query("…", fetchPolicy: .storeAndNetwork) var issues: IssuesQuery
```

```kotlin tab
val query = rememberQuery(IssuesQuery(owner, name), fetchPolicy = FetchPolicy.STORE_AND_NETWORK)
```

A refetch asks the network again, whatever the policy. `environment.invalidate()` marks everything stale and refetches what is retained. `environment.revalidate()` refetches what is stale or failed, for a return to the foreground. A query may state its own expiration with `@cacheExpiration(seconds:)`, and the store may be given a default for the rest. Data past that expiration reads as stale, and a `storeOrNetwork` attach refetches it, as a revalidation does.

{{script ages steps=1,2,3,4,5,6 | Two operations over the same character, under the store's default expiration of a minute. The second states thirty seconds of its own. As the clock advances the second reads stale first, then both. A revalidation refetches both, since both are stale by then.}}

## A fragment per view

A view declares the fields it reads and takes the fragment's lens. The lens is the fragment compiled: one accessor per declared field, typed as the schema types it, over the record the parent handed over.

{{host header CharacterHeader | The header reads five fields of one record, one of them through a link, and gets a lens with exactly those five accessors.}}

{{lens header CharacterHeader_character | In the lens as reported, `origin` is a nested lens over the linked record, and nothing the fragment did not declare exists on the type.}}

A parent spreads the fragment and hands the child its lens through the spread's accessor. The accessor is named after the fragment, `characterHeader` for `CharacterHeader_character`, or named by `@alias(as:)`. The parent cannot read the child's fields through it, and should not try. A view that reads another view's fields grows a dependency nobody declared.

## Reading through the lens

Every accessor is a synchronous read on the main thread: it loads a slot and registers the read with the UI framework. Reading `character.name` costs what reading an `@Observable` property costs. A body that read a field depends on that field of that record, and on nothing else. [The store](../store/) is where the notification side lives.

What an accessor reads follows the schema. A nullable field is an optional. A non-null field is not. A list of nullable elements is a list of optionals. A list of records is a collection of lenses, `List` in Swift and `LensList` in Kotlin, each lens keyed by its record. Interfaces and unions add an accessor per concrete type, `asIssue`. A spread inside an inline fragment on them carries `@alias`, as Relay requires.

{{host catch RepositoryScreen | A list of lenses, a spread that may read as absent, and a field under `@catch`. Honest data covers the last two.}}

## Refetch, retry, invalidate

- `refetch()` on a handle sends the operation again and commits the answer. The data stays while it runs, and a body wakes only if something changed.
- `retry()` comes after a failure. With data behind the failure it is a refetch, and after any other failure the phase reads loading again.
- `refetch()` on a refetchable fragment's lens runs the fragment's own query with its arguments and updates the records in place, and new arguments replace the lens.
- `environment.fetch(operation)` fetches by hand, outside any view, for a refresh of rows by id or a prefetch. [Discover once](../../recipes/discover-once/) is the pattern.

## Lookups

A root field that names a record by id, `node(id:)` or `character(id:)`, can be answered from the store before the network. `baton.json` declares the lookup. The availability check binds the field to the record it already holds, so a detail screen opened from a list renders in the first frame when the list fetched everything the detail selects. Otherwise the detail is fetched whole. The binding happens in the check, never in a read, so a read stays a slot load.

```json
{
  "schema": "schema.graphql",
  "lookups": [
    { "field": "Query.character", "type": "Character", "argument": "id" },
    { "field": "Query.node", "argument": "id" }
  ]
}
```

## Values, when a lens will not do

A rule outside a view, a share sheet, a comparison off the main thread: these want a value, not a live lens. A fragment marked `@inline` compiles to a plain value of its fields, built from the record when the spread's accessor is called, and a test builds one with its initializer. A fragment is a lens or a value, never both.

{{host inline Rules | An inline fragment, the rule that takes its value, and the screen that builds the value in its body and hands it on.}}
