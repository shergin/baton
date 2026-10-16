# The compiler

`batonc` finds the GraphQL in Swift and Kotlin sources, and in `.graphql` files. It validates every document against the schema, assembles the operations, and writes the lenses and the plans. It decides at build time everything a runtime client decides at run time: identity, aggregation, masking, storage keys, persisted ids, nullability, diagnostics. The runtime interprets what it wrote, and it never parses GraphQL.

## What it reads

A target's configuration is `baton.json`, beside the target or at the package root.

| key | what |
|---|---|
| `schema` | the SDL file, relative to the configuration |
| `schemaExtensions` | client schema extensions: files of `.graphql` that give server types client fields |
| `identity` | the key fields per type, `id` by default; a `default` list and `types` entries, interfaces included |
| `lookups` | root fields answered from the store by id before the network |
| `customScalarTypes` | a scalar's host type per language, and the Kotlin converter |
| `transient` | the types and root fields that never reach the image |
| `persistConfig` | Relay's: the file and the hash algorithm, under which an operation is sent by id |
| `onError` | the error behaviour sent with every operation |
| `kotlin.package` | the package of the Kotlin shared file |

The hosts are every Swift or Kotlin file of the target, and every `.graphql` file beside them. They are compiled together, since a fragment spread in one file is declared in another.

## What it checks

It checks everything Relay's compiler checks, because the front end is Relay's, pinned to a release. Unknown fields, wrong arguments, missing variables, a spread of an undefined fragment, a directive where it cannot go. The diagnostic names the file, the line, and the column inside the GraphQL text in the host file, so the editor shows it on the line. A document with an error writes nothing.

{{diagnostics typo | A misspelled field, with the schema's suggestion.}}

{{diagnostics unknown-fragment | A query that spreads a fragment nobody declared.}}

Baton adds its own checks on top. A name that generated code reserves. A fragment that is both a lens and a value. An operation made of client fields alone. A Kotlin document with a template in a plain string. A fragment spread by no operation is a warning, since nothing could ever read it.

## What it writes

One output per source that declares GraphQL, named by the source's path, and one shared file per target. The shared file holds the types and the storage keys every output names. The generated code is one line per field, plus the data tables the runtime walks a response by. There is no model, no decoder, no cache policy, and no reflection.

{{generated issues IssueRow | The lens of one fragment. A struct in Swift and a class in Kotlin, holding its anchor and one accessor per field. A linked field is a nested lens. An abstract field reads its slot on the concrete type.}}

{{generated issues shared | The shared file. The schema's digest, the format the runtime must declare, and every type and storage key the target's documents name, interned once per process.}}

The format is a number. The shared file names it, and the runtime declares it. Generated code of another format fails to compile at that one line, with a message, so a runtime and a compiler from different releases never meet silently.

## The report

`--report` writes what the target compiled, as JSON. Each operation has its kind, its variables, the fragments it reaches, and its text. Each fragment has its type and the operations that spread it. Each lens has its accessors, what each reads, and as what. A reviewer reads the report for a contract change. A dependent target's compilation would read it too. Every lens plate on this site is drawn from it.

{{lens comments IssueComments_issue | A fragment's lens from the report. The response key each accessor reads under, whether it may read absent, and the nested lenses.}}

## Persisted operations

Under `persistConfig`, the compiler hashes each operation's text and writes Relay's map from id to text, for the server to register. The artifact carries the id and no text. The request then sends `documentId`, and the server runs nothing it has not seen. Without `persistConfig`, the artifact carries the text and no id. The build decides, and no transport has a mode or a fallback.

{{operation issues IssuesQuery | An operation under `persistConfig`. The id it is sent as, and the text the server registers it under. `batonc print` prints both.}}

## How the build runs it

- **SwiftPM** runs it through `BatonPlugin`, a build-tool plugin over the release's artifact bundle, one `generate` per target. Nothing to install. The bundle is prebuilt for macOS and Linux.
- **Gradle** runs it through `com.shergin.baton`, a task with every input and output declared, over the same bundle. [Gradle](../../recipes/gradle/) has the setup.
- **Bazel** runs it through `rules_baton`, the command as one sandboxed action. [Bazel](../../recipes/bazel/) has the rule.
- **Anything else** runs the command itself. [The command line](../../recipes/batonc/) is the contract: `generate`, `validate` for an editor or a hook, `print` for one operation's text, and `--check` for a team that commits its generated code.

```sh
batonc validate --config baton.json Sources/App/*.swift
batonc generate --config baton.json --out Sources/App/Generated --check Sources/App/*.swift
```

The output is deterministic. The same schema, the same configuration, and the same sources produce the same bytes. Goldens in the repository fix those bytes for both languages. In a checkout, `scripts/build-compiler.sh` builds the binary, and `BATON_COMPILER` points any of the integrations at it.

## Why it is this way

[The compiler decides](../../principles/compiler-decides/) is the principle. [Relay's front end, pinned, behind our driver](../../decisions/relay-front-end/) is the decision that keeps the vocabulary Relay's, while everything after the plan is ours.
