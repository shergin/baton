# The report holds each lens

Status: accepted, 2026-10-09. Extends
[The report is what a dependent target's compilation would read](the-report-is-what-a-dependent-target-reads.md).
Serves [The compiler decides](../principles/compiler-decides.md). Reopen
if a consumer needs the lens's checks (`satisfied`, `fieldErrors`) or its
connection surface spelled out too, or if the lenses make the report too
large to review as a diff.

## Context

The report listed what a target compiled but not what its code reads as. A
lens's accessors are the target's surface: their names, which response key
each reads, whether each reads absent, a `@catch` result, a throwing read
or a list. That surface is decided once, in the decide pass, and each
emitter only prints it. Two readers needed it as data: a reviewer, for whom
a renamed accessor or a field that starts throwing is a contract change the
report did not show, and the harness for Relay's reader tests
(`spec/relay/`), which generates one read per response path and must spell
each step as the accessor reads, with `?.`, `try` or a result's `get()`,
without parsing generated code.

## Decision

`generate --report` adds to every operation its data's lens and to every
fragment its lens. A lens is its GraphQL type and its accessors in order;
an accessor is its name as the target's language spells it unescaped, the
response key it reads (none for a spread or a type condition, which read
their parent's object), what it reads (`scalar`, `linked`, `spread`,
`aliased`, `condition`), and its shape: `optional` when it may read absent,
`caught` with whether the result's value may be absent, `throws`, `list`
with whether an element may be absent, the fragment a spread reads, the
types a condition reads for, and the nested lens. The shape is derived from
the decided read forms by the rules both emitters print, so the report and
the code cannot disagree on what the program decided. A report written from
the plan alone, before the decide pass, has no lenses.

## Evidence

- `BatonTests.report.json`, the golden over the Swift test target, holds
  the lenses of every document the tests compile.
- The report's tests: an accessor's key under an alias, the shapes of
  `@required(action: THROW)`, `@catch`, `@catch(to: NULL)`, a caught link,
  a list of links and an `@include`, a type condition's types, a spread's
  fragment.
- `scripts/relay-harvest/translate.py` generates the Relay reader cases'
  reads from the report; the Swift test target compiles every one.

## Not chosen

- Parsing the generated Swift for its accessors: the generated code is
  printed for a compiler, not read by one, and Kotlin would need a second
  parser.
- A separate `--lenses` output: the lenses are the target's contract as
  much as the operations are, and the report is where the contract is
  read.
