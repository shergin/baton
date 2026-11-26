# A target spreads the fragments of its bases

Status: accepted, 2026-11-25. Answers
[#59](https://github.com/shergin/baton/issues/59). Supersedes, for the
import,
[The report is what a dependent target's compilation would read](the-report-is-what-a-dependent-target-reads.md),
whose reopening line, an adopter who spreads fragments across modules,
fired with #59. Answers the first reopening line of
[The report holds each lens](the-report-holds-each-lens.md), a consumer
that needs the lens's checks, without spelling the checks in the report.
Serves
[The compiler decides](../principles/compiler-decides.md),
[Relay's words](../principles/relays-words.md),
[What earns a concept](../principles/what-earns-a-concept.md) and
[A fragment is a lens](../principles/fragment-is-a-lens.md). Reopen if an
adopter is on a build system that cannot hand a target the files of its
closure, SwiftPM's plugin being the expected case; if adopters need one
host type per schema enum across sibling targets, which would ask for a
target that generates the schema's types whole; or if a measurement shows
that the checks generated at the spread, repeated in many dependents, cost
more generated code than every lens carrying every check.
Sharpened 2026-11-25, before the build, on the adopter's answer on #59
that the app is a very large Swift and Kotlin app on Bazel with many
modules: the fragments file, the reach, the bare lens name, `@file`
arguments, the third refusal, and the schema types' rule withdrawn for
the one in force. Built 2026-11-25 for the command, both emitters and
`rules_baton`; the Decision reads as built. Not built: the checks
generated at the spread, so the three refusals stand, and SwiftPM's and
Gradle's wiring.

## Context

`batonc` compiles one target at a time. #59 measured it with 0.20.0: a
fragment declared in a target `Shared` and spread in `Screens` is
`error: Undefined fragment 'CharacterStatus_character'` in `Screens` and
`warning: fragment ... is spread by no operation; nothing can read it` in
`Shared`. An app split into a library per feature declares a copy of each
shared fragment, and of the rule that reads it, per feature.

The earlier record settled the report's shape for this case and left the
import unbuilt, to be reopened on this request. The runtime is ready:
slots are numbered by the process, and a generated lens is a
`nonisolated public struct` whose `anchor`, `init(anchor:)` and static
checks are `@_spi(Generated) public`.

The adopter's app is very large, Swift and Kotlin, on Bazel, with many
modules. A target near the top of it depends on most of the others, so
what a compilation is handed and what reruns it are the cost.

Relay has the mechanism and the word. A project names a `base` project,
whose documents can be referenced but produce no artifacts.

## Decision

- A base is a target whose report's head and fragments another target's
  compilation reads: `batonc generate --base <file>`, repeatable, and the
  same for `validate`, `print` and `--check`, which are the same
  compilation. The file is the base's report or its fragments file,
  which `generate --fragments <file>` writes: the report's head
  (`format`, `schemaDigest`, `module`) and, of each fragment the target
  declares, `name`, `type`, `source`, `text` and, under Kotlin,
  `package`. The fragments file is there for the build: it changes only
  when a fragment does, so a build that hands dependents this file and
  not the report reruns a dependent only when a base's fragments change,
  not with each edit to one of the base's operations. The word is
  Relay's; the earlier record's "import" is retired.
- Only the base fragments the target's documents reach, directly or
  through another base fragment, join the compilation. A target at the
  top of an app has every fragment of the app among its bases; it pays
  for what it reaches, not for its closure.
- A reached base fragment's definition, the `text` its base wrote, is
  validated with the target's own documents, inlined into each
  operation's normalization plan and printed in its text; the target
  generates no lens for it and no refetch query from it. An operation's
  printed text and its persisted id therefore cover the base fragments it
  reaches.
- Relay's own handling of base fragments, `base_fragment_names` to
  `apply_transforms` and `remove_base_fragments`, is not used. It removes
  a base fragment from the reader program, and Baton decides at build
  time, from that program, what Relay's runtime decides at run time for a
  spread: the fragment's arguments, its type condition, whether a
  required child can null it. So base fragments stay in every program,
  the lowering marks them as the base's, and the refetch query Relay
  derives from a base's `@refetchable` fragment is dropped. The word
  "base" and the model stay Relay's.
- A spread of a base fragment compiles to the accessor it would have were
  the fragment declared in the same target, returning the base's lens. One
  fragment has one lens, in the target that declares it. In Swift, each
  generated file of a target that spreads base fragments imports each
  such base's module as `@_spi(Generated) import <Module>`, and names the
  base's lens bare, as it names its own: a fragment's name is unique
  among a target and its bases, and a module-qualified name is hidden by
  a type named as its module. In Kotlin, a file imports
  `<package>.<Lens>` for each base lens it names from another package,
  under the opt-in the generated code already declares. The module is the
  base's fact, which its `generate` writes into its report and its
  fragments file. In Swift it is the module `--module` names, which the
  build integration passes. Under Kotlin the head's `module` is the
  package of the target's shared file, the `kotlin.package` of its
  configuration, absent for the default package, and each fragment's
  `package` is its source's, where its lens is; `--module` on a Kotlin
  run is a usage error. A Swift target that reaches a fragment of a base
  whose file names no module is an error naming `--module`.
- Under Kotlin, no two of a target and its bases declare their shared
  file in one package. The shared file's objects, `Types`, `Slots`,
  `Guards` and `Sites`, are public and named alike in every target, so
  two shared files in one package declare one JVM class twice and the
  app loads one of them. A base whose shared file is in the target's
  package is an error at the configuration, naming the base and the
  package; two bases of one package is an error at the second base's
  file, naming both. Every base given is checked, reached or not. Two
  targets may still declare lenses in one package: what may not be
  shared is the package of the shared file.
- The build passes the file of every target in the closure. A report
  carries its own target's fragments and nobody else's. A base fragment
  that spreads a fragment no given base declares is an error that names
  it. An argument `@<file>` is replaced by the arguments the file holds,
  one a line, a build system's params file: the bases of a target at the
  top of an app outgrow a command line.
- Agreement is the schema's digest, which the report already carries and
  which covers the schema's files, the client extensions, `identity` and
  `transient`. A base whose digest differs is an error at the
  configuration, naming the base. Nothing else has to agree: a lookup
  binds in one operation's check, and a mapped scalar converts at the
  read, so neither can give one record two readings.
- A fragment's name is unique among a target and its bases. A duplicate
  is an error at the target's declaration, naming the base and the source
  its file gives; two bases that declare one name is an error naming
  both.
- Arguments need nothing new. A fragment with `@argumentDefinitions` has
  one lens: the clones Relay names by a hash live in the plan and the
  text, which the spreading target builds itself from the definition, and
  the spread binds the fragment's scope at a site of the spreading target.
- What a fragment's own definition settles belongs to its lens in the
  base: `satisfied` for a fragment whose required children can null it,
  the throwing read and `fieldErrors` for one under `@throwOnFieldError`.
  What a spread asks for is generated in the target that asks, from the
  definition: `isPresent` for a spread under `@defer`, `fieldErrors` for a
  spread under `@catch`, the error scan of an `@inline` value spread where
  errors are asked. These are generated today on the fragment's lens, and
  only when the same compilation defers or catches it, which a base
  cannot know of its dependents. Until that half is built, three spreads
  are refused, each with an error at the name of the document that
  spreads, not at the spread itself: a base fragment's spread under
  `@defer`, its spread under `@catch`, and a base `@inline` value spread
  inside a value whose field errors are read.
- Each target generates the enums and input objects its own documents
  name, as before; one that only a base fragment names is the base's and
  is not generated again. Two host types for one enum remain between
  sibling targets, and between a target and a base that both name it, as
  between any two modules today.
- The report grows at its head and in one field. The head gains `format`,
  1 today, so that a base of another format is refused with a message
  naming both, and `module`, the Swift module or, under Kotlin, the
  shared file's package; a fragment entry gains `package` under
  Kotlin. It lists no schema types. A base's fragments are not listed in
  the dependent's report, since the base's report is their home; an
  operation's `fragments` still names every fragment it reaches, a base's
  among them. The earlier record's "changes nothing in the report" holds
  for the operations' entries and not for the head.
- The warning for a fragment no operation reaches says what the compiler
  knows: "fragment `X` is spread by no operation of this target; nothing
  in it reads the fragment". It is not told for a base's fragments. When
  it is silent for a target whose fragments other targets spread is not
  decided here, and no flag is added for it. The candidates are the host
  declaration's own visibility, a `public` property under `@Fragment`,
  and a target that declares no operation; it waits on what #59's shared
  targets look like.
- Build integrations stay shells. `baton_generate` in `rules_baton` gains
  `deps`, other `baton_generate` targets, its bases, and passes the
  closure's fragments files as `--base`, through a params file when they
  are long; and `module`, the Swift module the generated code is
  compiled in, the `module_name` of the `swift_library` that lists the
  sources. It writes `Baton.fragments.json`, the output group
  `fragments`, and returns the provider `BatonInfo`, whose `fragments` is
  a depset of the fragments files of the target and all it depends on,
  exported from `//baton:defs.bzl` for an adopter's own rule that stands
  between two targets. `baton_check_test` takes the same `deps`. Gradle's
  and SwiftPM's wiring wait for an adopter: SwiftPM's plugin is shown one
  target's sources and no other target's outputs.
- The Kotlin emitter takes the same input in the same change, since the
  front end is one
  ([Two runtimes, one compiler](../principles/two-runtimes-one-compiler.md)).
- What is built: the command and both emitters, with the reach, the
  digest, name and module rules, Kotlin's rule on the shared file's
  package and the three refusals; `deps`, `module`
  and `BatonInfo` in `rules_baton`. What is left: the checks generated at
  the spread, which lift the refusals; then SwiftPM's and Gradle's wiring,
  on demand.

## Evidence

- #59's measurement: the two diagnostics above, `batonc` 0.20.0, over
  `spec/rickandmorty/schema.graphql`.
- #59's reproduction compiles at this change: `Shared` generated with
  `--module Shared --fragments`, and `Screens` with `--base` naming that
  file; the dependent imports `Shared` and its accessor returns `Shared`'s
  lens.
- The Kotlin fixture of `scripts/check-bases.sh`, its two modules' shared
  files on one package before the rule, compiled and failed at run time,
  2026-11-25: the dependent's code threw `NoSuchMethodError` on `Slots`
  when it first read a slot only its own `Slots` declares, the app having
  loaded the base's.
- Relay at the pinned v21.0.1: `ConfigFileProject.base` in relay-compiler;
  `relay_transforms::apply_transforms` takes `base_fragment_names`;
  `remove_base_fragments` runs in the reader and typegen pipelines;
  `transform_refetchable_fragment` takes the base names and adds no
  refetch query for a base fragment; `apply_fragment_arguments` runs only
  in the normalization and operation-text pipelines. Baton's driver passes
  an empty set on purpose (`compiler/src/pipeline.rs`, the
  `apply_transforms` call), so that the reader program keeps every base
  fragment the Decision says it must.
- The compiler at `591b59a`: `compiler/src/pipeline/lower.rs` takes lens
  fragments from the reader program, where a fragment with arguments is
  one definition; `compiler/src/decide/reader.rs` collects
  `deferred_fragments` and `caught_fragments` over one program and gives
  a lens `isPresent` or `fieldErrors` from them, and `satisfied` from the
  fragment's own bubbling; a spread with arguments binds at
  `Sites.<site>`, an `ArgumentSite()` value in the spreading module's
  shared file; `compiler/src/emit/shared.rs` prints each enum as
  `nonisolated public enum` in the module's shared file; `schema_digest`
  in `compiler/src/pipeline.rs` hashes the schema's files, the
  extensions, `identity` and `transient`.
- Nothing is measured. Owed, to be recorded in `BENCHMARKS.md`: the time
  of a compilation given N bases, and the generated bytes of a check at
  the spread against the same check on the lens.

## Not chosen

- One compilation for the whole app with outputs per module, which is
  Relay's own shape: build plugins run per target, a change anywhere would
  rerun one action over every source, and a prebuilt dependency would have
  no place.
- The word "import" and a flag of that name: Relay has "base".
- Relay's `base_fragment_names` and `remove_base_fragments`: they take a
  base fragment out of the reader program, from which Baton decides at
  build time what Relay's runtime decides at run time.
- A report that carries the fragments of its own bases: one definition in
  N reports is a fact outside its home.
- Handing dependents the report: each edit to an operation of a base
  would rerun every target above it.
- Every base fragment of the closure joining the compilation: a target at
  the top of an app would compile the app's fragments to use a few.
- A base's lens named with its module, `Shared.CharacterStatus_character`:
  a type named as its module hides the module's name, and the fragment's
  name is already unique among a target and its bases.
- A lens per argument set in the base, or a hashed name to match: the lens
  was never per argument set.
- Generating the base fragment's lens again in the dependent: two host
  types for one fragment, and the shared reader could not take the
  dependent's.
- Every lens carrying every check always: every app would pay in
  generated code for a spread across targets. Not measured; the third
  reopening line names the measurement.
- An enum or an input object a base generated read from the base and not
  generated again, which this record first decided, with the report
  listing the schema types its target generated: when two bases of one
  target both generated an enum, its bare name is ambiguous in the
  target's generated files and in the app's, and a module-qualified name
  is hidden by a type named as its module; and a type's home would move
  the day a base starts reading a field of it. The second reopening line,
  a target that generates the schema's types whole, is the way to one
  host type per enum.
- Agreement on `lookups` and `customScalarTypes`, which #59 asked for.
- A base whose schema is a subset of the target's, which is Relay's rule
  for a base project: one digest cannot say subset, so the digests are
  equal. Reopen when a target needs client extensions its base does not
  have.
- A flag that marks a target as a library or silences the warning: a
  codegen option where the source or the build already holds the fact.
