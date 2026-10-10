# Why GraphQL

This page is for iOS and Android engineers who have built apps on REST
endpoints and view models, and who meet GraphQL for the first time through
Baton. It says what GraphQL is, what it changes in the shape of an app,
and what it does not change, by way of the questions such engineers ask
first. The vocabulary is in [`terminology.md`](terminology.md); the
argument for Baton's own design is in [`vision.md`](vision.md).

GraphQL was made at Facebook in 2012 for a native app: the iOS News Feed,
whose screens needed nested data from many endpoints and whose round trips
on a phone network were the cost that mattered. Relay, the client that put
a fragment beside every component, came from the same company in 2015. It is a
mobile technology first, and the web adopted it after.

## What it is

A server publishes a **schema**: every type it serves, every field on each
type, which fields are nullable, which take arguments. A client sends a
**document** that selects the fields it wants, nested as deep as the data
goes, and the server answers with exactly that shape in JSON. One request
asks for a repository, its open issues, each issue's author and the
author's avatar; one response carries all of it.

Three properties follow, and the rest of this page is their consequences:

- **The client decides the shape of the response.** The server decides what
  exists; the client decides what it receives.
- **The schema is a typed contract.** A document can be checked against it
  before anything is sent, so a misspelled field or a missing argument is a
  build error, not a crash in production.
- **Objects have identity.** Types that carry an `id` can be normalized: the
  same user returned by two requests is one record, and a change to it
  shows everywhere it is read.

## Questions mobile engineers ask

### Is GraphQL a database query language?

No. GraphQL is the language of an API, the layer a REST API occupies
today. The server resolves each field however it likes: from a database,
from other services, from existing REST endpoints. Nothing about the
server's storage is exposed, and the client cannot ask for anything the
schema does not declare.

### Is it REST with one endpoint?

The transport is the same, an HTTP request with a JSON body, and any
server that follows the specification answers it
([Works with your server](../README.md#works-with-your-server)). The
difference is who owns the shape. With REST, the server fixes each
endpoint's response, and a screen either takes more than it needs or
calls several endpoints in sequence, each waiting on the last. With
GraphQL, the screen's request names exactly the fields it reads, so a
screen is one round trip with nothing extra in it.

### Where do my view models go?

Most of what a view model does in a REST app is data plumbing: call the
endpoints, decode the responses into model structs, merge them, hold them,
copy the fields a view needs into published properties, and remember to
refresh them when another screen changes the same object. Under Baton
none of that is written:

- The fields a view reads are declared in a [fragment](terminology.md#documents)
  beside its body, and the view receives a typed
  [lens](terminology.md#generated) that reads exactly those fields.
- The screen's one request is assembled by the compiler from the fragments
  of the views on it.
- The response is normalized into a [store](terminology.md#store) of
  records that SwiftUI's Observation or Compose's snapshot state observes,
  so a view re-renders when a field it read changes, whichever request or
  mutation changed it.

What is left is what a view model is for when it is not plumbing: state
that belongs to the user's interaction (a draft, a selection, a sheet that
is open) and rules that compute something from the data. Those stay, in
`@State`, in a model of the app's own, or in a function over a lens or an
`@inline` fragment's value ([derived state](recipes/derived-state.md)).
A Kotlin screen with no composition can still hold the handle in a
`ViewModel` ([views and view models](recipes/views.md)). What goes away is
the copy.

### Where do my view controllers go?

Nowhere; they are not about data. Navigation, presentation, containment
and lifecycle are the platform's, as before. A screen in SwiftUI or Compose
declares its query and its views declare their fragments; a UIKit or AppKit
controller holds the same handle a view does
([UIKit and AppKit](recipes/uikit.md)). GraphQL replaces the networking and
model layer under the controllers, not the controllers.

### Where is my networking layer?

It shrinks to a [transport](terminology.md#runtime): one function that
sends a request and yields its response. Authentication, retries and
deadlines wrap that one function ([the exchange](recipes/exchange.md)).
There are no per-endpoint clients, request builders or response decoders
to write, because the compiler generates the reading side from the
documents.

### Where is my model layer?

The schema is the model, and the compiler generates the types. A view
cannot read a field it did not select, and nothing decodes a response into
a tree of structs: the response goes into records, and lenses read them in
place. There is no second definition of a user to keep in sync with the
server's.

### How does caching work without HTTP caching?

By identity rather than by URL. A REST cache keys a response by its
request, so two endpoints that return the same user hold two copies that
disagree as soon as one is refreshed. A normalized store keys each object
by its type and id, so there is one copy, and every screen that shows it
shows the latest. A screen whose data is already in the store renders it in
the first frame, and the store can be kept on disk across launches
([persistence](terminology.md#store)).

### Who keeps the list up to date after a write?

The write says so. A mutation selects the fields it changed, and those land
in the store like any response; a mutation that adds to or removes from a
list says which list with an [edge directive](terminology.md#lists); a
write the user should see at once carries an
[optimistic response](terminology.md#store) that is reverted if the server
refuses it. No code edits a cache by hand.

### Can a client ask for anything, including what is expensive?

Only what the schema declares, and under persisted operations not even
that: the build registers each operation's text with the server under a
[persisted id](terminology.md#compiler), the app sends the id, and the
server may refuse any document it has not seen. Every operation an app can
send is known at build time; Baton has no API that builds one at run time.

### What about versioning?

A GraphQL API usually does not version. Fields are added; a field to be
removed is marked `@deprecated` while clients move off it; and since each
client names the fields it reads, the server knows which fields old app
versions still use. That matters on mobile, where old builds stay installed
for years.

### What happens when part of the server fails?

GraphQL can answer with partial data: the fields that resolved, and an
error for each that did not, with the path to it. Baton keeps each
[field error](terminology.md#store) beside its field, and a view says
which fields it cannot do without (`@required`) and which errors it shows
(`@catch`), so one failed field degrades one row instead of failing the
screen.

### Is GraphQL slow to parse on a device?

Not under Baton: no GraphQL is parsed on the device. The compiler reads the
documents at build time and emits the operation's text, or its persisted
id, and a plan for the response. On the device, the response's JSON is
decoded straight into the store; the measurements are in the
[README](../README.md#by-the-numbers).

### I tried a GraphQL client and it felt like more work than REST.

Most native GraphQL clients generate one model tree per operation from a
query file per screen, and leave the view model in place to copy from it:
the cost of a schema without the benefit of fragments. Relay's shape is
different: each view owns its fragment, the screen's query is assembled
for it, and the store tells views what changed. That is the shape Baton
brings to SwiftUI and Compose; [`comparison.md`](comparison.md) sets the
two approaches side by side.

## What it costs

- **A server that speaks GraphQL.** If the backend is REST, a GraphQL
  server has to stand in front of it, and someone owns that layer.
- **A schema in the build.** The compiler needs the schema's SDL, fetched
  or committed, and a change to it is a change the build sees.
- **A different discipline on the server.** Because clients choose the
  shape, a server has to guard against expensive selections and batch the
  lookups behind nested fields; persisted operations narrow what it has to
  guard against to what the apps actually send.
- **New habits.** A fragment per view and no copied state is the point, and
  it is unfamiliar at first. [`recipes/agents.md`](recipes/agents.md)
  states the shape of a screen in a page, for a person as much as for an
  agent.
