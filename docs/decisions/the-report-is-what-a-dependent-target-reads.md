# The report is what a dependent target's compilation would read

Status: accepted, 2026-10-11; extended by
[The report holds each lens](the-report-holds-each-lens.md). Answers
[#17](https://github.com/shergin/baton/issues/17)'s compile report and the
manifest side of [#7](https://github.com/shergin/baton/issues/7), and
settles the shape of the report before fragments across modules need it.
Serves [What earns a concept](../principles/what-earns-a-concept.md) and
[The compiler decides](../principles/the-compiler-decides.md). Reopen the
import when an adopter spreads fragments across modules, which the record
expects on a Bazel build with hundreds of fragments.

## Context

The compiler compiled a target and left two accounts of it: the generated
Swift, which only the compiler reads, and the persisted documents file,
which exists only under `persistConfig` and lists ids and texts. The people
who register operations and review contract changes had no account to read,
and a dependent target's compilation, should a fragment ever be declared in
one module and spread in another, had nothing to read either. The runtime
is ready for that case: lenses are public behind SPI, and slots are numbered
by the process because modules compile apart. The compiler and the plugin
see one target.

## Decision

`batonc generate --report <file>` writes one report per target, and the
SwiftPM plugin writes it into the build's output directory as
`Baton.report.json`. The report is JSON, deterministic, by name: the
schema's digest; every operation with its name, kind, source, id when
persisted, variables as the schema types them, the fragments it reaches
directly or through other fragments, and its text; every fragment with its
name, type condition, source, the operations that reach it, and its
definition as the author wrote it, printed before the transforms, which
rename a fragment with arguments by a hash and drop one nothing spreads.
Sources are relative to the working directory.

The fragment's printed definition and type condition are there for the
dependent target: a compilation given a dependency's report could resolve a
spread of one of its fragments without the dependency's sources, and import
the lens the dependency generated. That import is not built. The report's
shape is settled now so that building it adds an input to the compiler and
changes nothing in the report.

`validate`, `print` and `--check` are the same compilation with another
output, not other compilations.

## Evidence

The report is a view of the plan: every fact in it already exists at the
end of the pipeline, and the reach is a walk over the reader selections the
plan holds. One golden over the Swift test target fixes its bytes. The
persisted documents file is a projection of the report's operations.

## Not chosen

- A Markdown summary beside the JSON. A reviewer reads a diff of the JSON;
  a script reads the JSON. Two formats would drift.
- Generated code sizes per fragment. The emitter writes typed pieces, not
  files per fragment, so the number would be an estimate.
- The report as the plugin's input for a dependency. The plugin API shows
  one target's sources; the case has no adopter yet.
