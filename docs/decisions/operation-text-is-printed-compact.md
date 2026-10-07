# An operation's text is printed compact

Status: accepted, 2026-10-06. Answers
[#36](https://github.com/shergin/baton/issues/36). Serves
[The compiler decides](../principles/compiler-decides.md) and
[Relay's words](../principles/relays-words.md). Reopen if a conforming
server refuses compact text, which would be the server's defect, or if the
one-line text costs a reader more than it saves on the wire; the remedy is
then a formatted companion where people read, never a change to what is
sent.

## Context

The compiler prints each operation's text with Relay's printer and its
default options: one field a line, two spaces an indentation level, a
blank line before each fragment. The runtime sends that text as it is, in
every request of an operation that has no persisted id. The issue measured
the text at about 2.4 times what the same operation needs, and a server
refused a 65 KB operation with HTTP 400 that it accepted at 33 KB with the
insignificant whitespace removed. Whitespace and commas are insignificant
in GraphQL, so the server's answer cannot change with them. Relay's printer
has the other form already, `PrinterOptions::compact`, and Relay's compiler
applies it to every artifact under the feature flag `compact_query_text`,
off by default. `persistConfig` takes the text off the wire altogether, but
only for a server with a registry; the issue's server has a limit and no
registry.

## Decision

- Every operation's text is printed compact, with Relay's printer's own
  option: no newline, indentation or optional space, a comma between
  items, strings and block strings as they are. The fragments the operation
  reaches follow it in the same text, as before. There is no option, and
  nothing at run time touches the text.
- The one text is what the artifact holds, what a request sends, what a
  persisted id is hashed from, what the persisted file maps the id to, what
  `batonc print` prints and what `spec/documents` keeps. Nothing else
  prints a second form of it.
- The artifact's literal is one line, unless the text has a newline:
  Relay's compact printer keeps one between selections that share repeated
  `@include` or `@skip` conditions, and the literal then spans lines as it
  always did.
- A fragment's source definition in the report stays as the author wrote
  it, formatted. It is a compile input for a dependent target, whose
  compiler points its diagnostics into it, not a wire payload.

## Evidence

- The goldens at this commit against the commit before, a deterministic
  count: the test target's 115 operations hold 61,797 bytes of text where
  they held 83,885, 74%; the realistic documents, without the corpus of
  hostile names, 18,916 where they held 26,855, 70%; the `Fixture` query,
  the deepest of them, 283 where it held 607, 47%. The gain grows with
  depth, since indentation does, which is where a server's limit is met.
- The issue's measurements on four documents of nested unions: compact text
  at 40% to 43% of the printed, and the 65 KB operation accepted at 33 KB.
- Relay's printer at the pinned revision, read 2026-10-06: `compact` skips
  the newline where it may, drops optional spaces, writes `,` as the item
  separator, and prints a string constant as it is.
- Nothing is measured at run time, and nothing needs to be: no read or
  commit changes, and the runtime does not read the text.

## Not chosen

- Relay's flag, `featureFlags.compact_query_text`, off by default: a knob
  with no case for its off position here. Relay keeps the formatted text
  as its default so that persisted ids registered under it keep working, a
  debt Baton does not owe before 1.0, and the block would be the first
  feature flag in `baton.json`.
- Removing the whitespace in the transport, the issue's workaround: the
  runtime never parses GraphQL, and the id would no longer be the hash of
  the text sent.
- Compact on the wire and formatted in the artifact: two texts, and the id
  hashes one of them.
- A pass of our own after Relay's printer, for the newline it keeps in a
  group of conditions: a tokenizer for a few bytes, and a string argument
  holding a newline would be at risk.
