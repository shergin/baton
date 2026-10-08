# Bazel: the compiler as a toolchain, and one rule over its command

`rules_baton` is [the command's contract](batonc.md) spelled in Starlark:
a toolchain the module fetches from the release's artifact bundle, and
`baton_generate`, which runs `batonc generate` as one sandboxed action with
every input and output declared and yields the generated sources for the
library rule the adopter already has. It lives under `bazel/` in this
repository and is versioned with Baton, so `rules_baton` 0.11.0 fetches
the bundle 0.11.0 published and writes the format that runtime reads. It
holds no logic of its own: which source writes which output, the header
for a source without GraphQL, staleness and diagnostics are the compiler's
([the decision](../decisions/a-build-integration-holds-no-logic.md)).

## The runtime

The runtime arrives as any Swift package does under
`rules_swift_package_manager`, resolved from `Package.swift`:
`@swiftpkg_baton//:Baton`, with `BatonTesting` and `BatonInspector` beside
it and the macros as a compiler plugin target. The SwiftPM build-tool
plugin and the compiler's binary target are skipped by design, since
`rules_swift_package_manager` runs no plugin; this module is what runs the
compiler instead. On the Kotlin side, `language = "kotlin"` writes
`.baton.kt` for a `kt_jvm_library` or a `kt_android_library`, for when the
Kotlin runtime is published.

## The module

```python
bazel_dep(name = "rules_baton", version = "0.11.0")
```

Until the module is in the Bazel Central Registry, it is taken from the
release's tag, where it is the `bazel/` directory of the archive:

```python
archive_override(
    module_name = "rules_baton",
    strip_prefix = "baton-0.11.0/bazel",
    urls = ["https://github.com/shergin/baton/archive/refs/tags/v0.11.0.tar.gz"],
)
```

The module registers its toolchains itself. Its extension downloads
`batonc.artifactbundle.zip` of the release it is versioned with, the one
file SwiftPM downloads, checks it against the checksum the release wrote
into `bazel/baton/release.bzl`, reads the bundle's `info.json` and
registers a toolchain per triple it lists, so the execution platform,
macOS or Linux, x86_64 or aarch64, selects its binary. Nothing is pinned
by URL. A checkout that builds its own compiler names it instead, as
`Package.swift` takes `BATON_COMPILER`:

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
  the schema, the extensions and the compiler, so remote execution and
  caching work. `--schema` is passed explicitly, so the schema may be
  another rule's output. The configuration's `schemaExtensions` resolve
  relative to the configuration, as they do under the SwiftPM plugin,
  since the sandbox holds every declared input at its path: list the files
  in `schema_extensions` and leave the configuration as it is.
- **One output per source,** named as the SwiftPM plugin names it: the
  source's path relative to the rule's package, each separator an
  underscore, `.baton.swift` in place of `.swift` and after any other
  extension; a source from another repository is named relative to that
  repository's root. A source without GraphQL writes a header-only file,
  so the set of outputs follows from `srcs` and no file is read at
  analysis time. They are written under `bazel-bin/<package>/<name>/`,
  beside the shared `Baton.baton.swift`.
- **The default output is the generated sources,** to list in the `srcs`
  of the adopter's `swift_library`, `kt_jvm_library` or in-house macro,
  with the runtime and the macro plugin in that rule's own attributes.
  The report is the output group `report`, and under `persistConfig` the
  persisted documents file is the output group `persisted`, named by the
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

## `baton_check_test`

For a team that commits its generated code: the same inputs as a
`baton_generate` and the committed files, and a test that runs
`batonc generate --check` over them, failing with each stale or missing
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

The committed `Generated/` is the `baton_generate` target's output copied
from `bazel-bin`, or `batonc generate --out Generated` run from the
package's directory, which names the outputs by the same rule.

## The example

`bazel/examples/rickandmorty` generates the Rick and Morty sample's screens
from `examples/RickAndMorty` and `spec/rickandmorty/schema.graphql`, read
in place through `new_local_repository`, against the module at `../..`.
`scripts/check-bazel.sh` builds it in the sandbox over the compiler built
in the checkout, copies the output into `Generated/`, runs the check test,
edits one file and runs it again; CI's `bazel` job is that script. The
example compiles nothing: the generated Swift is what the SwiftPM plugin
writes for the same sources, which the package's own build compiles.

## What the module does not do

- Wrap `swift_library`. Every attribute rules_swift adds would be one the
  wrapper must learn, and a monorepo already wraps `swift_library` once;
  the rule yields sources and the adopter's rule compiles them. If two
  adopters' macros around `baton_generate` turn out the same, that macro
  has earned a home here.
- Take a schema extension or a root directory as a flag. An extension is a
  source beside the configuration, which the sandbox holds; a rule that
  names its outputs needs no root. The report's sources are relative to
  the execroot, which is the workspace, so two checkouts' reports diff
  clean.
