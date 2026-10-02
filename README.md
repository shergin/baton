# Baton

**Status: pre-0.1, under construction.** Nothing usable yet. The design is
written; the code is not.

Relay for SwiftUI and Compose. A view declares the GraphQL fragment it reads,
beside its body. The compiler aggregates the fragments of a screen into one
operation, validates everything against the schema at build time, and emits a
small typed lens per fragment. The runtime normalizes responses into records
that the UI framework itself observes, so a screen fetches once, renders
cached data in the first frame, and re-renders only the views whose fields
changed.

Baton is aligned with Relay, not Apollo: the same directives, the same
conventions, the same compiler lineage. A team running Relay on the web and
Baton on native speaks one language. Where Relay's design is React's rather
than GraphQL's (snapshots, re-reads, suspension by thrown promises), Baton
leaves it out: SwiftUI's Observation and Compose's snapshot state already know
which view read which field.

The design is in [`docs/vision.md`](docs/vision.md). Constraints it assumes
live in [`docs/principles/`](docs/principles/). The vocabulary is
[`docs/terminology.md`](docs/terminology.md).

## What it will be

- **A fragment per view.** GraphQL lives in the Swift file, next to the view
  that reads it, as a full, valid document. A parent passes a child its
  fragment as a pointer-sized value; a child can read nothing it did not
  declare.
- **One request per screen.** The compiler assembles the operation from the
  fragments spread into it and emits a persisted id for it. Nobody writes the
  screen's query by hand, and nothing waterfalls.
- **Cached data in the first frame.** Reads are synchronous on the main
  actor; a handle resolves against the store before the first body runs.
  Decoding, normalization, persistence and garbage collection run off it.
- **Only changed views re-render.** Records are observable objects; a body
  that read `user.name` is invalidated when that field of that record changes
  and at no other time. A commit of a thousand records costs tens of
  microseconds on the main thread.
- **Honest data.** Nullability is what the schema says; `@required` and
  `@catch` work as in Relay; field errors survive caching; staleness is a
  phase a view can read.
- **Small everything.** Generated code is one line per field plus data
  tables. The runtime depends on Foundation and Observation. The compiler is
  one prebuilt binary, shared by the Swift and (later) Kotlin runtimes.

## What it will not be

- Not a runtime GraphQL client: every operation is known at build time. No
  query builders, no string queries, no GraphQL parser in the app.
- Not a model layer: there is nothing decoded to hold, mutate or persist
  besides the store itself.
- Not configurable by policy objects: identity is schema configuration
  compiled in; behaviour is a directive or a value on a handle.
- Not an offline-sync engine, a local-state framework, a server, or a React
  Native or web client.
- Not one runtime for two platforms: the Swift and Kotlin runtimes are
  separate and idiomatic; the compiler, the artifact format, the vocabulary
  and the conformance fixtures are shared.

## The feel

Illustrative, not final.

```swift
struct CharacterRow: View {
    @Fragment("""
        fragment CharacterRow_character on Character {
          name
          status
          image
        }
        """)
    var character: CharacterRow_character

    var body: some View {
        HStack {
            AsyncImage(url: character.image)
            Text(character.name)
            Text(character.status)
        }
    }
}

struct CharactersScreen: View {
    @Query("""
        query CharactersScreenQuery($page: Int) {
          characters(page: $page) {
            results { id ...CharacterRow_character }
          }
        }
        """)
    var characters: CharactersScreenQuery

    var body: some View {
        switch characters.phase {
        case .ready(let data):
            List(data.characters.results) { CharacterRow(character: $0.characterRow) }
        case .loading:
            ProgressView()
        case .failed(let error):
            ErrorView(error) { characters.retry() }
        }
    }
}
```

## The name

In a relay, the baton is the thing that is actually handed over. Here it is
the data a screen hands each view: exactly what the view asked for, nothing
else.

## License

Licensed under either of [MIT](LICENSE-MIT) or [Apache-2.0](LICENSE-APACHE),
at your option.
