# A build integration holds no logic of its own

Status: accepted, 2026-10-07. Answers
[#40](https://github.com/shergin/baton/issues/40) and revises the stance
taken on [#8](https://github.com/shergin/baton/issues/8), that a Bazel rule
stays an example over the command. Serves
[The compiler decides](../principles/compiler-decides.md) and
[What earns a concept](../principles/what-earns-a-concept.md). Reopen when
a build system cannot declare an output from what it shows a rule and no
flag on the command can tell it.

## Context

`batonc generate` is the compiler's one command, and
[the command's contract](../recipes/batonc.md) is its contract. The SwiftPM
plugin is a shell over it: it declares the inputs and the outputs and runs
the command with an `--emit` per source, `--shared` and `--report`, and
holds no rule of its own about what is written where. #8 asked for a Bazel
rule; the answer, in October 2026, was a `genrule` on the contract page and
not a ruleset the project versions, since a second supported integration
would be a second place for the command's flags and diagnostics to drift,
and the line that would reopen it was two teams copying the example
unchanged.

#40 measured a Bazel adoption and found that the example cannot be copied
unchanged. A `genrule` needs every output named, so a hand-kept list drifts
as sources gain and lose markers; the toolchain is an `http_archive` each
team writes per release and per platform; the persisted documents file is
named by the configuration, which a rule cannot read at analysis time; and
the bundle had no Linux binary for the CI a Bazel repository runs. The
Kotlin runtime is heading for Gradle on Linux, a third shell.

## Decision

- A build integration is the command spelled in the build system's
  language, and holds no logic of its own. It declares inputs and outputs
  and runs `batonc generate`. Which source writes which output, the header
  for a source without GraphQL, the shared file, staleness and diagnostics
  are the compiler's. A shell that needs more gets a flag on the command,
  never a branch of its own; `--persisted <file>` is the one this record
  adds, so that every output has a flag that names it.
- The integrations live in this repository and are versioned with it: the
  SwiftPM plugin under `swift/Plugins`, the Bazel module `rules_baton`
  under `bazel/`, a Gradle plugin when the Kotlin runtime ships. The
  release commit stamps each with the version and the bundle's checksum,
  so a release is one artifact bundle and the shells that fetch it.
- The Bazel rule yields generated sources and nothing else.
  `baton_generate` returns the files a `swift_library`, a `kt_jvm_library`
  or an adopter's own macro lists in its `srcs`, with the report and the
  persisted documents file as output groups. It wraps no library rule.
- The toolchain is the release's artifact bundle: the module extension
  downloads the one file SwiftPM downloads, reads its `info.json` and
  registers a toolchain per triple it lists; `BATON_COMPILER` names a
  checkout's own compiler instead, as it does for `Package.swift`.
- The bundle carries a static Linux binary per architecture beside the
  universal macOS one, so a Linux host, SwiftPM or Bazel, takes the
  compiler from the same file.

## Evidence

- `swift/Plugins/BatonPlugin/BatonPlugin.swift`, read 2026-10-07: the
  plugin lists inputs and names outputs; the compiler reports the
  shared-file collision and the duplicate output, writes the header for a
  source without GraphQL and removes stale outputs. The rule is the same
  hundred lines in Starlark.
- #40's claims, checked against the compiler at `1a14d65` and by running
  it: `--emit` already wrote the header-only output for any source;
  `--schema` beside `--config` already overrode the configuration's schema;
  the persisted documents file already went under `--out`. What a rule
  could not do was declare that file without reading `baton.json`.
- A sandbox mirrors the execroot, so a path relative to the configuration
  resolves to a declared input; a rule that names its outputs needs
  neither `--root` nor a flag per schema extension.
- The compiler has built and tested on Linux in CI since the Kotlin lane
  began, so the Linux binaries were packaging, not porting.
- `scripts/check-bazel.sh`: the example workspace builds the sample's
  screens in the sandbox, and the check test passes over fresh output and
  fails over a stale one; without `BATON_COMPILER` the extension downloads
  the release's bundle and the same target builds with it.

## Not chosen

- A `baton_library` wrapping `swift_library` with pass-through attributes:
  each attribute rules_swift adds is one the wrapper must learn, and a
  monorepo already wraps `swift_library` once. Reopen when two adopters'
  macros around `baton_generate` turn out the same.
- `--schema-extension`: an extension is a source file beside the
  configuration, which resolves in the sandbox. Reopen when a client
  extension is a build's own output.
- `--root`: a rule that emits per source names each output, and the
  report's sources are relative to the execroot, which is the workspace.
- A sibling `rules_baton` repository: a second place for the contract's
  docs to drift from the code, and a second release cadence. Reopen when
  the Bazel Central Registry cannot take a module from a release's
  subdirectory.
- The rule as an example only, as #8 had it: the example could not be
  copied unchanged, so its reopening line could never fire.
