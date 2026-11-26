# Bazel: the compiler as a toolchain, and one rule over its command

`rules_baton` is [the command's contract](batonc.md) spelled in Starlark:
a toolchain the module fetches from the release's artifact bundle, and
`baton_generate`, which runs `batonc generate` as one sandboxed action.
Every input and output is declared, and the action yields the generated
sources for the library rule you already have. The module lives under
`bazel/` in this repository and is versioned with Baton, so `rules_baton`
0.11.0 fetches the bundle 0.11.0 published and writes the format the
runtime reads. It holds no logic of its own: which source writes which
output, the header for a source without GraphQL, staleness, and
diagnostics are the compiler's
([the decision](../decisions/a-build-integration-holds-no-logic.md)).

## The runtime

The runtime arrives as any Swift package does under
`rules_swift_package_manager`, resolved from `Package.swift`:
`@swiftpkg_baton//:Baton`, with `BatonTesting` and `BatonInspector` beside
it, and the macros as a compiler plugin target. The SwiftPM build-tool
plugin and the compiler's binary target are skipped by design, since
`rules_swift_package_manager` runs no plugin, and this module is what
runs the compiler instead. On the Kotlin side, `language = "kotlin"` writes
`.baton.kt` for a `kt_jvm_library` or a `kt_android_library` over the
runtime's Maven artifact, `com.shergin.baton:baton`
([the Gradle recipe](gradle.md) names them).

## The module

```python
bazel_dep(name = "rules_baton", version = "0.11.0")
```

Until the module is in the Bazel Central Registry, take it from the
release's tag. There it is the `bazel/` directory of the archive:

```python
archive_override(
    module_name = "rules_baton",
    strip_prefix = "baton-0.11.0/bazel",
    urls = ["https://github.com/shergin/baton/archive/refs/tags/v0.11.0.tar.gz"],
)
```

The module registers its toolchains itself. Its extension downloads
`batonc.artifactbundle.zip` of the release it is versioned with, the one
file SwiftPM downloads. It checks that zip against the checksum the
release wrote into `bazel/baton/release.bzl`, reads the bundle's
`info.json`, and registers a toolchain per triple it lists. The execution
platform selects its binary: macOS or Linux, x86_64 or aarch64. Nothing
is pinned by URL. A checkout that builds its own compiler names it
instead, as `Package.swift` takes `BATON_COMPILER`:

```bash
bazel build --repo_env=BATON_COMPILER=/path/to/batonc //...
```

The path is a `batonc` binary, or a bundle directory holding an
`info.json`, such as the one `scripts/build-compiler.sh` writes.

## `baton_generate`

```python
load("@rules_baton//baton:defs.bzl", "baton_generate")
load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

baton_generate(
    name = "screens_graphql",
    srcs = glob(["Sources/Screens/**/*.swift", "Sources/Screens/**/*.graphql"]),
    config = "Sources/Screens/baton.json",
    schema = "//graphql:schema.graphql",
    schema_extensions = ["//graphql:client-fields.graphql"],
)

swift_library(
    name = "Screens",
    srcs = glob(["Sources/Screens/**/*.swift"]) + [":screens_graphql"],
    deps = ["@swiftpkg_baton//:Baton"],
    plugins = ["@swiftpkg_baton//:BatonMacros.rspm"],
)
```

- **One action, every input declared:** the sources, the configuration,
  the schema, the extensions, and the compiler, so remote execution and
  caching work. `--schema` is passed explicitly, so the schema may be
  another rule's output. `schema` takes one file, or a target of
  several, such as a `filegroup` over a `glob` of the directory a
  configuration's `schemaDir` names, and passes each file as its own
  `--schema`, in the target's order. The files are a set: their order
  and their names change neither the schema nor its digest, so the
  digest is the one the other builds write. The configuration's `schemaExtensions` resolve
  relative to the configuration, as they do under the SwiftPM plugin,
  since the sandbox holds every declared input at its path. List the
  files in `schema_extensions` and leave the configuration as it is.
- **One output per source,** named as the SwiftPM plugin names it. Take
  the source's path relative to the rule's package, turn each separator
  into an underscore, and put `.baton.swift` in place of `.swift` and
  after any other extension. A source from another repository is named
  relative to that repository's root. A source without GraphQL writes a
  header-only file, so the set of outputs follows from `srcs` and no file
  is read at analysis time. The files are written under
  `bazel-bin/<package>/<name>/`, beside the shared `Baton.baton.swift`.
- **The default output is the generated sources,** to list in the `srcs`
  of your `swift_library`, `kt_jvm_library`, or in-house macro, with the
  runtime and the macro plugin in that rule's own attributes. The report
  is the output group `report`, the fragments file the output group
  `fragments`, and under `persistConfig` the persisted
  documents file is the output group `persisted`, named by the
  `persisted` attribute, since a rule declares its outputs before it can
  read the configuration:

  ```python
  baton_generate(
      name = "screens_graphql",
      persisted = "persisted-documents.json",
      ...
  )
  ```

  ```bash
  bazel build --output_groups=report,persisted //modules/Screens:screens_graphql
  ```

  A registration step or a review bot depends on the group and never
  rebuilds the library.
- **Diagnostics** are `path:line:column: error: message`, pointing into
  the GraphQL text in the host file, and a document with an error fails
  the action with nothing written.

## Bases: `deps` and `module`

A target spreads the fragments of another target, its
[base](../terminology.md#compiler), when it lists that target's
`baton_generate` in `deps`, as its `swift_library` lists the base's
library for the lenses:

```python
baton_generate(
    name = "shared_graphql",
    srcs = glob(["Sources/Shared/**/*.swift"]),
    config = "Sources/Shared/baton.json",
    schema = "//graphql:schema.graphql",
    module = "Shared",
)

swift_library(
    name = "Shared",
    module_name = "Shared",
    srcs = glob(["Sources/Shared/**/*.swift"]) + [":shared_graphql"],
    deps = ["@swiftpkg_baton//:Baton"],
    plugins = ["@swiftpkg_baton//:BatonMacros.rspm"],
)

baton_generate(
    name = "screens_graphql",
    srcs = glob(["Sources/Screens/**/*.swift"]),
    config = "Sources/Screens/baton.json",
    schema = "//graphql:schema.graphql",
    deps = [":shared_graphql"],
)

swift_library(
    name = "Screens",
    srcs = glob(["Sources/Screens/**/*.swift"]) + [":screens_graphql"],
    deps = [":Shared", "@swiftpkg_baton//:Baton"],
    plugins = ["@swiftpkg_baton//:BatonMacros.rspm"],
)
```

- **`module`** is the Swift module the generated sources are compiled in,
  the `module_name` of the `swift_library` that lists them. A Swift
  target others list in `deps` names it: a dependent's generated files
  import that module as `@_spi(Generated) import Shared` and name its
  lenses bare. It is Swift's: a Kotlin target does not set it, and
  `batonc` refuses `--module` on a Kotlin run. A Kotlin target's
  fragments file names the package of its shared file, the
  `kotlin.package` of its configuration, and a dependent reads each
  lens's package from the base. No two Kotlin targets of a closure may
  name one `kotlin.package`.
- **`deps`** are the base's `baton_generate` targets, the ones the
  library's own `deps` mirror. Each is passed with all it depends on in
  turn as `--base`: an operation's text prints every fragment it reaches,
  however deep its base. The arguments go through a params file, since
  the bases of a target at the top of an app outgrow a command line. Only
  the base fragments the target's documents reach join its compilation.
- **The fragments file** is what a dependent reads, not the report:
  every `baton_generate` writes `Baton.fragments.json`, the output group
  `fragments`, which changes only when one of its fragments does, so an
  edit to one of a base's operations reruns no dependent.
- **`BatonInfo`**, exported from `@rules_baton//baton:defs.bzl`, is what
  a `baton_generate` returns for the targets that list it: `fragments`,
  a depset of the fragments files of the target and all it depends on. A
  rule of your own that stands between two targets forwards it.

A base of another schema's digest, a fragment's name declared twice, a
Kotlin base whose shared file is in the target's package or another
base's, or a base fragment's spread under `@defer` or `@catch`, which is
not built yet, fails the action with an error;
[the command's contract](batonc.md#bases) lists them all.

## `baton_check_test`

For a team that commits its generated code, use the same inputs as a
`baton_generate`, plus the committed files. The test runs
`batonc generate --check` over them and fails with each stale or missing
output named on stderr.

```python
load("@rules_baton//baton:defs.bzl", "baton_check_test")

baton_check_test(
    name = "screens_check",
    srcs = glob(["Sources/Screens/**/*.swift"]),
    config = "Sources/Screens/baton.json",
    schema = "//graphql:schema.graphql",
    generated = glob(["Generated/*"]),
    generated_dir = "Generated",
)
```

The committed `Generated/` is the `baton_generate` target's output, copied
from `bazel-bin`, or the result of `batonc generate --out Generated`, run
from the package's directory, which names the outputs by the same rule.
A target with bases lists the same `deps` as its `baton_generate`, since
the check is the same compilation.

## The example

`bazel/examples/rickandmorty` generates the Rick and Morty sample's
screens from `examples/RickAndMorty` and
`spec/rickandmorty/schema.graphql`. Those are read in place through
`new_local_repository`, against the module at `../..`.
`scripts/check-bazel.sh` builds that example in the sandbox, over the
compiler built in the checkout. The script copies the output into
`Generated/` and runs the check test. Then it edits one file and runs
the test again. It also builds and checks
`bazel/examples/rickandmorty/several`, whose schema is a filegroup of two
files, the extension's file first, and
`bazel/examples/rickandmorty/bases`, where `screens` spreads a fragment
declared in `shared` through `deps`. CI's `bazel` job is that script. The example compiles
nothing: the generated Swift is what the SwiftPM plugin writes for the
same sources, and the package's own build compiles it.
`scripts/check-bases.sh` is the half that compiles: two modules of one
app, the second spreading a fragment the first declares, generated with
`--fragments` and `--base` over the same compiler, built and tested in
Swift and in Kotlin. CI's `swift` and `kotlin` jobs run its halves.

## What the module does not do

- Wrap `swift_library`. Every attribute rules_swift adds would be one the
  wrapper must learn, and a monorepo already wraps `swift_library` once.
  The rule yields sources, and your rule compiles them. If two adopters'
  macros around `baton_generate` turn out the same, that macro has earned
  a home here.
- Take a schema extension or a root directory as a flag. An extension is
  a source beside the configuration, which the sandbox holds. A rule that
  names its outputs needs no root. The report's sources are relative to
  the execroot, which is the workspace, so two checkouts' reports diff
  clean.
