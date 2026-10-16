# Getting started

You add four things, in order: the package, the schema, the environment, the first screen. Then a fragment, a list, and a write. That is most of what an app does. The GraphQL in every figure is compiled by the real compiler when this site is built, and the SwiftUI and Compose tabs show the same thing twice.

## Install

In Swift, add the package and put the build plugin on each target that holds GraphQL. The plugin runs the compiler over the target's sources at build time. The binary comes with the release, prebuilt for macOS and Linux.

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/shergin/baton", from: "0.15.0"),
],
targets: [
    .executableTarget(
        name: "App",
        dependencies: [.product(name: "Baton", package: "baton")],
        plugins: [.plugin(name: "BatonPlugin", package: "baton")]
    ),
]
```

In Kotlin, the runtime is on Maven Central and the Gradle plugin runs the compiler as a task. The plugin fetches the same prebuilt binary the Swift plugin uses.

```kotlin
// build.gradle.kts
import baton.gradle.BatonGenerate

plugins {
    kotlin("multiplatform") version "2.4.20"
    id("com.shergin.baton") version "0.15.0"
}

val generateBaton = tasks.named<BatonGenerate>("generateBaton") {
    hosts.from(fileTree("src/commonMain/kotlin") { include("**/*.kt", "**/*.graphql") })
}

kotlin {
    jvm()
    sourceSets {
        commonMain {
            kotlin.srcDir(generateBaton.flatMap { it.outputDirectory })
            dependencies { implementation("com.shergin.baton:baton:0.15.0") }
        }
    }
}
```

[Gradle](../recipes/gradle/) has the repositories, the Android variant wiring, and the plugin's properties. [Bazel](../recipes/bazel/) has the rule. [The command line](../recipes/batonc/) is the contract everything else spells.

## The schema

The compiler needs the server's schema as SDL, the schema written out as text, checked in beside the code. Download it with whatever your server offers, the server's own tooling or an introspection query, and name it in `baton.json` in the target's directory.

```json
{
  "schema": "schema.graphql"
}
```

That is a complete configuration for a schema whose objects carry an `id`. Identity is configurable when they do not, custom scalars can map to your types, and persisted operations are one more key. [The compiler](../guide/compiler/) lists them. The Kotlin target adds `"kotlin": {"package": "app"}` for the generated shared file.

## The environment

Make one environment per session, at the root of the app, and inject it once. It holds the store, the transport, and the image on disk. For an endpoint that takes a bearer token:

```swift tab
@main
struct IssuesApp: App {
    private static let tokens = TokenStore()
    @State private var environment = Baton.Environment(
        transport: URLSessionTransport(
            url: URL(string: "https://api.github.com/graphql")!,
            credentials: { ["Authorization": "Bearer \(tokens.current)"] }
        ),
        store: Store(persistence: Persistence(name: "App", version: Types.schemaDigest))
    )

    var body: some Scene {
        WindowGroup {
            NavigationStack { IssuesScreen(issues: .init(owner: "shergin", name: "baton")) }
                .environment(\.baton, environment)
        }
    }
}
```

```kotlin tab
@Composable
fun App(tokens: TokenStore) {
    val environment = remember {
        Environment(
            HttpTransport("https://api.github.com/graphql", credentials = { mapOf("Authorization" to "Bearer ${tokens.current}") }),
            store = Store(persistence = Persistence.named("App", version = Types.schemaDigest)),
        )
    }
    CompositionLocalProvider(LocalBaton provides environment) {
        IssuesScreen(owner = "shergin", name = "baton")
    }
}
```

`Types.schemaDigest` is generated. An image written under another schema starts again, instead of being migrated. The credentials closure is read on every attempt. A token the store renews reaches the next request without a new environment. On Android the image also needs a directory, `Persistence.named("App", version = Types.schemaDigest, directory = cacheDir.path)`. A production endpoint wants a retry and a deadline around that transport. That is [the exchange](../recipes/exchange/), a few dozen lines the app owns.

## The first screen

A screen declares one query and switches over its phase. The query is a document, the GraphQL text, in a marker right in the file, where the compiler can find it.

{{host issues IssuesScreen | The screen's query and its three cases. `IssuesQuery` is generated from the document. It is a value of the two variables, which the parent constructs.}}

The parent constructs the operation value, `IssuesQuery(owner:name:)`, and the view resolves it against the store when it appears. Data already there renders in the first body. Otherwise the environment fetches, and `phase` is `loading`, `ready(data)`, or `failed(error)`, with `retry` right there for the failed case.

## The first fragment

The screen's query already spreads `IssueRow_issue`, so the row has to exist. Write the fields that one view reads, beside that view. That piece of GraphQL is a fragment, and the view takes the fragment's lens as its one input. A lens is a typed window onto one record.

{{host issues IssueRow | The row's fragment and its body. The parent writes `IssueRow(issue: node.issueRow)`. `issueRow` is the accessor the spread compiled to.}}

Two rules make the rest work. A view reads only through its own lens, and a parent never reads a child's fields. Add a field to the row's fragment and the row gets it. Nothing in the screen changes.

## The first list

A list that pages is a connection on a refetchable fragment, which means the fragment has its own query for the next page. The fragment owns the pagination, the store owns the merged pages, and the view reads them like any other field.

{{host issue-list IssueList | The connection fragment, the row it spreads, and a screen that spreads the fragment in place of its own `issues` field. `loadNext` fetches the next page with the fragment's own query. The store merges it in.}}

[Lists](../guide/lists/) shows what the store holds after each page, from the fixture that proves it.

## The first write

A mutation compiles to an action. Call it with one argument per variable, and, when the user should see the result at once, pass a typed optimistic response: a value shown immediately and reverted if the server refuses.

{{host star StarButton | A star toggle: a fragment for what it reads, two mutations for what it does. The optimistic response is a typed value. It is reverted if the server refuses.}}

[Writes](../guide/writes/) has the rest: edge directives for lists, payloads committed by hand, and why there is no cache updater.

## When something is wrong

Misspell a field. The build fails at that character in the GraphQL text, in the file that carries it, with the schema's suggestion.

{{diagnostics typo | The compiler over a row with a typo. The position points into the string inside the Swift file. The editor shows it on the line.}}

## Previews and tests

A store is filled from a payload as well as from the network. A preview or a test gets a real store, with no server, and without mocking anything of Baton's.

```swift tab
let environment = Environment(transport: SilentTransport())
try await environment.commitPayload(IssuesQuery(owner: "shergin", name: "baton"), Payload(fixture))
```

```kotlin tab
val environment = Environment(SilentTransport())
environment.commitPayload(IssuesQuery(owner = "shergin", name = "baton"), Payload(fixture))
```

[Previews and tests](../recipes/testing/) is the catalogue: recorded transports, a held mutation to observe an optimistic layer, and a rule tested with a value.

## Where next

- [One screen, end to end](../walkthrough/): what happened, step by step, from the fragment to the next launch.
- [GraphQL for mobile engineers](../graphql/): the schema, the document, and the response, if those words are new.
- [The twelve words](../guide/concepts/): the whole vocabulary on one page.
- [Agents](../recipes/agents/): the shape of a screen and a review checklist, for a coding agent or for you.
