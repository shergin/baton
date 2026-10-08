# The specification

What a Baton runtime is held to, in files no language owns: the schemas, the
documents, the recorded responses, the records a store must hold after
them, what a generated lens must read, and the rules that produce all of
it, in [`runtime.md`](runtime.md), the contract. The Swift runtime passes
these files; a second runtime passes the same files. The principles are
[The response is the oracle](../docs/principles/response-is-the-oracle.md)
and [Two runtimes, one compiler](../docs/principles/two-runtimes-one-compiler.md).

The fixtures are server responses, not tests: a change to the store, the
tokenizer or the record layout is frozen under them, and none is edited to
fit code. A new case adds files; a reviewed change to identity or layout
rewrites the dumps (`BATON_BLESS=1 swift test` writes `.store.json` files
and the documents; `BATON_BLESS=1 cargo test` in `compiler/` writes
`sources/` from the markers).

## Layout

- `rickandmorty/`: the public API's schema, three documents and their
  responses.
- `tests/`: the responses the test documents read, recorded or shaped by
  hand to say one thing each, with the dump beside each one the oracle reads,
  the schema and its client extensions, and `baton.json`, the configuration
  the authors' documents compile with: identity, lookups, transient types
  and fields, and the custom scalars' types by language.
- `sources/`: the authors' documents, one file for each document the Swift
  test target writes, named for its first operation or fragment, as the
  author wrote it, client directives included. Compiled with
  `tests/baton.json`, they give the lenses every case and script reads.
- `tokenizer/`: responses that exercise the tokenizer, and
  `malformed.json`, the responses that are not well formed, each with the
  outcome it must have.
- `documents/`: the text of every operation the manifest names, with its
  fragments, as the compiler emits it, compact on one line; written from
  the generated code and checked against it, so the two cannot drift. This
  is the text a server receives: the client directives the authors wrote,
  `@catch`, `@required`, `@connection`, `@cacheExpiration`, are not in it.
  The authors' documents a second runtime compiles its lenses from are
  under `sources/`, checked against the Swift test target's markers byte
  for byte by the compiler's tests, which also prove that they plan what
  the markers plan.
- `scripts/`: the scripts, below: steps over time and what each leaves.
- `manifest.json`: the sources, the cases and the scripts, below.
- `runtime.md`: the contract, one paragraph a rule, each ending with the
  fixture that holds it or the word *unheld*.

## The manifest

`manifest.json` lists the cases. Its fields:

| Field | Meaning |
|---|---|
| `format` | The manifest's own version, raised when a field changes meaning: 3. Format 3 adds `sources`. |
| `sources` | The authors' documents: `directory`, the directory of `.graphql` files, and `config`, the `baton.json` they compile with, both under `spec/`. A runtime's harness compiles its lenses by running `batonc` over the directory with the configuration. |
| `cases` | The cases, below. |
| `scripts` | The scripts' files under `spec/`, in the order they run, below. |

Each case has:

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
| `reads` | What a generated lens reads at each path after the responses: `path` is the response keys and list indices from the root joined by dots, `value` the JSON the lens yields, with `null` for a field it reads as absent. A row's `value` is the response's leaf unless a rule of the runtime reads it otherwise, a `@required` null that bubbles or a `@throwOnFieldError` fragment that throws; such a row carries a `note` saying which. A custom scalar the test target's `baton.json` maps to a Swift type is a row of the response's text, compared as the mapped type's value, so `1.50` is the decimal the lens reads as `1.5`; a text the type cannot hold reads as `null`, with its `note`, as does an element of a list whose elements are nullable. An enum is a row of the response's text too, compared as the generated enum's value, so a value the schema does not declare is the generated enum's case for an undeclared value with that text: Swift's `unknown`, Kotlin's `Undeclared`. Rows name only fields the document selects on the object's type; a list of records with null entries has no rows below it, since a lens shows the records. |

A runtime proves a case by committing the responses in order under the
case's root, comparing its store to `records`, reading every `reads` row
through the lens its compiler generated for the document, and, where
`override` is given, applying the overriding response as an optimistic
layer and reading the overridden leaves. A runtime that cannot bind a case
or a read fails the case; it does not skip it.

## Scripts

A case starts from an empty store and commits once. What happens over time,
a second page merging, a layer reverted, a root released and collected, a
clock advanced past an expiration, a phase moving, is a *script*: a file
under `scripts/`, listed in the manifest's `scripts`, holding steps and,
after any step, the facts the runtime must then show. Format 2 of the
manifest adds them; the cases are unchanged.

A script has a `name`, the name of its file; whether it runs with an
`image` (an image on a file of the harness's choosing, so that `relaunch`
can open a second store over it); the store's release `buffer` (ten when
omitted) and default `expiration` in seconds (none when omitted); and
`steps`, each an object with one key naming the step, whose value is an
object of the step's arguments (`{}` for none), and any of the expectation
fields beside it. A response is a path under `spec/`; `variables` is
omitted for none.

| Step | Arguments | What the runtime does |
|---|---|---|
| `commit` | `operation`, `variables`, `response` (or `responses`, the parts of an incremental response) | Commits the response as a server's response to the operation, through the door, under the root of the operation's kind: complete, so an omitted field is malformed. A query is fetched by the environment and a mutation committed by it, the transport answering with the response; a subscription's events come by `event`. |
| `payload` | `operation`, `variables`, `response` | Commits the response as a payload committed by hand: part of the selection may be absent. |
| `optimistic` | `operation`, `variables`, `response`, `as` | Applies the response as an optimistic layer of the mutation, named `as` for later steps. |
| `resolve` | `layer`, `response` | The server's answer to the layer's mutation replaces the layer in one batch. |
| `revert` | `layer` | Reverts the layer, as a failed mutation does. |
| `attach` | `operation`, `variables`, `policy`, `as` | Makes the operation's handle in the script's environment with the fetch policy (`storeOrNetwork`, the default, `storeAndNetwork`, `networkOnly`, `storeOnly`), retains it, and names it `as`. The transport answers the fetch this makes from `response` when the step gives one, and fails it with `failure` (`transport`, `request`, `malformed`) when the step gives that; with neither the fetch stays in flight. |
| `answer` | `handle`, `response` or `failure` | Answers the handle's fetch in flight, or fails it. |
| `refetch` | `handle`, `response` or `failure` | Refetches the handle, answered or failed as `answer` is. |
| `retry` | `handle`, and `response` or `failure` or neither | Retries the handle after a failure, answered or failed as `attach` is. |
| `release` | `handle` | Ends the handle's retention. |
| `collect` | | Runs a collection pass now. |
| `advance` | `seconds` | Advances the store's clock, and the wall clock the image keeps ages by. |
| `invalidate` | | Marks everything stale, as `Environment.invalidate()` does; the refetches it starts stay in flight for `answer`. |
| `revalidate` | | As `Environment.revalidate()`; its refetches stay in flight as well. |
| `check` | `operation`, `variables` | Runs the availability check for the operation. |
| `relaunch` | | Ends the environment and opens a second store over the same image, in the same process; later steps run in it. |
| `event` | `handle`, `response` or `failure` or `complete` (`true`) | A subscription handle's stream delivers an event, fails, or is completed by the server. |
| `active` | `value` | Sets the environment's activity. |
| `end` | | Ends the environment. |

The failures are a transport's own (`transport`), the server's errors and
no data (`request`), and a response with neither data nor errors
(`malformed`). The expectations, each optional, each compared after the
step and after a collection pass it scheduled has run:

| Field | Meaning |
|---|---|
| `records` | The path of the store's dump, as a case's. |
| `reads` | Rows as a case's, each with the `handle` whose data the lens reads, or with the `operation` and `variables` of a lens made by hand over the root of the operation's kind. |
| `notified` | The fields the step's batches notified, as `[{"record": key, "field": storage key}]`, and nothing else was notified, among the fields that held a value before the step. `[]` says the step notified nothing. |
| `phase` | A handle's phase: `{"handle": name, "phase": "loading" or "ready" or {"failed": kind}}`, where `kind` is a failure's kind, `fieldErrors`, `requiredField`, `missingData` or `gone`; with `isRefreshing` and `isStale` beside it when they matter. A list of such objects compares several handles; so for `fetch` and `stream`. |
| `fetch` | A handle's fetch: `{"handle": name, "fetch": "idle" or "inFlight" or {"failed": kind}}`. |
| `stream` | A subscription handle's stream: `{"handle": name, "stream": state}`, the state `idle`, `connecting`, `open`, `waiting`, or `{"ended": kind or null}`; with `events` (the count) and `resumptions` beside it when they matter. |
| `answer` | Beside a `check` step, the check's answer: `memory`, `image` or `miss`. As a word it is this expectation; as an object it is the `answer` step. |
| `records_held` | The record keys the store holds, the roots among them, sorted. |
| `events` | The log's events during the step, its expectations' reads included, as their names in order, with the value-free fields a name carries (`{"fetchFailed": {"operation": name, "kind": kind}}`); a bare name compares the name alone. The image's events are left out, since their timing is the writer's. |
| `sent` | The requests the transport received during the step, in order and no others: `[{"operation": name, "body": text}]`, the body the standard encoding writes for each, compared as text byte for byte. |
| `error` | What the step threw, as a failure's kind or `fieldErrors` or `gone`, when the step is expected to throw (a `refetch` failed; a fetch after the end). A step that throws without it fails the script, except a `revert`, whose failure is the point. A `storeOnly` attach without data throws nothing: its phase reads `{"failed": "missingData"}`. |

A runtime proves a script by running its steps in order in one environment
over one store, through a transport the harness scripts from the steps, and
comparing every expectation as it comes. The clock is the store's: a
runtime whose store cannot be told the time cannot run `advance` and fails
the script. Timing that is not the store's, a subscription's backoff, is
not scripted: a `waiting` stream is compared as waiting, not at an instant.
A runtime that cannot bind a step fails the script; it does not skip it.
The rules a script holds are named in [`runtime.md`](runtime.md) by the
script's name.
