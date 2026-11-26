# A target spreads the fragments of its bases

Status: accepted, 2026-11-25; not built. Answers
[#59](https://github.com/shergin/baton/issues/59). Supersedes, for the
import,
[The report is what a dependent target's compilation would read](the-report-is-what-a-dependent-target-reads.md),
whose reopening line, an adopter who spreads fragments across modules,
fired with #59. Answers the first reopening line of
[The report holds each lens](the-report-holds-each-lens.md), a consumer
that needs the lens's checks, without spelling the checks in the report.
Narrows
[An enum reads as a generated enum](an-enum-reads-as-a-generated-enum.md)
from once per module to once per target and its bases. Serves
[The compiler decides](../principles/compiler-decides.md),
[Relay's words](../principles/relays-words.md),
[What earns a concept](../principles/what-earns-a-concept.md) and
[A fragment is a lens](../principles/fragment-is-a-lens.md). Reopen if an
adopter is on a build system that cannot hand a target the reports of its
closure, SwiftPM's plugin being the expected case; if adopters need one
host type per schema enum across sibling targets, which would ask for a
target that generates the schema's types whole; or if a measurement shows
that the checks generated at the spread, repeated in many dependents, cost
more generated code than every lens carrying every check.

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

Relay has the mechanism and the word. A project names a `base` project,
whose documents can be referenced but produce no artifacts.

## Decision

- A base is a target whose report another target's compilation reads:
  `batonc generate --base <report>`, repeatable, and the same for
  `validate`, `print` and `--check`, which are the same compilation. The
  word is Relay's; the earlier record's "import" is retired.
- The compilation adds each base fragment's definition, the report's
  `text`, to its program and names them to Relay's transforms as base
  fragments. They are validated with the target's own documents, inlined
  into each operation's normalization plan and printed in its text; no
  lens is generated for them and no refetch query is derived from them. An
  operation's printed text and its persisted id therefore cover the base
  fragments it reaches.
- A spread of a base fragment compiles to the accessor it would have were
  the fragment declared in the same target, returning the base's lens. One
  fragment has one lens, in the target that declares it. The generated
  file imports the base's module with the Generated SPI; in Kotlin, its
  package, under the opt-in the generated code already declares. The
  module is the base's fact: the base's `generate` is told it, in Swift by
  `--module`, which the build integration passes, in Kotlin by the package
  its configuration already names, and writes it into its report.
- The build passes every report in the closure. A report carries its own
  target's fragments and nobody else's. A base fragment that spreads a
  fragment no given report declares is an error that names it.
- Agreement is the schema's digest, which the report already carries and
  which covers the schema's files, the client extensions, `identity` and
  `transient`. A base whose digest differs is an error at the
  configuration, naming the base. Nothing else has to agree: a lookup
  binds in one operation's check, and a mapped scalar converts at the
  read, so neither can give one record two readings.
- A fragment's name is unique among a target and its bases. A duplicate
  is an error at the target's declaration, naming the base and the source
  its report gives; two bases that declare one name is an error naming
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
  cannot know of its dependents. Until that half is built, `@defer` and
  `@catch` on a spread of a base fragment are refused with a diagnostic at
  the spread.
- An enum or an input object that a base generated is read from the base
  and not generated again, so the report lists the schema types its
  target generated. When two bases generated one, the target reads the
  one whose module sorts first by name. Two host types for one enum remain
  between sibling targets, as between any two modules today.
- The report grows at its head only: its format number, so that a base's
  report of another format is refused with a message; the target's
  module; and the schema types it generated. The entries for fragments and
  operations are unchanged. The earlier record's "changes nothing in the
  report" holds for those entries and not for the head.
- The warning for a fragment no operation reaches says what the compiler
  knows: no operation of this target. When it is silent for a target whose
  fragments other targets spread is not decided here, and no flag is added
  for it. The candidates are the host declaration's own visibility, a
  `public` property under `@Fragment`, and a target that declares no
  operation; it waits on what #59's shared targets look like.
- Build integrations stay shells. `baton_generate` in `rules_baton` gains
  `deps`, takes each dependency's report output and passes the closure's
  reports as `--base`. Gradle's and SwiftPM's wiring wait for an adopter:
  SwiftPM's plugin is shown one target's sources and no other target's
  outputs.
- The Kotlin emitter takes the same input in the same change, since the
  front end is one
  ([Two runtimes, one compiler](../principles/two-runtimes-one-compiler.md)).
- The order of the build: the command and both emitters, with the digest,
  name and module rules and the refusal under `@defer` and `@catch`; then
  `deps` in `rules_baton`; then the checks at the spread and the schema
  types' home; then the other build systems on demand.

## Evidence

- #59's measurement: the two diagnostics above, `batonc` 0.20.0, over
  `spec/rickandmorty/schema.graphql`.
- Relay at the pinned v21.0.1: `ConfigFileProject.base` in relay-compiler;
  `relay_transforms::apply_transforms` takes `base_fragment_names`;
  `remove_base_fragments` runs in the reader and typegen pipelines;
  `transform_refetchable_fragment` takes the base names and adds no
  refetch query for a base fragment; `apply_fragment_arguments` runs only
  in the normalization and operation-text pipelines. Baton's driver passes
  an empty set (`compiler/src/pipeline.rs`, the `apply_transforms` call).
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
- Nothing is built and nothing is measured. Owed when it is built, to be
  recorded in `BENCHMARKS.md`: the time of a compilation that reads N
  reports, and the generated bytes of a check at the spread against the
  same check on the lens.

## Not chosen

- One compilation for the whole app with outputs per module, which is
  Relay's own shape: build plugins run per target, a change anywhere would
  rerun one action over every source, and a prebuilt dependency would have
  no place.
- The word "import" and a flag of that name: Relay has "base".
- A report that carries the fragments of its own bases: one definition in
  N reports is a fact outside its home.
- A lens per argument set in the base, or a hashed name to match: the lens
  was never per argument set.
- Generating the base fragment's lens again in the dependent: two host
  types for one fragment, and the shared reader could not take the
  dependent's.
- Every lens carrying every check always: every app would pay in
  generated code for a spread across targets. Not measured; the third
  reopening line names the measurement.
- Agreement on `lookups` and `customScalarTypes`, which #59 asked for.
- A base whose schema is a subset of the target's, which is Relay's rule
  for a base project: one digest cannot say subset, so the digests are
  equal. Reopen when a target needs client extensions its base does not
  have.
- A flag that marks a target as a library or silences the warning: a
  codegen option where the source or the build already holds the fact.
