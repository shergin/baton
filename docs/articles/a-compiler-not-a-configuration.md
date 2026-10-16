# A compiler, not a configuration

A GraphQL client that reasons about GraphQL at run time pays for it on every
request, and again in the binary. The binary carries a parser, a validator,
and an executor over selection metadata. Records are keyed by strings, and
type policies are looked up by name.

That client also cannot tell you, at build time, that a field does not
exist, that a parent never spread the fragment a child reads, or that two
operations will collide in the cache.

Baton's runtime parses no GraphQL. Every operation is static, so every
question a cache has to answer is answered before the app runs. The runtime
is a tokenizer that follows a plan, a store that merges slots, accessors
that read them, and a transport that sends the text, or the id the build
registered.

## What the compiler settles

`batonc` reads the schema, `baton.json`, and every document in the module. A
document can sit in a Swift file, a Kotlin file, or a `.graphql` file. The
compiler then settles the following.

- **Validity.** Every field is checked against the schema. The diagnostic
  points into the GraphQL text inside the host file, at the character, as
  `path:line:column: error: message`. The editor shows it on the line. A
  misspelled field has the schema's suggestion beside it.
- **Aggregation.** The screen's operation is assembled from the fragments
  spread into it. Fragment arguments are applied by cloning, once per unique
  argument set. Every fragment is inlined into one normalization plan per
  operation. Nobody writes the screen's query.
- **Identity.** The key fields identity needs are inserted into the selection
  wherever the type is read. That is `id`, unless `baton.json` names other
  fields for a type. A response always carries what the ingest needs to make
  a record.
- **Storage keys.** Every key without a variable is computed and emitted as
  a constant. A key with variables is rendered once per owner. No path a
  view or a commit takes hashes a field name.
- **Masking.** A fragment compiles to a lens, a typed, read-only view over
  one record: one accessor per field you declared, and no accessor for
  anything else. A spread compiles to an accessor that returns the child's
  lens, which the parent cannot read through.
- **The wire.** The operation's text is printed compact and hashed to an id.
  Under Relay's `persistConfig`, the build writes the registration file, and
  the app sends the id alone.
- **The report.** What a dependent target's compilation would read is every
  operation, fragment, and lens, the schema's digest, the reachable
  fragments, and the unused ones. The report is for tools and for the
  inspector.

The runtime has no opinion. The Swift runtime and the Kotlin runtime
interpret the same plans. They can disagree only in execution, and the
fixtures catch that.

## Relay's front end, pinned, behind Baton's driver

The front end is Relay's own compiler: its parser, its schema, its typed IR,
its spec validation, and its transforms. Baton consumes them as Rust crates,
pinned to a tag, behind a driver that is Baton's.

Everything in front of that front end is Baton's: finding GraphQL in Swift
and Kotlin sources. Everything behind it is Baton's too: the plan IR, the
emitters, and the artifact format. There is no fork.

The reason is a graveyard. Relay.swift put the fragment in the Swift file
and generated code through a plugin for the JavaScript Relay compiler. Relay
13 replaced that compiler in January 2022 and removed the plugin API.
Relay.swift stopped.

rescript-relay forks the Rust compiler and, in October 2026, was 675 commits
behind upstream. Apollo iOS bundles GraphQL.js, so syntax the JavaScript
reference implementation does not parse yet is syntax Apollo iOS cannot
accept.

Baton owns the binary, the scanner, and the emitter. The pinned revision
cannot fall out of step with anything, because the runtime is Baton's. An
upgrade is elective ([the
decision](../decisions/relay-front-end.md)).

The spike that settled it measured a stripped binary of 4.3 MB, and 500
fragments compiled in 8 ms warm. GitHub's schema, about 1,800 definitions,
passes the front end in 33 ms. The compiler is one prebuilt binary, for
macOS and Linux. The SwiftPM plugin, the Xcode plugin, the Gradle plugin,
the Bazel rule, or the command line runs it. None of those integrations
holds logic of its own ([the
decision](../decisions/a-build-integration-holds-no-logic.md)).

## Slots are numbered by the process

One detail shows how far the principle goes, and where it stops. A record
stores a field's value at a slot, a small integer, one per storage key and
type.

The obvious reading of "the compiler decides" is that the compiler writes
those integers into the generated code. It does not. Modules compile apart
and share one store. Two modules must agree on the slot of `Character.name`
without having seen each other. A build-tool plugin sees one target at a
time.

So the compiler emits one constant per key and type,
`Slots.Character_name`. The process numbers each constant the first time it
is touched, in a table every module shares. A name is hashed where a key is
first met, and nowhere a view or a commit passes again. The image stores
names, not numbers, because slot numbers belong to a process. That is why
the image survives a build with other documents ([the
decision](../decisions/slots-are-numbered-by-the-process.md)).

## No policy objects

The opposite of a compiler is a configuration. A cache is correct once the
right objects are registered at run time. Apollo configures identity with
`@typePolicy` and `@fieldPolicy`, or with a key-generator function.

Medium's Android team migrated between Apollo Kotlin majors in 2025 and
found cache misses everywhere. Some ids were missing from their
`CacheKeyGenerator`, and some of its logic was wrong ([their
write-up](https://medium.engineering/medium-android-app-migrating-from-apollo-kotlin-3-to-4-lessons-learned-ff8d0d861cdb)).
Vrbo's 2019 account of the same cache says normalization is all-or-nothing.
Every type needs a stable key. Two queries with the same response type do
not share data unless their roots are remapped by hand ([their
write-up](https://medium.com/expedia-group-tech/how-apollo-android-client-cache-works-at-vrbo-73334d98af43)).

Those are not bugs in Apollo. They are what a run-time policy is: a contract
the compiler never sees, broken in production.

In Baton, identity is configuration the compiler reads and checks. When a
type is keyed by something other than `id`, you name it once in
`baton.json`. The key can be several fields, or it can go through an
interface. The compiler validates the fields against the schema and selects
them wherever the type is read. The plan carries the key per selection ([the
decision](../decisions/identity-is-configured.md)).

Fetch behaviour is a directive, or a value on a handle: `@connection`,
`@refetchable`, `@cacheExpiration`, a fetch policy. There is no type-policy
registry, no merge function, no interceptor chain, and no per-call option
bag. The principle lists those under what it is not. They are refusals, not
omissions.

## Byte-stable output, and names that try to break it

Generated output is deterministic and byte-stable, and golden tests cover
every emitter in both languages. What generated code names in the runtime is
a format with a number, and a change to it raises the number on both sides
in one commit. Generated code of an older format fails to compile at its
marker, with a message that says to rebuild.

The compiler's tests fence the bytes of generated code per accessor line at
120, over the goldens, so a lens cannot quietly grow.

Then there are the names. A schema can call a field `init`, `Type`,
`description`, `self`, or `suspend`, a fragment `Variables` or `Companion`,
and an enum value `UNKNOWN` beside `Unknown`.

A corpus of hostile names, in every position a name can take, is compiled
into a host file for each language. A sweep type-checks the generated code
one document at a time, in CI. A field spelled like a keyword is escaped,
and a name that would clash with a generated member is refused, with a
diagnostic at the name. The generated case for an enum value the build did
not know cannot collide with a schema value spelled `UNKNOWN`. On a
case-insensitive disk, that would be the same class file.

That is work a run-time client never has to do. If you adopt a compiler, you
should never notice it.

## Why this matters more now

When a coding agent writes the screens, as one increasingly does in 2026, a
compiler-checked data layer is what makes those screens safe to accept. A
diagnostic at the character, in the file, is the loop an agent iterates on
best. A fragment beside the view is local reasoning an agent can hold in one
window. Structural masking means a view cannot grow a dependency on a field
it did not declare, however the code was produced.

[fate](https://github.com/nkzw-tech/fate) is a data client for the web,
released in 2026, that takes Relay's ideas without requiring GraphQL. Asked
for a compiler, the author answered "we have agents" ([its issue
20](https://github.com/nkzw-tech/fate/issues/20)). It checks nothing at
build time.

The argument runs the other way. A planner at run time is weaker for agents,
not stronger, because the only thing that tells an agent its fragment is
wrong is a user. Baton ships [a page for agents](../recipes/agents.md) that
says what to read, the shape of a screen, what never to write, and what to
run. The compiler is the reviewer that never gets tired.

## What it costs

The cost is a Rust toolchain, for Baton's own development, and a prebuilt
binary and a build step, for adopters, with a plugin trust prompt in Xcode
the first time. It is also a pinned revision of the front end, which Baton
advances on its own schedule, and a schema checked into the build, so a
change to it is a change the build sees.

Nothing is configurable at run time that could be decided at build time. An
app with a genuinely dynamic schema would find that too strict, and such an
app is not who this is for.

In exchange, the runtime is small enough to read in an afternoon, and to
vendor. A wrong field is a build error, with the fix suggested. The cache
cannot be misconfigured, because there is nothing to configure. The same
compiler drives both platforms. The compiler decides. The runtime executes
([the principle](../principles/compiler-decides.md)).
