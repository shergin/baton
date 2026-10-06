# The specification

What a Baton runtime is held to, in files no language owns: the schemas, the
documents, the recorded responses, the records a store must hold after
them, and what a generated lens must read. The Swift runtime passes these
files; a second runtime passes the same files. The principle is
[The response is the oracle](../docs/principles/response-is-the-oracle.md).

The fixtures are server responses, not tests: a change to the store, the
tokenizer or the record layout is frozen under them, and none is edited to
fit code. A new case adds files; a reviewed change to identity or layout
rewrites the dumps (`BATON_BLESS=1 swift test` writes `.store.json` files
and the documents).

## Layout

- `rickandmorty/`: the public API's schema, three documents and their
  responses.
- `tests/`: the responses the test documents read, recorded or shaped by
  hand to say one thing each, with the dump beside each one the oracle reads.
- `tokenizer/`: responses that exercise the tokenizer, and
  `malformed.json`, the responses that are not well formed, each with the
  outcome it must have.
- `documents/`: the text of every operation the manifest names, with its
  fragments, as the compiler emits it; written from the generated code and
  checked against it, so the two cannot drift.
- `manifest.json`: the cases, below.

## The manifest

`manifest.json` lists the cases. `format` is the manifest's own version,
raised when a field changes meaning. Each case has:

| Field | Meaning |
|---|---|
| `name` | The case's name: the path of its response under `spec/` without the extension, which also names its dump. |
| `operation` | The operation's name in its document. |
| `kind` | `query`, `mutation` or `subscription`: which root the response is committed under. |
| `document` | The operation's text with its fragments, under `spec/`. |
| `variables` | The variables the operation is run with, as JSON. Omitted means none. |
| `responses` | The responses in the order the server sent them: one file, or the parts of an incremental response. |
| `records` | The store's dump after the responses: every record by key, a map from storage key to value, links as Relay writes them (`{"__ref": key}`, `{"__refs": [key]}`), the type as `__typename`, field errors under `__errors`, a deleted record as `null`; keys sorted, one record a line. |
| `complete` | Whether the responses answer every field the document selects, so the availability check passes on them. Omitted means true. |
| `override` | Optional: the leaves an optimistic response overrides, and the value they read under it; several paths when they are aliases of one storage key. |
| `reads` | What a generated lens reads at each path after the responses: `path` is the response keys and list indices from the root joined by dots, `value` the JSON the lens yields, with `null` for a field it reads as absent. A row's `value` is the response's leaf unless a rule of the runtime reads it otherwise, a `@required` null that bubbles or a `@throwOnFieldError` fragment that throws; such a row carries a `note` saying which. A custom scalar the test target's `baton.json` maps to a Swift type is a row of the response's text, compared as the mapped type's value, so `1.50` is the decimal the lens reads as `1.5`; a text the type cannot hold reads as `null`, with its `note`, as does an element of a list whose elements are nullable. Rows name only fields the document selects on the object's type; a list of records with null entries has no rows below it, since a lens shows the records. |

A runtime proves a case by committing the responses in order under the
case's root, comparing its store to `records`, reading every `reads` row
through the lens its compiler generated for the document, and, where
`override` is given, applying the overriding response as an optimistic
layer and reading the overridden leaves. A runtime that cannot bind a case
or a read fails the case; it does not skip it.
