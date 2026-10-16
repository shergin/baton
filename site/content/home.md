# Baton

<section class="hero">

<div class="hero-text">

<h1>Relay, for <span class="swift-word">SwiftUI</span> and <span class="kotlin-word">Compose</span>.</h1>

<p class="lede">You write the fields a view needs, next to the view. Baton asks for them in one request, shows the cached data on the first frame, and re-renders only where a field changed. The compiler checks every field against the schema. The UI framework watches the records.</p>

```sh
swift package add-dependency https://github.com/shergin/baton --from 0.15.0
```

<p class="trust">Swift 6.2 · Kotlin 2.4 · the platform's own frameworks and SQLite, nothing vendored · one compiler, already built</p>

<p><a class="cta solid" href="start/">Start here</a> <a class="cta" href="graphql/">New to GraphQL?</a> <a class="cta accent" href="walkthrough/">One screen, end to end</a> <a class="cta" href="playground/">Open the playground</a></p>

</div>

{{host issues IssueRow | A row names the fields it reads, right beside its body. It cannot read anything else. SwiftUI on one tab, Compose on the other. Same document, same lens.}}

</section>

## A field changes. One view re-renders.

The store below is a real response from the Rick and Morty API. The screen beside it reads those records through the fragments the compiler reported. There is no view model in between. Click a field. Watch who wakes up.

{{stage characters CharactersQuery spec/rickandmorty/characters-page-1.store.json rows=6 | The list reads the root's link and the list's links. Each row reads the four fields its fragment declared, on its own record. A refetch that comes back with the same bytes notifies nobody. The store compares before it tells anyone.}}

<section class="manifesto">

<div>

<h3>The view never sees the data layer</h3>

<p>No query file to keep in sync. No cache-update function. No view model copying fields into a struct. The fragment sits next to the body, and the data is there. A parent hands a child a lens, not a bag of fields. The child reads exactly what it asked for.</p>

</div>

<div>

<h3>Every claim can be checked</h3>

<p>Read a field through a lens and you get the same value as the raw response, at the same path. Fixtures under <code>spec/</code> prove it for Swift and for Kotlin. A speed claim has a bench in the repository. If a view re-rendered, a field it read changed, and a test can count that.</p>

</div>

<div>

<h3>Relay's language, native's mechanisms</h3>

<p>The directives, the conventions, and the compiler's front end are Relay's. A web team and a native team can use the same words. Relay built a runtime because React cannot see which view read which field. SwiftUI's Observation and Compose's snapshot state can. Baton uses those, and leaves Relay's read side out.</p>

</div>

</section>

## The shape of a screen

A screen is one query. Each view on it is one fragment. The compiler builds the query out of the fragments spread into it. Nobody writes the screen's request by hand.

{{host issues IssuesScreen | The screen names the repository with its variables, and spreads the row's fragment into the open issues. The row's accessor, `issueRow`, is the baton. The parent hands it over, and cannot read through it.}}

{{operation issues IssuesQuery | What the compiler sends. The operation, then the fragment it reaches. The `id` fields identity needs, added. The whole text on one line, hashed to an id. Under `persistConfig` the request carries that id and nothing else.}}

{{lens issues IssueRow_issue | The row's lens, as the compiler reported it. One accessor per field the fragment declared. No accessor for anything else. Masking is not a house rule. It is the shape of the type.}}

<div class="tiles">

<div class="tile">

<h3>Records, not models</h3>

<p>A response is decoded straight into records, keyed by type and id, off the main actor. There is no model tree in between. The list, the detail, and the cast of an episode all read the one record a character is. <a href="guide/store/">The store</a> shows a response beside the records it became.</p>

</div>

<div class="tile">

<h3>Lists that page in the store</h3>

<p>A list is a Relay connection on a refetchable fragment. The lens pages with <code>loadNext</code>. The store merges the pages. A mutation adds an edge with a directive, not with a cache updater. <a href="guide/lists/">Lists</a> walks the fixture that proves it.</p>

</div>

<div class="tile">

<h3>Writes you can see at once</h3>

<p>A mutation is an action. Its optimistic response is a typed value. It goes through the same ingest as a server's answer, shows up in the turn of the call, and comes back off if the server says no. <a href="guide/writes/">Writes</a> steps through a layer applied, resolved, and reverted.</p>

</div>

<div class="tile">

<h3>Honest data</h3>

<p>Nullability is what the schema says. <code>@required</code> moves a null up to where the product wants to deal with it. <code>@catch</code> turns a field error into a <code>Result</code>. A field error survives caching. Missing data is reported and healed. It is never invented. <a href="guide/honest-data/">Honest data</a> has the directives.</p>

</div>

<div class="tile">

<h3>The first frame has the data</h3>

<p>Reads are synchronous on the main actor. A handle resolves against the store before the first body runs. After a launch, the store reads what the handle needs from its image on disk. A screen the app has seen does not flash a spinner. <a href="walkthrough/">The walkthrough</a> follows one screen through to the next launch.</p>

</div>

<div class="tile">

<h3>The compiler decides</h3>

<p>Every operation is known at build time. Identity, aggregation, masking, storage keys, persisted ids, and diagnostics are settled before the app runs. A wrong field is a build error, pointing at the character in the GraphQL text. <a href="guide/compiler/">The compiler</a> shows one.</p>

</div>

</div>

## Twelve words

Twelve words. That is the whole vocabulary. A feature is some combination of these, or a Relay directive the compiler already understands. Otherwise it does not ship.

<ul class="words">
<li><a href="guide/concepts/#schema">schema</a>the server's menu, checked in and compiled in</li>
<li><a href="guide/concepts/#document">document</a>a query, a mutation, a subscription, or a fragment, beside a view</li>
<li><a href="guide/concepts/#directive">directive</a>the only way behaviour attaches to data</li>
<li><a href="guide/concepts/#lens">lens</a>a typed window onto one record, read-only</li>
<li><a href="guide/concepts/#record">record</a>an observable object, keyed by type and id</li>
<li><a href="guide/concepts/#store">store</a>all the records, owned by the main thread</li>
<li><a href="guide/concepts/#plan">plan</a>how a response becomes records, decided by the compiler</li>
<li><a href="guide/concepts/#operation-value">operation value</a>an operation's variables, the thing a parent constructs</li>
<li><a href="guide/concepts/#connection">connection</a>a list that pages, merged in the store</li>
<li><a href="guide/concepts/#environment">environment</a>the session: one store, one transport</li>
<li><a href="guide/concepts/#transport">transport</a>one verb, <code>send</code>, yielding payloads</li>
<li><a href="guide/concepts/#phase">phase</a>loading, ready, or failed, and always readable</li>
</ul>

## Where to go

<div class="map">

<section>
<h3>Start here</h3>
<ul>
<li><a href="start/">Getting started</a><span>Install, the schema, the first screen, the first fragment, the first list.</span></li>
<li><a href="graphql/">GraphQL for mobile engineers</a><span>The menu, the order, the response in the order's shape, ids, lists, writes. No GraphQL required.</span></li>
<li><a href="walkthrough/">One screen, end to end</a><span>From the fragment beside a view to the frame, the records, the one re-render, and the next launch.</span></li>
<li><a href="playground/">Playground</a><span>Type a fragment. Read what the compiler wrote.</span></li>
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
<li><a href="guide/live/">Live data</a><span>Subscriptions, deferred fragments, streamed lists.</span></li>
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
<li><a href="examples/">The gallery</a><span>Every sample, and what the compiler found in it.</span></li>
</ul>
</section>

<section>
<h3>Why it is shaped this way</h3>
<ul>
<li><a href="vision/">Vision</a><span>Three commitments and five rules.</span></li>
<li><a href="principles/fragment-is-a-lens/">The principles</a><span>Eight constraints. Each one names the failure it avoids.</span></li>
<li><a href="decisions/">Decisions</a><span>Every choice, the evidence, and what would reopen it.</span></li>
<li><a href="#faster-by-skipping-steps">Faster, by skipping steps</a><span>Three things Apollo does on every response, or every read, that Baton never does.</span></li>
<li><a href="articles/">Articles</a><span>The long version: Relay without the read side, what Meta built, why it is fast, the first frame, two runtimes, the compiler, the honest store, twelve words, Baton beside fate, the small lies a client tells, and how the library is built.</span></li>
</ul>
</section>

<section>
<h3>Reference</h3>
<ul>
<li><a href="terminology/">Terminology</a><span>The vocabulary contract.</span></li>
<li><a href="contract/">The runtime contract</a><span>What a runtime does, one paragraph a rule.</span></li>
<li><a href="spec/">The specification</a><span>The fixtures both runtimes are held to.</span></li>
<li><a href="changelog/">Changelog</a><span>Every release, named for a bread.</span></li>
</ul>
</section>

</div>

## Faster, by skipping steps

Baton is faster than Apollo iOS and Apollo Kotlin on the same data. The store is not the trick. The stores write at about the same speed. Apollo takes three steps, on every response or every read, that Baton does not take at all.

<div class="numbers">
<div><span class="big word">No model tree</span><p>Apollo builds a model of the operation from the response's bytes, and builds it again from the store on every read. Baton decodes the bytes straight into record slots, by the plan the compiler emitted. A view reads a slot.</p></div>
<div><span class="big word">No re-execution</span><p>When any field a query read changes, Apollo re-executes the whole query and rebuilds the tree. Baton notifies the slot that changed. Only the bodies that read it run.</p></div>
<div><span class="big word">No waiting</span><p>Apollo's store reads are asynchronous, so a warm cache still shows a loading frame. Baton's reads are synchronous on the main actor. The first body has the data. After a launch, the image on disk has it too.</p></div>
</div>

Each of those is work a view never asked for. How much of a frame it costs depends on the device and the data, so the head-to-heads stay in the repository, in [`BENCHMARKS.md`](https://github.com/shergin/baton/blob/master/BENCHMARKS.md). Each one has its revision, machine, OS, and date. [`docs/comparison.md`](https://github.com/shergin/baton/blob/master/docs/comparison.md) is the longer argument, including the places Apollo is ahead.

## The name

<section class="name">

<div class="loaf-big" aria-hidden="true"></div>

<div>

<p>In a relay race, the baton is the thing that actually gets handed over. Here it is the data a screen hands each view: exactly what that view asked for, and nothing else. In Russian the same word, батон, is a loaf of bread. That is why the logo is a loaf, and why every release is named for one.</p>

</div>

</section>
