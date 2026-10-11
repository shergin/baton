# GraphQL for mobile engineers

You have built screens on REST: an endpoint per resource, a model struct per response, a view model that merges three calls into what the screen shows. This page is GraphQL explained from there, with a real API, a real response and the real records a store made of it. Every word that matters is in [the terminology](../terminology/); this page is the tour.

## The menu

A GraphQL server publishes a **schema**: every type, every field, and whether each field can be null. Think of it as the whole menu, written down once. Here is the whole schema of the public Rick and Morty API, which this site uses because it fits on one screen:

{{source spec/rickandmorty/schema.graphql | The schema, as checked into the repository. `Query` is the root: the fields you can ask for first. `Character`, `Location` and `Episode` are the things; `[Episode]!` is a list that is never null, of episodes that may be.}}

Read it the way you read a REST API's documentation, except that it is machine-checkable: a tool can tell you, before your app runs, that `Character` has no field called `nmae`.

## The order

A **document** is what you send: a selection of fields, nested as deep as you like. The server answers with exactly that shape and nothing else, in one round trip. This is a **query**, the read kind of **operation**, with one **variable**:

{{source spec/sources/TestHeaderQuery.graphql | A query with a variable, `$id`, and a fragment spread, `...TestHeader_character`. The fragment is below.}}

{{source spec/sources/TestHeader_character.graphql | A fragment: a named piece of a selection on one type. Think of it as the fields one view needs, with a name. The query above spreads it, and the text the server receives carries the fragment after the operation, as the compiler prints it.}}

The response is the order, filled. Its keys are the document's field names, its nesting is the document's nesting, and there is nothing in it you did not ask for:

{{json spec/rickandmorty/character-header-9.json | The response, recorded from the API for `id: "9"`. The `id` fields, on the character and under `origin`, are there because the compiler asked for them; the next section says why.}}

Three things to notice, because they change how you build:

- **No over-fetching.** The REST endpoint for a character returns every field the character has, a dozen; this response has the five the view reads. A screen fetches what its views render.
- **No waterfalls.** Ask for the origin's dimension as well and it comes in the same round trip as the character. On REST the character embeds only its origin's name and link, and the dimension is a second call after the first answered.
- **The contract is in the build.** The document is checked against the schema when the app is compiled. A field the server renames is a build error at the character in the text, not a decoding failure in production.

## Null is a word in the schema

Look at the schema again: `name: String` may be null, `episode: [Episode]!` may not. That is a promise the server makes per field, and a client honours it in the types: a nullable field is an optional, a non-null field is not. You stop writing `?? ""` where the schema says a value is always there, and you stop pretending a value is always there where it is not. The Rick and Morty API marks nearly everything nullable, which is why the row views on this site read `character.name ?? "Unknown"`. GitHub's marks `title` and `number` non-null, so a row over GitHub reads them straight.

Relay adds two directives for the cases the types cannot express on their own, and Baton keeps both: `@required` says a view cannot do without a field, and moves the null up to where the product wants to handle it; `@catch` turns a field's error into a value the view can show. [Honest data](../guide/honest-data/) is the chapter.

## The id, and why one store

Every object in a good schema carries an `id`. It is the reason a client can keep one copy of each thing: the Rick who appears in the characters list, in the cast of an episode and among the residents of a location is one `Character:1`, whatever path reached him. A client that stores responses by URL keeps three copies and shows a stale star on two of them; a client that stores records by type and id keeps one.

This is **normalization**, and it is the single idea that makes the data layer disappear. Hover a field in the response below and watch where it went:

{{normalize spec/rickandmorty/character-header-9 | The response on the left became the records on the right: `Character:9`, `Location:20`, and the root record that holds the link `character(id:"9")`. A nested object with an id became its own record, referenced by a link; a field without arguments is stored under its name, a field with arguments under its name and its arguments.}}

Nothing here was typed by hand: the records are the dump the runtime wrote under the specification's fixtures, and the walk that links a path to its slot follows the links in the dump. A response that arrives later for the same character, from any screen, lands in the same `Character:9`, and every view reading it sees the change.

## Lists that page

A list that grows as you scroll is a **connection**, a convention from Relay that most schemas follow: `edges` holding `node`s with a `cursor` each, `pageInfo` with `hasNextPage` and `endCursor`, and arguments `first` and `after` that ask for the next page from a cursor. It looks heavier than an array, and it is, because it carries exactly what paging needs:

{{source spec/sources/TestNotes_character.graphql | A fragment that owns a connection. `@connection(key:)` names the list in the store; `@refetchable` gives the fragment a query of its own to fetch the next page with; `@argumentDefinitions` declares the page size and the cursor as the fragment's own arguments.}}

The payoff is in [Lists](../guide/lists/): the store merges each page into one list, and a view reads `nodes`, `hasNext` and calls `loadNext`. The Rick and Morty API itself pages by number, which is un-Relay-like and the reason the GitHub samples carry the connection examples.

## Writes

A **mutation** is an operation that changes something and then selects what it changed, like a `POST` whose response you get to shape:

{{source spec/sources/TestAddNote.graphql | A mutation with its variables, selecting the new edge from the payload. What a mutation changes is what its payload selects; the store merges it like any response.}}

Because the payload is a selection like any other, the records it names are updated in place and every view reading them re-renders. Adding to a list is a directive on the payload, `@appendEdge`, rather than code that edits a cache. And a mutation can carry an **optimistic response**, a typed value shown at once and replaced by the server's answer or reverted if the server refuses. [Writes](../guide/writes/) steps through one.

## Subscriptions

A **subscription** is the third kind of operation: a stream of events from the server, each one a selection in the same shape as a query's response. In Baton each event is committed to the store like any payload, so a view that reads the record it names updates, and a directive on the event can append it to a connection. [Live data](../guide/live/) covers the stream, reconnecting, and what happens while the app is in the background.

## Errors are data too

A GraphQL response can carry both `data` and `errors`, and an error has a `path` that says which field failed. A client that swallows that into a `null` shows an empty label and tells no one. Baton stores a field's error beside the field, so a cached read sees the same error the network read saw, and `@catch` lets a view decide what to show. A response with errors and no data at all is a failure of the whole fetch: with nothing in the store the phase reads failed, with a retry; with data already there, the data stays and the fetch carries the failure.

## What Relay adds, and what Baton keeps

GraphQL alone moves the plumbing; it does not remove it. A query per screen still has to be written and kept in sync with every view on it, and the response still has to be decoded and copied into view models. Relay's answer, which Baton brings to SwiftUI and Compose, is:

- **A fragment per view, beside the view.** Each view declares the fields it reads, next to its body. The compiler assembles the screen's one query from the fragments of its views. A row that starts showing a date adds `createdAt` to its own fragment, and nothing else changes.
- **A view reads only what it declared.** The parent hands the child a lens, not data. The child reads its own fields through it and cannot reach the parent's.
- **One store.** Every response is normalized into records by type and id, and the UI framework observes the records directly: a view re-renders when a field it read changes, and at no other time.
- **Declarative writes.** A mutation selects what it changed, names the list it adds to with a directive, and may carry an optimistic response. No code edits the cache.

[Why GraphQL](../why-graphql/) is the same argument in the repository's words, with the view model's fate spelled out, and [One screen, end to end](../walkthrough/) follows a screen through all of it.

## What it costs

- **A GraphQL server.** If the backend is REST, a GraphQL layer stands in front of it, and someone owns it. Any server that follows the specification works, with no plugin for Baton.
- **A schema in the build.** The compiler reads the schema's SDL from a file you check in; a change to it is a change the build sees.
- **Server discipline.** Clients choose the shape, so the server guards against expensive selections. Persisted operations narrow the requests to the documents the apps were built with.
- **New habits.** A fragment per view, and no copied state. [Getting started](../start/) builds the first screen that way.
