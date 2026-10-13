# A compiler, not a configuration

A GraphQL client that reasons about GraphQL at run time pays for it on every
request and in every binary: a parser, a validator, an executor over selection
metadata, string-keyed records, type policies looked up by name. It also
cannot tell a developer at build time that a field does not exist, that a
parent never spread the fragment a child reads, or that two operations will
collide in the cache. Baton's runtime parses no GraphQL. Every operation is
static, so every question a cache has to answer is answered before the app
runs, and the runtime is a tokenizer that follows a plan, a store that merges
slots, accessors that read them, and a transport that sends the text, or the
id the build registered.

## What the compiler settles

`batonc` reads the schema, `baton.json` and every document in the module,
whether in a Swift or Kotlin file or in a `.graphql` file, and settles:

- **Validity.** Every field against the schema, with the diagnostic pointing
  into the GraphQL text inside the host file, at the character, as
  `path:line:column: error: message`, so the editor shows it on the line and a
  misspelled field has the schema's suggestion beside it.
- **Aggregation.** The screen's operation is assembled from the fragments
  spread into it, fragment arguments applied by cloning per unique argument
  set, every fragment inlined into one normalization plan per operation.
  Nobody writes the screen's query.
- **Identity.** The key fields identity needs, `id` unless `baton.json` names
  other fields for a type, are inserted into the selection wherever the type
  is read, so a response always carries what the ingest needs to make a
  record.
- **Storage keys.** Every key without a variable is computed and emitted as a
  constant; a key with variables is rendered once per owner. No path a view or
  a commit takes hashes a field name.
- **Masking.** A fragment compiles to a lens with an accessor per declared
  field and no other; a spread compiles to an accessor returning the child's
  lens. The parent cannot read through it.
- **The wire.** The operation's text is printed compact and hashed to an id;
  under Relay's `persistConfig` the registration file is written by the build
  and the app sends the id alone.
- **The report.** What a dependent target's compilation would read: every
  operation, fragment and lens, the schema's digest, the reachable and the
  unused fragments, for tools and for the inspector.

The runtime has no opinion. The same plans are interpreted by the Swift and
the Kotlin runtime, so they can only disagree in execution, which the fixtures
catch.

## Relay's front end, pinned, behind Baton's driver

The front end is Relay's own compiler: its parser, schema, typed IR, spec
validation and transforms, consumed as Rust crates pinned to a tag, behind a
driver that is Baton's. Everything in front of them, finding GraphQL in Swift
and Kotlin sources, and everything behind them, the plan IR, the emitters and
the artifact format, is Baton's. There is no fork.

The reason is a graveyard. Relay.swift put the fragment in the Swift file and
generated code through a plugin for the JavaScript Relay compiler; Relay 13
replaced that compiler in January 2022 and removed the plugin API, and
Relay.swift stopped. rescript-relay forks the Rust compiler and was 675
commits behind upstream in October 2026. Apollo iOS bundles GraphQL.js, so
syntax the JavaScript reference implementation does not parse yet is syntax
Apollo iOS cannot accept. Baton owns the binary, the scanner and the emitter,
and the pinned revision cannot fall out of step with anything because the
runtime is Baton's; an upgrade is elective ([the
decision](../decisions/relay-front-end.md)).

The spike that settled it measured a stripped binary of 4.3 MB and 500
fragments compiled in 8 ms warm; GitHub's schema, about 1,800 definitions,
passes the front end in 33 ms. The compiler is one prebuilt binary for macOS
and Linux, run by the SwiftPM and Xcode plugin, the Gradle plugin, the Bazel
rule or the command line, and none of those integrations holds logic of its
own ([the decision](../decisions/a-build-integration-holds-no-logic.md)).

## Slots are numbered by the process

One detail shows how far the principle is taken, and where it stops. A record
stores a field's value at a slot, a small integer per storage key and type.
The obvious reading of "the compiler decides" is that the compiler writes the
integers into the generated code. It does not, and the reason is that modules
compile apart and share one store: two modules must agree on the slot of
`Character.name` without having seen each other, and a build-tool plugin sees
one target at a time. So the compiler emits one constant per key and type,
`Slots.Character_name`, and the process numbers each constant the first time
it is touched, in a table every module shares. A name is hashed where a key is
first met and nowhere a view or a commit passes again. The image stores names,
not numbers, because slot numbers belong to a process, and that is why it
survives a build with other documents ([the
decision](../decisions/slots-are-numbered-by-the-process.md)).

## No policy objects

The opposite of a compiler is a configuration: a cache that is correct once
the right objects are registered at run time. Apollo configures identity with
`@typePolicy` and `@fieldPolicy` or a key-generator function; Medium's Android
team, migrating between Apollo Kotlin majors in 2025, found cache misses
everywhere because some ids were missing from their `CacheKeyGenerator` and
some of its logic was wrong ([their
write-up](https://medium.engineering/medium-android-app-migrating-from-apollo-kotlin-3-to-4-lessons-learned-ff8d0d861cdb)),
and Vrbo's 2019 account of the same cache says normalization is
all-or-nothing, every type needs a stable key, and two queries with the same
response type do not share data unless their roots are remapped by hand
([their
write-up](https://medium.com/expedia-group-tech/how-apollo-android-client-cache-works-at-vrbo-73334d98af43)).
Those are not bugs in Apollo. They are what a run-time policy is: a contract
the compiler never sees, broken in production.

In Baton identity is configuration the compiler reads and checks. A type keyed
by something other than `id`, by several fields or through an interface, is
named once in `baton.json`, the compiler validates the fields against the
schema and selects them wherever the type is read, and the plan carries the
key per selection ([the decision](../decisions/identity-is-configured.md)).
Fetch behaviour is a directive or a value on a handle: `@connection`,
`@refetchable`, `@cacheExpiration`, a fetch policy. There is no type-policy
registry, no merge function, no interceptor chain and no per-call option bag,
and the principle lists those under what it is not, as refusals rather than
omissions.

## Byte-stable output, and names that try to break it

Generated output is deterministic and byte-stable, and golden tests cover
every emitter in both languages. What generated code names in the runtime is a
format with a number; a change to it raises the number on both sides in one
commit, and generated code of an older format fails to compile at its marker
with a message that says to rebuild. The compiler's tests fence the bytes of
generated code per accessor line at 120 over the goldens, so a lens cannot
quietly grow.

Then there are the names. A schema can call a field `init`, `Type`,
`description`, `self` or `suspend`, a fragment `Variables` or `Companion`, an
enum value `UNKNOWN` beside `Unknown`. A corpus of hostile names in every
position a name can take is compiled into a host file for each language, and a
sweep type-checks the generated code one document at a time, in CI, so that a
field spelled like a keyword is escaped, a name that would clash with a
generated member is refused with a diagnostic at the name, and the generated
case for an enum value the build did not know cannot collide with a schema
value spelled `UNKNOWN`, which on a case-insensitive disk would be the same
class file. That is work a run-time client never has to do and an adopter of a
compiler should never notice.

## Why this matters more now

When a coding agent writes the screens, as one increasingly does in 2026, a
compiler-checked data layer is what makes its screens safe to accept. A
diagnostic at the character in the file is exactly the loop an agent iterates
on best; a fragment beside the view is local reasoning an agent can hold in
one window; structural masking means a view cannot grow a dependency on a
field it did not declare, however the code was produced.
[fate](https://github.com/nkzw-tech/fate), a data client for the web released
in 2026 that takes Relay's ideas without requiring GraphQL, answered a request
for a compiler with "we have agents" ([its issue
20](https://github.com/nkzw-tech/fate/issues/20)) and checks nothing at build
time. The argument runs the other way: a planner at run time is weaker for
agents, not stronger, because the only thing that tells an agent its fragment
is wrong is a user. Baton ships [a page for agents](../recipes/agents.md) that
says what to read, the shape of a screen, what never to write, and what to
run, and the compiler is the reviewer that never gets tired.

## What it costs

A Rust toolchain for Baton's own development; a prebuilt binary and a build
step for adopters, with a plugin trust prompt in Xcode the first time; a
pinned revision of the front end that Baton advances on its own schedule; and
a schema checked into the build, so that a change to it is a change the build
sees. Nothing is configurable at run time that could be decided at build time,
which an app with a genuinely dynamic schema would find too strict, and such
an app is not who this is for.

In exchange, the runtime is small enough to read in an afternoon and to
vendor, a wrong field is a build error with the fix suggested, the cache
cannot be misconfigured because there is nothing to configure, and the same
compiler drives both platforms. The compiler decides; the runtime executes
([the principle](../principles/compiler-decides.md)).
