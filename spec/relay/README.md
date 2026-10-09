# Relay's store tests

Cases harvested from Relay v21.0.1's own runtime tests, so that Baton's store
is held to what Relay's store does with the same payloads. Each Relay test
gives a document, its variables and a payload, and states the records the
store must hold afterwards; the harvest records those calls as Relay's test
makes them and translates the records into Baton's keys. The tests,
`testschema.graphql` and the client extensions are Relay's, MIT licensed,
copyright Meta Platforms, Inc. and affiliates.

The harvest covers `RelayResponseNormalizer-test.js`, `DataChecker-test.js`,
`RelayReader-test.js`, `RelayReader-RequiredFields-test.js`,
`RelayReader-CatchFields-test.js` and `RelayReader-RelayErrorHandling-test.js`.
Relay's tests are
measured against, not obeyed
([docs/decisions/relays-tests-are-measured-not-obeyed.md](../../docs/decisions/relays-tests-are-measured-not-obeyed.md)):
each case carries a status, and a case whose status is not `passes` says
why and, once the owner has decided, what is to be done. The dumps are
Relay's statement, not Baton's: `BATON_BLESS=1` writes `documents/` but
never a dump, and a case where Baton parts from Relay changes its status,
never its dump. The statuses are written in
`scripts/relay-harvest/expectations.json`, the translator's input.

## Layout

- `manifest.json`: the cases, in the main manifest's format, each with an
  `origin` naming the Relay test it came from and, when Baton is not held to
  Relay's result, a `status`, a `note` and a `decision`; `scripts` lists a
  test that normalizes several payloads in a row, as `payload` steps.
- `normalizer/`: the payloads as responses and the records after them.
- `checker/`: the responses the availability checks' seeded stores stand
  for; each is a script of a `payload` step and a `check` step with Relay's
  answer, `available` as `memory` and `missing` as `miss`.
- `reader/`, `required/`, `catch/`, `errors/`: the responses the reader
  tests' seeded stores stand for; each is a script of one `payload` step
  whose `reads` say what Relay's reader read, in Baton's terms (below).
- `sources/`: each operation as the test's author wrote it, with its
  fragments; `documents/`: the text the compiler generated from it;
  `unsupported/`: the documents batonc rejects, kept for when it does not.
- `schema/`: Relay's `testschema.graphql` and the client extensions batonc
  accepts; `baton.json` keys every `Node` by `id`.
- `harvest.json`: every test with what became of it.

The Swift test target `BatonRelayTests` compiles `sources/` (generated into
`RelayDocuments.swift`, the reads into `RelayReads.swift`) against the
schema and runs every case but the
unsupported ones, each with a status as a known issue: it commits
the responses as payloads and compares the store with the dump.

## Seeded stores

Relay's checker, reader and marker tests seed a store by hand; Baton's
cases start from a response. The recorder walks the query's selection over
the seeded records and writes the response they stand for, a field the
store lacks left out and a field error written as a response error; Relay
normalizes that response into an empty store and answers again, and a test
is kept only when the two answers agree. The case then compares Baton and
Relay on one response a server could send. A check of a fragment at a
record has no counterpart: a Baton fragment has no plan of its own.

## Reads

Relay's `read` gives masked data and the field errors a component would
act on; a Baton lens reads the same facts through accessors. A row is a
response path with what the lens reads there:

- a value, as Relay read it; a link Relay read as null is `null`;
- a `@catch` field's result, `{"ok": true, "value": …}` (no value for a
  lens) or `{"ok": false, "errors": [path, …]}`, each error by its dotted
  path, a `@required` error's taken from Relay's message;
- `"throws": "requiredField"` where Relay's component would throw for a
  `@required(action: THROW)` field: Baton's accessor throws there, and the
  nulls Relay wrote on the way up are not rows;
- at the empty path, the operation's own outcome: `requiredField` when
  Relay read no data because a `@required` field bubbled to the root, as a
  Baton handle fails; `fieldErrors` where Relay would throw under
  `@throwOnFieldError`; `missingData` where Relay would throw for data
  missing under it, which Baton has no counterpart of.

A list's indices count the records Baton's list keeps: Relay keeps a null
element in place, Baton drops it. A type condition's fields are read
through its accessor (`asUser`), chosen by the response's `__typename`, and
a masked spread is no row. `RelayReads.swift` in the Swift test target is
generated from the rows and from the compiler's report, which gives every
accessor's name, the response key it reads and its shape, so each row is
read as the lens reads it, with `?.`, `try` or a result's `get()`.

## Running the harvest again

In a checkout of Relay v21.0.1 outside this repository, install and build
its JavaScript (`yarn install --ignore-scripts`, then
`node_modules/.bin/gulp dist`), record the calls, and translate them:

```sh
for suite in RelayResponseNormalizer DataChecker RelayReader \
    RelayReader-RequiredFields RelayReader-CatchFields RelayReader-RelayErrorHandling; do
  HARVEST_OUT=/tmp/harvest NODE_ENV=test OSS=true node_modules/.bin/jest \
    packages/relay-runtime/store/__tests__/$suite-test.js \
    --setupFilesAfterEnv <baton>/scripts/relay-harvest/record.js
done
python3 scripts/relay-harvest/translate.py --relay <relay> \
  --harvest /tmp/harvest --batonc compiler/target/release/batonc
BATON_COMPILER=local BATON_BLESS=1 swift test --filter BatonRelayTests
```

## What the harvest kept

The translator writes this table.

<!-- harvest -->
227 tests harvested.

| Status | Meaning | `RelayResponseNormalizer` | `DataChecker` | `RelayReader` | `RelayReader-RequiredFields` | `RelayReader-CatchFields` | `RelayReader-RelayErrorHandling` |
|---|---|---|---|---|---|---|---|
| `passes` | Baton agrees with Relay; the case must pass. | 13 | 2 | 1 | 18 | 9 | 4 |
| `possible-bug` | Baton is probably wrong; the case runs and its result is ignored. | 2 | 0 | 0 | 1 | 2 | 0 |
| `unspecified-behaviour` | GraphQL does not say, and Relay chose; the case runs and its result is ignored. | 7 | 0 | 0 | 0 | 3 | 2 |
| `invalid-input` | the payload is one a conforming server does not send; the case runs and its result is ignored. | 1 | 0 | 0 | 0 | 0 | 0 |
| `by-design` | Baton parts from Relay on purpose, by a decision; the case runs and its result is ignored. | 0 | 1 | 0 | 0 | 0 | 0 |
| `unsupported-feature` | Relay has something Baton does not; the case is ingested and left out of the runs. | 31 | 13 | 0 | 1 | 2 | 4 |
| `not-ingested` | the harvest cannot express the test yet; nothing is written. | 6 | 47 | 34 | 10 | 3 | 10 |

### `RelayResponseNormalizer-test.js`

| Test | Status | Note |
|---|---|---|
| normalizes queries | `passes` |  |
| normalizes queries with "handle" fields | `unsupported-feature` | batonc: `@__clientField` on a field has no meaning in Baton |
| normalizes queries with "filters" | `unsupported-feature` | batonc: `@__clientField` on a field has no meaning in Baton |
| @match normalizes queries correctly | `unsupported-feature` | batonc: `@match` on a field has no meaning in Baton |
| @match returns metadata with prefixed path | `unsupported-feature` | batonc: `@match` on a field has no meaning in Baton |
| @match normalizes queries correctly when the resolved type does not match any of the specified cases | `unsupported-feature` | batonc: `@match` on a field has no meaning in Baton |
| @match normalizes queries correctly when the @match field is null | `unsupported-feature` | batonc: `@match` on a field has no meaning in Baton |
| @module normalizes queries and returns metadata when the type matches an @module selection | `unsupported-feature` | batonc: `@module` on a fragment spread has no meaning in Baton |
| @module returns metadata with prefixed path | `unsupported-feature` | batonc: `@module` on a fragment spread has no meaning in Baton |
| @module normalizes queries correctly when the resolved type does not match any @module selections | `unsupported-feature` | batonc: `@module` on a fragment spread has no meaning in Baton |
| @defer normalizes when if condition is false | `passes` |  |
| @defer returns metadata when `if` is true (literal value) | `unspecified-behaviour` | The initial payload already holds the deferred fragment's fields. Relay skips them on purpose (`_normalizeDefer`: data for a deferred selection 'should not be present') and waits for a later part; Baton writes what the response holds. The fields in the test's payload are incidental to what it asserts, the placeholder. Decision: Open. Relay's skip is deliberate, but a server that answers a deferred fragment inline sends no later part, and Relay then never writes the fields; the recommendation is to keep Baton's. |
| @defer returns metadata when `if` is true (variable value) | `unspecified-behaviour` | The initial payload already holds the deferred fragment's fields. Relay skips them on purpose (`_normalizeDefer`: data for a deferred selection 'should not be present') and waits for a later part; Baton writes what the response holds. The fields in the test's payload are incidental to what it asserts, the placeholder. Decision: Open. Relay's skip is deliberate, but a server that answers a deferred fragment inline sends no later part, and Relay then never writes the fields; the recommendation is to keep Baton's. |
| @defer returns metadata for @defer within a plural | `unspecified-behaviour` | The initial payload already holds the deferred fragment's fields. Relay skips them on purpose (`_normalizeDefer`: data for a deferred selection 'should not be present') and waits for a later part; Baton writes what the response holds. The fields in the test's payload are incidental to what it asserts, the placeholder. Decision: Open. Relay's skip is deliberate, but a server that answers a deferred fragment inline sends no later part, and Relay then never writes the fields; the recommendation is to keep Baton's. |
| @defer returns metadata with prefixed path | `passes` |  |
| @stream normalizes when if condition is false | `unsupported-feature` | batonc: `@stream` on a field has no meaning in Baton |
| @stream normalizes and returns metadata when `if` is true (literal value) | `unsupported-feature` | batonc: `@stream` on a field has no meaning in Baton |
| @stream normalizes and returns metadata when `if` is true (variable value) | `unsupported-feature` | batonc: `@stream` on a field has no meaning in Baton |
| @stream normalizes and returns metadata for @stream within a plural | `unsupported-feature` | batonc: `@stream` on a field has no meaning in Baton |
| @stream returns metadata with prefixed path | `unsupported-feature` | batonc: `@stream` on a field has no meaning in Baton |
| Client Extensions skips client fields not present in the payload but present in the store | `not-ingested` | a store seeded by hand before the first payload |
| Client Extensions skips client fields not present in the payload or store | `not-ingested` | a store seeded by hand before the first payload |
| Client Extensions ignores linked client fields not present in the payload | `not-ingested` | a store seeded by hand before the first payload |
| Client Extensions ignores linked client fields not present in the payload or store | `not-ingested` | a store seeded by hand before the first payload |
| User-defined getDataID single field overwrite fields in same position but with different data | `unsupported-feature` | a custom `getDataID`: Baton keys by configured fields, not by a function |
| User-defined getDataID single field overwrite fields in same position but with different data in second normalization | `unsupported-feature` | a custom `getDataID`: Baton keys by configured fields, not by a function |
| User-defined getDataID single field stores user-defined id when function returns an string | `unsupported-feature` | a custom `getDataID`: Baton keys by configured fields, not by a function |
| User-defined getDataID single field falls through to previously generated ID if function returns null  | `unsupported-feature` | a custom `getDataID`: Baton keys by configured fields, not by a function |
| User-defined getDataID single field falls through to generateClientID when the function returns null, and no previously generated ID | `unsupported-feature` | a custom `getDataID`: Baton keys by configured fields, not by a function |
| User-defined getDataID plural fields stores user-defined ids when function returns an string | `unsupported-feature` | a custom `getDataID`: Baton keys by configured fields, not by a function |
| User-defined getDataID plural fields uses cached IDs if they were generated before and the function returns null | `unsupported-feature` | a custom `getDataID`: Baton keys by configured fields, not by a function |
| User-defined getDataID plural fields falls through to generateClientID when the function returns null and there is one new field in stored plural links | `unsupported-feature` | a custom `getDataID`: Baton keys by configured fields, not by a function |
| User-defined getDataID plural fields falls through to generateClientID when the function returns null and no previously generated IDs | `unsupported-feature` | a custom `getDataID`: Baton keys by configured fields, not by a function |
| User-defined getDataID plural fields overwrite fields in same position but with different data in second normalization | `unsupported-feature` | a custom `getDataID`: Baton keys by configured fields, not by a function |
| normalize queries with provided variables | `unsupported-feature` | batonc: Expected a non-variable identifier (e.g. 'x' or 'Foo') |
| warns in __DEV__ if payload data is missing an expected field | `passes` |  |
| does not warn in __DEV__ if payload data is missing for an abstract field | `passes` |  |
| warns in __DEV__ if a single response contains conflicting fields with the same id | `passes` |  |
| does not warn if a single response contains the same fields with the same id | `passes` |  |
| does not warn if a single response contains the same scalar array value | `passes` |  |
| warns in __DEV__ if a single response contains conflicting fields with multiple same ids | `passes` |  |
| warns in __DEV__ if a single response contains conflicting linked fields | `passes` |  |
| warns in __DEV__ if a single response contains conflicting linked fields with null values | `passes` |  |
| warns in __DEV__ if payload contains inconsistent types for a record | `not-ingested` | one id of several types (`1`): Relay merges them into one record, Baton keys by type (docs/decisions/identity-is-configured.md) |
| does not warn in __DEV__ on inconsistent types for a client record | `not-ingested` | one id of several types (`client:1`): Relay merges them into one record, Baton keys by type (docs/decisions/identity-is-configured.md) |
| leaves undefined fields unset | `passes` |  |
| when treatMissingFieldsAsNull is true set undefined fields to null | `unsupported-feature` | `treatMissingFieldsAsNull`: Baton has no option that writes a missing field as null |
| when treatMissingFieldsAsNull is true skips client fields not present in the payload but present in the store | `unsupported-feature` | `treatMissingFieldsAsNull`: Baton has no option that writes a missing field as null |
| when treatMissingFieldsAsNull is true does not warn if a single response contains the same fields with the same id | `unsupported-feature` | `treatMissingFieldsAsNull`: Baton has no option that writes a missing field as null |
| "falsy" IDs in payload should create client IDs for "falsy" values in payload | `unspecified-behaviour` | Relay keys an object whose id is the empty string by its path; Baton keys it `User:`, one record for every such object of the type. Decision: Document it and copy Relay, unless that costs performance (owner, 2026-10-09). |
| "falsy" IDs in payload should create client IDs for "falsy" values in payload - same id | `unspecified-behaviour` | Relay keys an object whose id is the empty string by its path; Baton keys it `User:`, one record for every such object of the type. Decision: Document it and copy Relay, unless that costs performance (owner, 2026-10-09). |
| "falsy" IDs in payload should create client IDs for "falsy" values in payload for list | `unspecified-behaviour` | An `ID` the server sends as a number or a boolean: Relay keys the object by its path; Baton's ingest rejects the response. Decision: Document it and copy Relay, unless that costs performance (owner, 2026-10-09). |
| records which concrete types implement which client schema extension interfaces | `unsupported-feature` | batonc: Unknown type 'ClientInterface'. Did you mean `ClientObject`? |
| when field error handling is enabled normalizes queries with multiple field errors | `possible-bug` | Relay keeps every error of a field as a list of messages; Baton keeps one error a field, the last, with its absolute path, and loses the others. Decision: Match Relay, unless that costs performance (owner, 2026-10-09). |
| when field error handling is enabled normalizes queries with field errors that bubbled up | `possible-bug` | Relay keeps every error that bubbled to the nulled field, with paths relative to it; Baton keeps one, the last, with its absolute path, and loses the others. Decision: Match Relay, unless that costs performance (owner, 2026-10-09). |
| when field error handling is enabled when noncompliant error handling on lists is disabled ignores field errors on an empty list | `unspecified-behaviour` | An error whose path ends at a list that is not null: Relay drops it; Baton places it on the list's field, the last field its path reaches. Decision: Match Relay, unless that costs performance (owner, 2026-10-09). |
| when field error handling is enabled when noncompliant error handling on lists is enabled stores field errors on an linked field that is an empty list | `unsupported-feature` | a Relay feature flag: `ENABLE_NONCOMPLIANT_ERROR_HANDLING_ON_LISTS` |
| when field error handling is enabled when noncompliant error handling on lists is enabled stores field errors on an scalar field that is an empty list | `unsupported-feature` | a Relay feature flag: `ENABLE_NONCOMPLIANT_ERROR_HANDLING_ON_LISTS` |
| Prototype-less objects (e.g., from graphql-js executor) normalizes prototype-less payloads with type discriminator | `passes` |  |
| Prototype-less objects (e.g., from graphql-js executor) normalizes prototype-less payloads for union types | `invalid-input` | The server text asks for `... on Node { __isNode: __typename, id }`, and the test's payload leaves `__isNode` out, which a conforming server does not do; the test is about prototype-less objects and the omission is incidental. Relay knows no schema at run time and applies an abstract fragment only when the payload answers `__isX`, so it stores no `id`; Baton knows from the schema that `Page` is a `Node` and stores it (spec/runtime.md, memberships). Decision: Open. The recommendation is no change: both behave the same on a response that answers the text. |

### `DataChecker-test.js`

| Test | Status | Note |
|---|---|---|
| reads query data | `passes` |  |
| reads fragment data | `not-ingested` | a check of a fragment at `1`; Baton checks an operation from its root |
| reads handle fields in fragment | `not-ingested` | a check of a fragment at `1`; Baton checks an operation from its root |
| reads handle fields in fragment and checks missing | `not-ingested` | a check of a fragment at `1`; Baton checks an operation from its root |
| reads handle fields in fragment and checks missing sub field | `not-ingested` | a check of a fragment at `1`; Baton checks an operation from its root |
| reads handle fields in operation | `not-ingested` | the response the seeded store stands for gives Relay another answer (missing, not available) |
| reads handle fields in operation and checks missing | `unsupported-feature` | batonc: `@__clientField` on a field has no meaning in Baton |
| reads handle fields in operation and checks missing sub field | `unsupported-feature` | batonc: `@__clientField` on a field has no meaning in Baton |
| reads scalar handle fields in operation and checks presence | `not-ingested` | the response the seeded store stands for gives Relay another answer (missing, not available) |
| reads scalar handle fields in operation and checks missing | `unsupported-feature` | batonc: `@__clientField` on a field has no meaning in Baton |
| when @match directive is present returns true when the match field/record exist and match a supported type (plaintext) | `not-ingested` | the store holds what a `ModuleImport` selection writes, which no response does |
| when @match directive is present returns true when the match field/record exist and match a supported type (markdown) | `not-ingested` | the store holds what a `ModuleImport` selection writes, which no response does |
| when @match directive is present returns false when the match field/record exist but the matched fragment has not been processed | `not-ingested` | the store holds what a `ModuleImport` selection writes, which no response does |
| when @match directive is present returns false when the match field/record exist but a scalar field is missing | `not-ingested` | the store holds what a `ModuleImport` selection writes, which no response does |
| when @match directive is present returns false when the match field/record exist but a linked field is missing | `not-ingested` | the store holds what a `ModuleImport` selection writes, which no response does |
| when @match directive is present returns true when the match field/record exist but do not match a supported type | `unsupported-feature` | batonc: `@match` on a field has no meaning in Baton |
| when @match directive is present returns true when the match field is non-existent (null) | `unsupported-feature` | batonc: `@match` on a field has no meaning in Baton |
| when @match directive is present returns false when the match field is not fetched (undefined) | `unsupported-feature` | batonc: `@match` on a field has no meaning in Baton |
| when @module directive is present returns true when the field/record exists and matches the @module type (plaintext) | `not-ingested` | the store holds what a `ModuleImport` selection writes, which no response does |
| when @module directive is present returns true when the field/record exist and matches the @module type (markdown) | `not-ingested` | the store holds what a `ModuleImport` selection writes, which no response does |
| when @module directive is present returns false when the field/record exist but the @module fragment has not been processed | `not-ingested` | the store holds what a `ModuleImport` selection writes, which no response does |
| when @module directive is present returns false when the field/record exists but a scalar field is missing | `not-ingested` | the store holds what a `ModuleImport` selection writes, which no response does |
| when @module directive is present returns false when the field/record exists but a linked field is missing | `not-ingested` | the store holds what a `ModuleImport` selection writes, which no response does |
| when @module directive is present returns true when the field/record exists but does not match any @module selection | `unsupported-feature` | batonc: `@module` on a fragment spread has no meaning in Baton |
| when @defer directive is present returns true when deferred selections are fetched | `not-ingested` | the response the seeded store stands for gives Relay another answer (missing, not available) |
| when @defer directive is present returns false when deferred selections are not fetched | `by-design` | The deferred fragment's fields are not in the store. Relay's check answers missing; Baton's answers from the selection outside the deferred parts, which checks them apart, and the operation fetches either way (spec/runtime.md, 'The deferred parts are checked apart'). Decision: Open. The recommendation is no change, since the answer only decides whether the rest renders while the deferred part is fetched. |
| when @stream directive is present returns true when streamed selections are fetched | `unsupported-feature` | batonc: `@stream` on a field has no meaning in Baton |
| when @stream directive is present returns false when streamed selections are not fetched | `unsupported-feature` | batonc: `@stream` on a field has no meaning in Baton |
| when the data is complete returns available | `passes` |  |
| when some data is missing returns missing on missing records | `not-ingested` | a check of a fragment at `1`; Baton checks an operation from its root |
| when some data is missing returns missing on missing fields | `not-ingested` | a check of a fragment at `1`; Baton checks an operation from its root |
| when some data is missing allows handlers to supplement missing scalar fields | `not-ingested` | a check of a fragment at `1`; Baton checks an operation from its root |
| when some data is missing linked field handler handler that returns undefined | `not-ingested` | a check of a fragment at `user1`; Baton checks an operation from its root |
| when some data is missing linked field handler handler that returns null | `not-ingested` | a check of a fragment at `user1`; Baton checks an operation from its root |
| when some data is missing linked field handler handler that returns 'hometown-exists' | `not-ingested` | a check of a fragment at `user1`; Baton checks an operation from its root |
| when some data is missing linked field handler handler that returns 'hometown-deleted' | `not-ingested` | a check of a fragment at `user1`; Baton checks an operation from its root |
| when some data is missing linked field handler handler that returns 'hometown-unknown' | `not-ingested` | a check of a fragment at `user1`; Baton checks an operation from its root |
| when some data is missing plural linked field handler handler that returns undefined | `not-ingested` | a check of a fragment at `user1`; Baton checks an operation from its root |
| when some data is missing plural linked field handler handler that returns null | `not-ingested` | a check of a fragment at `user1`; Baton checks an operation from its root |
| when some data is missing plural linked field handler handler that returns [] | `not-ingested` | a check of a fragment at `user1`; Baton checks an operation from its root |
| when some data is missing plural linked field handler handler that returns [undefined] | `not-ingested` | a check of a fragment at `user1`; Baton checks an operation from its root |
| when some data is missing plural linked field handler handler that returns [null] | `not-ingested` | a check of a fragment at `user1`; Baton checks an operation from its root |
| when some data is missing plural linked field handler handler that returns ['screenname-exists'] | `not-ingested` | a check of a fragment at `user1`; Baton checks an operation from its root |
| when some data is missing plural linked field handler handler that returns ['screenname-deleted'] | `not-ingested` | a check of a fragment at `user1`; Baton checks an operation from its root |
| when some data is missing plural linked field handler handler that returns ['screenname-unknown'] | `not-ingested` | a check of a fragment at `user1`; Baton checks an operation from its root |
| when some data is missing plural linked field handler handler that returns ['screenname-exists', 'screenname-unknown'] | `not-ingested` | a check of a fragment at `user1`; Baton checks an operation from its root |
| when some data is missing returns modified records with the target | `not-ingested` | a check of a fragment at `1`; Baton checks an operation from its root |
| when some data is missing returns available even when client field is missing | `not-ingested` | a check of a fragment at `1`; Baton checks an operation from its root |
| when individual records have been invalidated when data is complete returns correct invalidation epoch in result when record was invalidated | `unsupported-feature` | a record invalidated by hand: Baton invalidates the store, not a record |
| when individual records have been invalidated when data is complete returns correct invalidation epoch in result when multiple records invalidated at different times | `not-ingested` | several checks in one test |
| when individual records have been invalidated when data is missing returns correct invalidation epoch in result when record was invalidated | `unsupported-feature` | a record invalidated by hand: Baton invalidates the store, not a record |
| when individual records have been invalidated when data is missing returns correct invalidation epoch in result when multiple records invalidated at different times | `not-ingested` | several checks in one test |
| when individual records have been invalidated when data is missing returns null invalidation epoch when stale record is unreachable | `unsupported-feature` | a record invalidated by hand: Baton invalidates the store, not a record |
| returns false when a Node record is missing an id | `not-ingested` | a check of a selector that is not a query |
| precise type refinement returns `missing` when a Node record is missing an id | `not-ingested` | a check of a selector that is not a query |
| precise type refinement returns `missing` when an abstract refinement is only missing the discriminator field | `not-ingested` | a check of a selector that is not a query |
| precise type refinement returns `available` when a record is only missing fields in non-implemented interfaces | `not-ingested` | a check of a selector that is not a query |
| should assign client-only abstract type information to the target source | `not-ingested` | the seeded store stands for no response: no root record |
| should assign client-only abstract type information to the target source if it is not available in the source | `unsupported-feature` | batonc: Unknown type 'ClientInterface'. Did you mean `ClientObject`? |
| exec time resolvers client query should return available when all data is available | `not-ingested` | the store holds what a `ClientEdgeToClientObject` selection writes, which no response does |
| exec time resolvers client query should return available when only client data is missing | `not-ingested` | the store holds what a `ClientEdgeToClientObject` selection writes, which no response does |
| exec time resolvers server and client query should return available when server data is available | `not-ingested` | the store holds what a `ClientEdgeToClientObject` selection writes, which no response does |
| exec time resolvers server and client query should return missing when server data is missing | `not-ingested` | the store holds what a `ClientEdgeToClientObject` selection writes, which no response does |

### `RelayReader-test.js`

| Test | Status | Note |
|---|---|---|
| reads query data | `passes` |  |
| reads fragment data | `not-ingested` | a read of a fragment at `1`; a Baton case reads from a response's root |
| creates fragment pointers with fragment owner when owner is provided | `not-ingested` | a read of a fragment at `1`; a Baton case reads from a response's root |
| creates fragment pointers with variable @arguments | `not-ingested` | a read of a fragment at `1`; a Baton case reads from a response's root |
| creates fragment pointers with literal @arguments | `not-ingested` | a read of a fragment at `1`; a Baton case reads from a response's root |
| @inline reads a basic fragment | `not-ingested` | a read of a fragment at `1`; a Baton case reads from a response's root |
| reads data when the root is deleted | `not-ingested` | a read of a fragment at `4`; a Baton case reads from a response's root |
| reads data when the root is unfetched | `not-ingested` | a read of a fragment at `4`; a Baton case reads from a response's root |
| reads "handle" fields for query root fragments | `not-ingested` | the response the seeded store stands for gives Relay another answer |
| reads "handle" fields for fragments | `not-ingested` | a read of a fragment at `1`; a Baton case reads from a response's root |
| when @match directive is present creates fragment and module pointers for fragment that matches resolved type (1) | `not-ingested` | a read of a fragment at `1`; a Baton case reads from a response's root |
| when @match directive is present creates fragment and module pointers for fragment that matches resolved type (2) | `not-ingested` | a read of a fragment at `1`; a Baton case reads from a response's root |
| when @match directive is present reads data correctly when the resolved type does not match any of the specified cases | `not-ingested` | a read of a fragment at `1`; a Baton case reads from a response's root |
| when @match directive is present reads data correctly when the match field record is null | `not-ingested` | a read of a fragment at `1`; a Baton case reads from a response's root |
| when @match directive is present reads data correctly when the match field record is missing | `not-ingested` | a read of a fragment at `1`; a Baton case reads from a response's root |
| @module creates fragment and module pointers when the type matches a @module selection (1) | `not-ingested` | a read of a fragment at `1`; a Baton case reads from a response's root |
| @module creates fragment and module pointers when the type matches a @module selection (2) | `not-ingested` | a read of a fragment at `1`; a Baton case reads from a response's root |
| @module reads data correctly when the resolved type does not match any of the @module selections | `not-ingested` | a read of a fragment at `1`; a Baton case reads from a response's root |
| `isMissingData` field readScalar should have `isMissingData = false` if data is available | `not-ingested` | a read of a fragment at `1`; a Baton case reads from a response's root |
| `isMissingData` field readScalar should have `isMissingData = true` if data is missing | `not-ingested` | a read of a fragment at `1`; a Baton case reads from a response's root |
| `isMissingData` field readLink should have `isMissingData = false` if data is available | `not-ingested` | a read of a fragment at `1`; a Baton case reads from a response's root |
| `isMissingData` field readLink should have `isMissingData = true` if data is missing | `not-ingested` | a read of a fragment at `1`; a Baton case reads from a response's root |
| `isMissingData` field readLink should have `isMissingData = true` if data is missing (variables) | `not-ingested` | a read of a fragment at `1`; a Baton case reads from a response's root |
| `isMissingData` field readPluralLink should have `isMissingData = false` if data is available | `not-ingested` | a read of a fragment at `1`; a Baton case reads from a response's root |
| `isMissingData` field readPluralLink should have `isMissingData = true` if data is missing in the node | `not-ingested` | a read of a fragment at `1`; a Baton case reads from a response's root |
| `isMissingData` field readPluralLink should have `isMissingData = true` if data is missing for connection | `not-ingested` | a read of a fragment at `2`; a Baton case reads from a response's root |
| `isMissingData` field readPluralLink should have `isMissingData = true` if data is missing for edge in the connection | `not-ingested` | a read of a fragment at `3`; a Baton case reads from a response's root |
| `isMissingData` field readPluralLink should not have missing data if missing fields are client fields | `not-ingested` | a read of a fragment at `1`; a Baton case reads from a response's root |
| `isMissingData` field readPluralLink should not consider data missing if the fragment type does not match the data | `not-ingested` | a read of a fragment at `1`; a Baton case reads from a response's root |
| `isMissingData` field readPluralLink should consider data missing if the fragment type is abstract | `not-ingested` | a read of a fragment at `1`; a Baton case reads from a response's root |
| `isMissingData` field readPluralLink should consider data missing if the fragment is concrete but on the root | `not-ingested` | a read of a selector that is not a query |
| `isMissingData` field @stream_connection should not have missing data if all data is fetched | `not-ingested` | a read of a fragment at `1`; a Baton case reads from a response's root |
| `isMissingData` field @stream_connection should not have missing data when all edge data is fetched by pageInfo is missing | `not-ingested` | a read of a fragment at `1`; a Baton case reads from a response's root |
| `isMissingData` field @stream_connection should have missing data if an edge is missing data | `not-ingested` | a read of a fragment at `1`; a Baton case reads from a response's root |
| does not record a dependency on type records for abstract type discriminators | `not-ingested` | a read of a fragment at `1`; a Baton case reads from a response's root |

### `RelayReader-RequiredFields-test.js`

| Test | Status | Note |
|---|---|---|
| @required bubbles @required(action: LOG) scalars up to LinkedField | `passes` |  |
| @required bubbles @required(action: LOG) up to aliased inline fragment without type condition | `passes` |  |
| @required bubbles @required(action: LOG) up to aliased inline fragment _with_ type condition | `passes` |  |
| @required if two @required(action: THROW) errors cascade, report the more deeply nested one | `passes` |  |
| @required bubbles @required(action: LOG) scalars up to LinkedField even if subsequent fields are not unexpectedly null | `passes` |  |
| @required only bubbles @required(action: LOG) scalars up to the parent LinkedField | `passes` |  |
| @required bubbles @required(action: LOG) through @required(action: LOG) LinkedField | `passes` |  |
| @required bubbles @required(action: LOG) scalars up to the query root | `passes` |  |
| @required bubbles @required(action: LOG) up to plural linked field | `passes` |  |
| @required bubbles @required(action: LOG) on plural scalar field up to the parent | `passes` |  |
| @required does _not_ bubbles @required(action: LOG) on plural linked field up to the parent | `passes` |  |
| @required bubbles when encountering a missing plural linked field | `passes` |  |
| @required @required(action: LOG) within an inline fragment on a concrete type bubbles if the type matches | `possible-bug` | A `@required` field inside a type condition does not bubble: the generated `satisfied` of `maybeNodeInterface`'s lens returns true without testing the condition's fields, so the link reads present, and `name` reads as a non-optional `String` while it is null. Relay nulls `maybeNodeInterface`, as Baton's own rule for `@required` says it should. Decision: Open. |
| @required @required(action: LOG) within an inline fragment does not bubble if type does not match | `passes` |  |
| @required @required(action: LOG) bubbles across @skip | `passes` |  |
| @required @required(action: LOG) bubbles across @include | `passes` |  |
| @required @required(action: LOG) does not bubble if @required field is not @included | `passes` |  |
| @required @required(action: LOG) does not bubble if @required field is @skipped | `passes` |  |
| @required @required(action: LOG) bubbles client extension fields | `passes` |  |
| @required bubbles @required(action: LOG) on Scalar up to parent fragment | `not-ingested` | a read of a fragment at `1`; a Baton case reads from a response's root |
| @required bubbles @required(action: LOG) on LinkedField up to parent fragment | `not-ingested` | a read of a fragment at `1`; a Baton case reads from a response's root |
| @required bubbles @required(action: LOG) on LinkedField up to parent fragment on Query | `not-ingested` | a read of a selector that is not a query |
| @required does not allow unexpected nulls to escape fragment boundaries | `not-ingested` | several reads in one test |
| @required bubbles nulls if the value is "missing" (still in the process of being loaded) | `not-ingested` | a read of a fragment at `1`; a Baton case reads from a response's root |
| @required bubbles to list item when used in plural fragment | `unsupported-feature` | batonc: `@relay` on a fragment definition has no meaning in Baton |
| @required client edge with @required when CATCH is enabled caught missing required field error when action:THROW under a @catch | `not-ingested` | the store holds what a `ClientEdgeToClientObject` selection writes, which no response does |
| @required client edge with @required throws when missing required field | `not-ingested` | the store holds what a `ClientEdgeToClientObject` selection writes, which no response does |
| @required client edge with @required does not throw when required field is present | `not-ingested` | the store holds what a `ClientEdgeToClientObject` selection writes, which no response does |
| @required client edge with @required does not throw when required plural field is present | `not-ingested` | the store holds what a `ClientEdgeToClientObject` selection writes, which no response does |
| @required client edge with @required does not throw when @live required field is suspended | `not-ingested` | the store holds what a `RelayResolver` selection writes, which no response does |

### `RelayReader-CatchFields-test.js`

| Test | Status | Note |
|---|---|---|
| @catch if scalar has @catch(to: NULL) - scalar value should be null, and nothing should throw or catch | `passes` |  |
| @catch if scalar has catch to RESULT - scalar value should provide the error | `passes` |  |
| @catch if preceding scalar sibling has error, catch to RESULT should not catch that error | `passes` |  |
| @catch if preceding scalar sibling has a logged missing required field, an THROW required field inside a subsequent @catch should not delete that log | `passes` |  |
| @catch @catch(to: NULL) catching a @required(action: THROW) returns null | `possible-bug` | `@catch(to: NULL)` on a link or an aliased inline fragment: Relay reads the selection as null when a field error or a `@required(action: THROW)` is below it; Baton reads `to: NULL` as the plain optional accessor (docs/decisions/error-directives-in-swift.md), so the selection reads present and the error stays below. Decision: Open. |
| @catch @catch(to: NULL) catching missing data returns null | `unspecified-behaviour` | Data missing from the store: Relay's reader reports it as an error, which `@catch` catches and `@throwOnFieldError` throws; Baton reads missing data as absent and refetches, since the check misses, and no read throws or fails for it. Decision: Open. |
| @catch @catch(to: NULL) on query catching missing data returns null | `unsupported-feature` | batonc: `@catch` on a query has no meaning in Baton |
| @catch @catch(to: RESULT) on query catching missing data returns error | `unsupported-feature` | batonc: `@catch` on a query has no meaning in Baton |
| @catch @catch(to: NULL) on fragment catching missing data returns null | `not-ingested` | a read of a selector that is not a query |
| @catch @catch(to: RESULT) on fragment catching missing data returns error | `not-ingested` | a read of a selector that is not a query |
| @catch @catch(to: NULL) on aliased inline fragment catching missing data returns null | `unspecified-behaviour` | Data missing from the store: Relay's reader reports it as an error, which `@catch` catches and `@throwOnFieldError` throws; Baton reads missing data as absent and refetches, since the check misses, and no read throws or fails for it. Decision: Open. |
| @catch @catch(to: RESULT) on aliased inline fragment catching missing data returns error | `unspecified-behaviour` | Data missing from the store: Relay's reader reports it as an error, which `@catch` catches and `@throwOnFieldError` throws; Baton reads missing data as absent and refetches, since the check misses, and no read throws or fails for it. Decision: Open. |
| @catch @catch(to: RESULT) on aliased inline fragment with field error returns error | `not-ingested` | the read: a caught error the response does not hold |
| @catch @catch(to: NULL) on aliased inline fragment with field error returns null | `possible-bug` | `@catch(to: NULL)` on a link or an aliased inline fragment: Relay reads the selection as null when a field error or a `@required(action: THROW)` is below it; Baton reads `to: NULL` as the plain optional accessor (docs/decisions/error-directives-in-swift.md), so the selection reads present and the error stays below. Decision: Open. |
| @catch @catch(to: RESULT) on aliased inline fragment with no error returns ok result | `passes` |  |
| @catch if scalar has catch to RESULT - but no error, response should reflect | `passes` |  |
| @catch if linked has catch to RESULT - but no error, response should reflect | `passes` |  |
| @catch if linked has catch to RESULT - with error, response should reflect | `passes` |  |
| @catch if scalar has catch to RESULT with nested required | `passes` |  |

### `RelayReader-RelayErrorHandling-test.js`

| Test | Status | Note |
|---|---|---|
| error fields adds the errors to fieldErrors | `passes` |  |
| error fields adds the errors to fieldErrors including missingData - without @catch | `passes` |  |
| error fields adds the errors to fieldErrors including missingData within plural fields - without @catch | `passes` |  |
| error fields adds the errors to fieldErrors including missingData - with @catch | `unspecified-behaviour` | Data missing from the store: Relay's reader reports it as an error, which `@catch` catches and `@throwOnFieldError` throws; Baton reads missing data as absent and refetches, since the check misses, and no read throws or fails for it. Decision: Open. |
| error fields @throwOnFieldError on a resolver rootFragment that reads field error will cause that resolver to be treated as a field error by the reader | `not-ingested` | the store holds what a `RelayResolver` selection writes, which no response does |
| error fields @throwOnFieldError reading a resolver with @throwOnFieldError on its rootFragment that reads field error will cause that resolver to be treated as a field error by the reader | `not-ingested` | the store holds what a `RelayResolver` selection writes, which no response does |
| error fields @throwOnFieldError reading a client edge resolver which points to a record with missing data logs the correct path | `not-ingested` | the store holds what a `RelayResolver` selection writes, which no response does |
| error fields @throwOnFieldError reading a client edge to client object resolver which points to a record with missing data logs the correct path | `not-ingested` | the store holds what a `ClientEdgeToClientObject` selection writes, which no response does |
| error fields @throwOnFieldError reading a client edge to PLURAL client object resolver which points to records with missing data logs the correct paths with index segments | `not-ingested` | the store holds what a `ClientEdgeToClientObject` selection writes, which no response does |
| error fields @catch(to: NULL) on a client edge to server object returns data when available | `not-ingested` | the store holds what a `RelayResolver` selection writes, which no response does |
| error fields @catch(to: NULL) on a client edge to server object returns null when data is missing instead of throwing | `not-ingested` | the store holds what a `RelayResolver` selection writes, which no response does |
| error fields @catch(to: NULL) on a client edge to server object returns null when field has errors instead of throwing | `not-ingested` | the store holds what a `RelayResolver` selection writes, which no response does |
| error fields @catch(to: NULL) on a client edge to client object returns null when data is missing instead of throwing | `not-ingested` | the store holds what a `ClientEdgeToClientObject` selection writes, which no response does |
| error fields does not report missing data within an inline fragment that does not match | `passes` |  |
| error fields does report missing data within an inline fragment that does match | `not-ingested` | the response the seeded store stands for gives Relay another answer |
| error fields Reports missing fields in topological order | `unspecified-behaviour` | Data missing from the store: Relay's reader reports it as an error, which `@catch` catches and `@throwOnFieldError` throws; Baton reads missing data as absent and refetches, since the check misses, and no read throws or fails for it. Decision: Open. |
| error fields when noncompliant error handling on lists is enabled when query has @throwOnFieldError directive has errors that will throw when the linked field is an empty list | `unsupported-feature` | a Relay feature flag: `ENABLE_NONCOMPLIANT_ERROR_HANDLING_ON_LISTS` |
| error fields when noncompliant error handling on lists is enabled when query has @throwOnFieldError directive has errors that will throw when the scalar field is an empty list | `unsupported-feature` | a Relay feature flag: `ENABLE_NONCOMPLIANT_ERROR_HANDLING_ON_LISTS` |
| error fields when noncompliant error handling on lists is enabled when query does not have the @throwOnFieldError directive has errors that wont throw when the linked field is an empty list | `unsupported-feature` | a Relay feature flag: `ENABLE_NONCOMPLIANT_ERROR_HANDLING_ON_LISTS` |
| error fields when noncompliant error handling on lists is enabled when query does not have the @throwOnFieldError directive has errors that wont throw when the scalar field is an empty list | `unsupported-feature` | a Relay feature flag: `ENABLE_NONCOMPLIANT_ERROR_HANDLING_ON_LISTS` |

The client extension files batonc rejects, left out of `schema/extensions/`:

- `AstrologicalSign.graphql`: the client field `AstrologicalSign.id` is non-null: a client field is nullable, since no server promises it
- `Client3D.graphql`: the client field `Persona.id` is non-null: a client field is nullable, since no server promises it
- `ClientInterface.graphql`: the client field `ClientTypeWithNestedClientInterface.client_interface` is non-null: a client field is nullable, since no server promises it
- `IAnimal.graphql`: the client field `Chicken.id` is non-null: a client field is nullable, since no server promises it
- `Todos.graphql`: the client field `Todo.todo_id` is non-null: a client field is nullable, since no server promises it
<!-- /harvest -->
