# Baton

<section class="hero">

<div class="hero-text">

<h1>Relay, for <span class="swift-word">SwiftUI</span> and <span class="kotlin-word">Compose</span>.</h1>

<p class="lede">A fragment beside every view, one request per screen, cached data in the first frame, and a re-render only where a field changed. You write what a view needs. The compiler writes the query, checks every field against the schema, and emits a typed lens. The runtime turns responses into records that the UI framework itself observes.</p>

```sh
swift package add-dependency https://github.com/shergin/baton --from 0.15.0
```

<p class="trust">Swift 6.2 · Kotlin 2.4 · Foundation, Observation and the system's SQLite, nothing else · one prebuilt compiler</p>

<p><a class="cta solid" href="start/">Start here</a> <a class="cta" href="graphql/">New to GraphQL?</a> <a class="cta accent" href="walkthrough/">One screen, end to end</a> <a class="cta" href="playground/">Open the playground</a></p>

</div>

{{host issues IssueRow | A row declares the fields it reads, beside its body, and can read nothing else. SwiftUI on one tab, Compose on the other: the same document, the same lens.}}

</section>

## A field changes. One view re-renders.

The store below holds records the runtime wrote from a recorded response to the Rick and Morty API, and the screen beside it reads them through the fragments the compiler reported. Nothing in between is a view model. Click a field in the store and watch who notices.

{{stage characters CharactersQuery spec/rickandmorty/characters-page-1.store.json rows=6 | The list reads the root's link and the list's links; each row reads the four fields its fragment declared, of its own record. A refetch that answers with the same bytes notifies nobody, because the store compares before it notifies.}}

<section class="manifesto">

<div>

<h3>The view never sees the data layer</h3>

<p>No query files to keep in sync, no cache-update code, no view model copying fields around. A fragment next to a body, and the data is there. A parent hands a child a lens, not data, and the child reads exactly the fields it declared.</p>

</div>

<div>

<h3>Every claim can be checked</h3>

<p>Reading a field through a lens equals reading the raw response at the same path, and fixtures under <code>spec/</code> prove it for both runtimes. Every number comes from a bench recorded with device, OS and date. A view that re-rendered did so because a field it read changed, and a test can count it.</p>

</div>

<div>

<h3>Relay's language, native's mechanisms</h3>

<p>The directives, the conventions and the compiler's front end are Relay's, so a web team and a native team speak one language. What Relay built because React could not see who read what is replaced by what SwiftUI's Observation and Compose's snapshot state can see.</p>

</div>

</section>

## The shape of a screen

A screen is one query. Every view on it is one fragment. The compiler assembles the query from the fragments spread into it, and nobody writes the screen's request by hand.

{{host issues IssuesScreen | The screen names the repository by its variables and spreads the row's fragment into the open issues. The row's accessor, `issueRow`, is the baton: the parent hands it over and cannot read through it.}}

{{operation issues IssuesQuery | What the compiler sends: the fragment inlined, the `id` fields identity needs added, the whole operation printed on one line and hashed to an id. Under `persistConfig` the request carries the id alone.}}

{{lens issues IssueRow_issue | The row's lens, as the compiler reported it: one accessor per declared field, and no accessor for anything the fragment did not declare. Masking is not a convention here; it is the shape of the type.}}

<div class="tiles">

<div class="tile">

<h3>Records, not models</h3>

<p>A response is decoded straight into records keyed by type and id, off the main actor, with no model tree in between. The list, the detail and the cast of an episode all read the one record a character is. <a href="guide/store/">The store</a> shows a response beside what it became.</p>

</div>

<div class="tile">

<h3>Lists that page in the store</h3>

<p>A list is a Relay connection on a refetchable fragment. The lens pages with <code>loadNext</code>, the store merges the pages, and a mutation adds an edge with a directive instead of a cache updater. <a href="guide/lists/">Lists</a> walks the fixture that proves it.</p>

</div>

<div class="tile">

<h3>Writes you can see at once</h3>

<p>A mutation is an action. Its optimistic response is a typed value that goes through the same ingest as a server's answer, shows in the turn of the call, and is reverted if the server refuses. <a href="guide/writes/">Writes</a> steps through a layer applied, resolved and reverted.</p>

</div>

<div class="tile">

<h3>Honest data</h3>

<p>Nullability is what the schema says. <code>@required</code> moves a null to where the product wants it, <code>@catch</code> turns a field error into a <code>Result</code>, and a field error survives caching. Missing data is reported and healed, never invented. <a href="guide/honest-data/">Honest data</a> has the directives.</p>

</div>

<div class="tile">

<h3>The first frame has the data</h3>

<p>Reads are synchronous on the main actor. A handle resolves against the store before the first body runs, and after a launch the store reads what the handle needs from its image on disk. No loading flash for a screen the app has seen. <a href="walkthrough/">The walkthrough</a> follows one screen to the next launch.</p>

</div>

<div class="tile">

<h3>The compiler decides</h3>

<p>Every operation is known at build time. Identity, aggregation, masking, storage keys, persisted ids and diagnostics are settled before the app runs, and a wrong field is a build error pointing at the character in the GraphQL text. <a href="guide/compiler/">The compiler</a> shows one.</p>

</div>

</div>

## Twelve words

The vocabulary is closed and short. A feature is a composition of these, or a Relay directive the compiler understands, or it does not ship.

<ul class="words">
<li><a href="guide/concepts/#schema">schema</a>the server's menu, checked in and compiled in</li>
<li><a href="guide/concepts/#document">document</a>a query, a mutation, a subscription or a fragment, beside a view</li>
<li><a href="guide/concepts/#directive">directive</a>the only way behaviour attaches to data</li>
<li><a href="guide/concepts/#lens">lens</a>a typed, read-only view over one record</li>
<li><a href="guide/concepts/#record">record</a>an observable object keyed by type and id</li>
<li><a href="guide/concepts/#store">store</a>all records, owned by the main thread</li>
<li><a href="guide/concepts/#plan">plan</a>how a response becomes records, decided by the compiler</li>
<li><a href="guide/concepts/#operation-value">operation value</a>a query's variables, the thing a parent constructs</li>
<li><a href="guide/concepts/#connection">connection</a>a list that pages, merged in the store</li>
<li><a href="guide/concepts/#environment">environment</a>the session: one store, one transport</li>
<li><a href="guide/concepts/#transport">transport</a>one verb, <code>send</code>, yielding payloads</li>
<li><a href="guide/concepts/#phase">phase</a>loading, ready or failed, always readable</li>
</ul>

## Where to go

<div class="map">

<section>
<h3>Start here</h3>
<ul>
<li><a href="start/">Getting started</a><span>Install, the schema, the first screen, the first fragment, the first list.</span></li>
<li><a href="graphql/">GraphQL for mobile engineers</a><span>The menu, the order, the response with the order's shape, ids, lists, writes. No prior GraphQL needed.</span></li>
<li><a href="walkthrough/">One screen, end to end</a><span>From the fragment beside a view to the frame, the records, the one re-render and the next launch.</span></li>
<li><a href="playground/">Playground</a><span>Type a fragment, read what the compiler wrote.</span></li>
</ul>
</section>

<section>
<h3>The guide</h3>
<ul>
<li><a href="guide/concepts/">The twelve words</a><span>The closed vocabulary, one plate each.</span></li>
<li><a href="guide/reads/">Reads</a><span>Queries, fragments, lenses, phases, fetch policies.</span></li>
<li><a href="guide/store/">The store</a><span>Records, identity, observation, roots, the image on disk.</span></li>
<li><a href="guide/lists/">Lists</a><span>Connections, pages merged, edge directives.</span></li>
<li><a href="guide/writes/">Writes</a><span>Actions, optimistic responses, payloads.</span></li>
<li><a href="guide/honest-data/">Honest data</a><span>Nulls, errors, missing data, enums, scalars.</span></li>
<li><a href="guide/live/">Live data</a><span>Subscriptions and deferred fragments.</span></li>
<li><a href="guide/compiler/">The compiler</a><span>What it checks, what it writes, how the build runs it.</span></li>
<li><a href="guide/environment/">The environment</a><span>The transport, the session, the log, tests.</span></li>
<li><a href="guide/kotlin/">Compose</a><span>The same screens in Kotlin.</span></li>
</ul>
</section>

<section>
<h3>Recipes and examples</h3>
<ul>
<li><a href="recipes/agents/">Agents</a><span>The page a coding agent reads first.</span></li>
<li><a href="recipes/">Every recipe</a><span>Testing, the exchange, UIKit, view models, porting from Relay, the build integrations.</span></li>
<li><a href="examples/">The gallery</a><span>Every sample, with what the compiler found in it.</span></li>
</ul>
</section>

<section>
<h3>Why it is shaped this way</h3>
<ul>
<li><a href="vision/">Vision</a><span>Three commitments and five rules.</span></li>
<li><a href="principles/fragment-is-a-lens/">The principles</a><span>Eight constraints, each with the failure it avoids.</span></li>
<li><a href="decisions/">Decisions</a><span>Every choice, with its evidence and what would reopen it.</span></li>
<li><a href="comparison/">Compared with the other clients</a><span>Apollo iOS, Apollo Kotlin, the smaller Swift clients, Relay.</span></li>
</ul>
</section>

<section>
<h3>Reference</h3>
<ul>
<li><a href="terminology/">Terminology</a><span>The vocabulary contract.</span></li>
<li><a href="contract/">The runtime contract</a><span>What a runtime does, one paragraph a rule.</span></li>
<li><a href="benchmarks/">Benchmarks</a><span>Every number, with its machine and date.</span></li>
<li><a href="changelog/">Changelog</a><span>Every release, named for a bread.</span></li>
</ul>
</section>

</div>

## By the numbers

Two head-to-heads against the maintained native clients, on the same data: a page of 686 KB and 899 records. Every number is in [the benchmarks](benchmarks/) with the device, the OS and the date; these are from the README.

<div class="numbers">
<div><span class="big">94×</span><p>faster than Apollo iOS 2.4 from bytes to the store on an M1 Pro: 3.4 ms against 318 ms.</p></div>
<div><span class="big">8.4×</span><p>faster than Apollo Kotlin 5.2 on a Pixel 9: 5.3 ms against 44.7 ms, in under a 120 Hz frame.</p></div>
<div><span class="big">0.75 ms</span><p>for a screen whose data is already in the store to know it, where Apollo Kotlin rebuilds the query in 25 ms.</p></div>
<div><span class="big">0</span><p>views re-rendered by a refetch that changed nothing. The store compares before it notifies.</p></div>
</div>

{{chart read-path | The ingest and the commit of the fixture at each release, best of each, drawn by the benchmark package from its own tables.}}

## The name

<section class="name">

<div class="loaf-big" aria-hidden="true"></div>

<div>

<p>In a relay, the baton is the thing that is actually handed over. Here it is the data a screen hands each view: exactly what the view asked for, nothing else. In Russian the same word, батон, is a loaf of bread, which is why the logo is a loaf and every release is named for one.</p>

</div>

</section>

{{releases | The releases so far. A release is cut whenever the unreleased section holds something an adopter can use.}}
