# Relay's store tests

Cases harvested from Relay v21.0.1's own runtime tests, so that Baton's store
is held to what Relay's store does with the same payloads. Each Relay test
gives a document, its variables and a payload, and states the records the
store must hold afterwards; the harvest records those calls as Relay's test
makes them and translates the records into Baton's keys. The tests,
`testschema.graphql` and the client extensions are Relay's, MIT licensed,
copyright Meta Platforms, Inc. and affiliates.

The harvest covers `RelayResponseNormalizer-test.js`. Relay's tests are
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
- `sources/`: each operation as the test's author wrote it, with its
  fragments; `documents/`: the text the compiler generated from it;
  `unsupported/`: the documents batonc rejects, kept for when it does not.
- `schema/`: Relay's `testschema.graphql` and the client extensions batonc
  accepts; `baton.json` keys every `Node` by `id`.
- `harvest.json`: every test with what became of it.

The Swift test target `BatonRelayTests` compiles `sources/` (generated into
`RelayDocuments.swift`) against the schema and runs every case but the
unsupported ones, each with a status as a known issue: it commits
the responses as payloads and compares the store with the dump.

## Running the harvest again

In a checkout of Relay v21.0.1 outside this repository, install and build
its JavaScript (`yarn install --ignore-scripts`, then
`node_modules/.bin/gulp dist`), record the calls, and translate them:

```sh
HARVEST_OUT=/tmp/harvest NODE_ENV=test OSS=true node_modules/.bin/jest \
  packages/relay-runtime/store/__tests__/RelayResponseNormalizer-test.js \
  --setupFilesAfterEnv <baton>/scripts/relay-harvest/record.js
python3 scripts/relay-harvest/translate.py --relay <relay> \
  --harvest /tmp/harvest --batonc compiler/target/release/batonc
BATON_COMPILER=local BATON_BLESS=1 swift test --filter BatonRelayTests
```

## What the harvest kept

The translator writes this table.

<!-- harvest -->
60 tests harvested.

| Status | Tests | Meaning |
|---|---|---|
| `passes` | 13 | Baton agrees with Relay; the case must pass. |
| `possible-bug` | 2 | Baton is probably wrong; the case runs and its result is ignored. |
| `unspecified-behaviour` | 7 | GraphQL does not say, and Relay chose; the case runs and its result is ignored. |
| `invalid-input` | 1 | the payload is one a conforming server does not send; the case runs and its result is ignored. |
| `by-design` | 0 | Baton parts from Relay on purpose, by a decision; the case runs and its result is ignored. |
| `unsupported-feature` | 31 | Relay has something Baton does not; the case is ingested and left out of the runs. |
| `not-ingested` | 6 | the harvest cannot express the test yet; nothing is written. |

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

The client extension files batonc rejects, left out of `schema/extensions/`:

- `AstrologicalSign.graphql`: the client field `AstrologicalSign.id` is non-null: a client field is nullable, since no server promises it
- `Client3D.graphql`: the client field `Persona.id` is non-null: a client field is nullable, since no server promises it
- `ClientInterface.graphql`: the client field `ClientTypeWithNestedClientInterface.client_interface` is non-null: a client field is nullable, since no server promises it
- `IAnimal.graphql`: the client field `Chicken.id` is non-null: a client field is nullable, since no server promises it
- `Todos.graphql`: the client field `Todo.todo_id` is non-null: a client field is nullable, since no server promises it
<!-- /harvest -->
