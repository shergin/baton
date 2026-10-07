# `batonc`: the command's contract

`batonc` is the compiler the SwiftPM plugin runs. It is one binary, in the
artifact bundle each release publishes and `scripts/build-compiler.sh` builds
from `compiler/` in a checkout, and its command line is the contract a build
outside SwiftPM uses: Bazel, a committed-output step, an editor's check. What
follows is that contract. Its output is deterministic: the same schema,
configuration and sources produce the same bytes, which the goldens under
`compiler/src/tests` fix.

## Commands

```
batonc generate --config <baton.json> (--out <dir> | --emit <source>=<output>...) [--shared <file>] [--report <file>] [--check] <files...>
batonc validate --config <baton.json> <files...>
batonc print <OperationName> --config <baton.json> <files...>
```

`--schema <sdl>` may replace `--config` when there is no configuration; the
configuration's `schema` is otherwise the schema, relative to the
configuration's directory, as are its `schemaExtensions` and the persisted
documents file.

`<files...>` are the target's Swift sources and its `.graphql` or `.gql`
documents. The compiler reads the GraphQL out of the Swift markers
(`@Fragment`, `@Query`, `@Mutation`, `@Subscription`, bare or qualified as
`@Baton.Query`) and compiles every document of the target together, since a
fragment spread in one file is declared in another.

### `generate`

Writes, and writes nothing when a document has an error:

- **One output per Swift source that declares GraphQL**, named under `--out`
  by the source's path relative to the working directory with each separator
  an underscore and `.baton.swift` in place of `.swift`
  (`Sources/App/Screen.swift` writes `Sources_App_Screen.baton.swift`), or
  exactly where `--emit <source>=<output>` says. A source that names a
  marker but holds no document gets a header only, so a build system never
  sees a missing output. Under `--out`, a `.baton.swift` in the directory
  that this run did not write is removed, so a renamed source leaves nothing
  behind.
- **The shared file**, `Baton.baton.swift` under `--out` or `--shared
  <file>`: the types every output names, the schema's digest, the format
  marker.
- **The persisted documents file**, under `persistConfig`: beside the
  configuration, or under `--out` when given.
- **The report**, `--report <file>`: what the target compiled, as JSON. See
  [Report](../terminology.md#compiler).

`--check` writes nothing: every output is computed and compared with the
file at its path, each stale or missing one is named on stderr, and the
exit code is 1 when any is. A team that commits its generated code runs
`generate` as a developer step and `generate --check` in CI.

### `validate`

The same compilation with no output: diagnostics and an exit code, for an
editor or a pre-commit hook.

### `print`

The same compilation, printing one operation's text, the exact text the app
sends, compact on one line as the compiler prints it, preceded by
`# documentId: <id>` under `persistConfig`, for pasting into a server's
tool, which formats it.

## Diagnostics and exit codes

Diagnostics are printed to stderr as `path:line:column: severity: message`,
with the position inside the GraphQL text in the host Swift file, so Xcode
and Bazel both show them at the line. A warning does not fail the command.

| Exit | Meaning |
|---|---|
| 0 | Done; warnings may have been printed. |
| 1 | A document has an error, an output is stale under `--check`, or a file could not be read or written; the reason is on stderr. |
| 2 | No command, or one `batonc` does not have. |

## Under the SwiftPM plugin

The plugin runs one `generate` per target with `--out` in its own output
directory, `--shared`, `--report`, and an `--emit` for each Swift source
that names a marker; the generated Swift joins the target's sources, and the
report and the persisted documents file sit beside them, undeclared, so
SwiftPM does not bundle them as resources. `baton.json` is read from the
target's directory, then the package root.

## Outside SwiftPM: committed output

```bash
batonc generate --config Sources/App/baton.json --out Sources/App/Generated Sources/App/*.swift
```

Commit `Sources/App/Generated`, add it to the target's sources, and gate with
`--check`:

```bash
batonc generate --config Sources/App/baton.json --out Sources/App/Generated --check Sources/App/*.swift
```

## Outside SwiftPM: a Bazel `genrule`

An example over the contract, not a ruleset this repository versions; the
binary comes from the release's artifact bundle through an `http_archive`.

```python
genrule(
    name = "app_graphql",
    srcs = glob(["Sources/App/*.swift"]) + ["Sources/App/baton.json", "schema.graphql"],
    outs = [
        "Generated/Baton.baton.swift",
        "Generated/Sources_App_Screen.baton.swift",
        "Generated/Baton.report.json",
    ],
    cmd = """
        $(location @batonc//:batonc) generate \\
            --config $(location Sources/App/baton.json) \\
            --out $(RULEDIR)/Generated \\
            --report $(RULEDIR)/Generated/Baton.report.json \\
            $(locations Sources/App/*.swift)
    """,
    tools = ["@batonc//:batonc"],
)

swift_library(
    name = "App",
    srcs = glob(["Sources/App/*.swift"]) + [":app_graphql"],
    deps = ["@baton//:Baton"],
)
```

Every input is declared, the schema included, so remote execution and
caching work; the `outs` list names each source's output by the rule above.
