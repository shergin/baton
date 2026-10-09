# Relay's store tests

Cases harvested from Relay v21.0.1's own runtime tests, so that Baton's store
is held to what Relay's store does with the same payloads. Each Relay test
gives a document, its variables and a payload, and states the records the
store must hold afterwards; the harvest records those calls as Relay's test
makes them and translates the records into Baton's keys. The tests,
`testschema.graphql` and the client extensions are Relay's, MIT licensed,
copyright Meta Platforms, Inc. and affiliates.

The pilot harvests `RelayResponseNormalizer-test.js`. The dumps are Relay's
statement, not Baton's: `BATON_BLESS=1` writes `documents/` but never a dump,
and a case where Baton parts from Relay is listed in `divergences.json` with
a line saying how, never resolved by editing the dump. Each such case runs as
a known issue, which fails once Baton agrees with Relay, and waits for a
decision recorded under `docs/decisions/`.

## Layout

- `manifest.json`: the cases, in the main manifest's format, each with an
  `origin` naming the Relay test it came from; `scripts` lists a test that
  normalizes several payloads in a row, as `payload` steps.
- `normalizer/`: the payloads as responses and the records after them.
- `sources/`: each operation as the test's author wrote it, with its
  fragments; `documents/`: the text the compiler generated from it.
- `schema/`: Relay's `testschema.graphql` and the client extensions batonc
  accepts; `baton.json` keys every `Node` by `id`.
- `divergences.json`: the cases where Baton parts from Relay.
- `harvest.json`: every test with what became of it.

The Swift test target `BatonRelayTests` compiles `sources/` (generated into
`RelayDocuments.swift`) against the schema and runs every case: it commits
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
60 tests harvested, 23 kept, 37 dropped; of those kept, 13 pass and 10 part from Relay.

| Test | Outcome |
|---|---|
| normalizes queries | kept, passes |
| normalizes queries with "handle" fields | dropped: batonc: `@__clientField` on a field has no meaning in Baton |
| normalizes queries with "filters" | dropped: batonc: `@__clientField` on a field has no meaning in Baton |
| @match normalizes queries correctly | dropped: batonc: `@match` on a field has no meaning in Baton |
| @match returns metadata with prefixed path | dropped: batonc: `@match` on a field has no meaning in Baton |
| @match normalizes queries correctly when the resolved type does not match any of the specified cases | dropped: batonc: `@match` on a field has no meaning in Baton |
| @match normalizes queries correctly when the @match field is null | dropped: batonc: `@match` on a field has no meaning in Baton |
| @module normalizes queries and returns metadata when the type matches an @module selection | dropped: batonc: `@module` on a fragment spread has no meaning in Baton |
| @module returns metadata with prefixed path | dropped: batonc: `@module` on a fragment spread has no meaning in Baton |
| @module normalizes queries correctly when the resolved type does not match any @module selections | dropped: batonc: `@module` on a fragment spread has no meaning in Baton |
| @defer normalizes when if condition is false | kept, passes |
| @defer returns metadata when `if` is true (literal value) | parts from Relay: Relay skips a deferred fragment's fields when the initial payload already holds them and waits for the later part; Baton writes what the response holds. |
| @defer returns metadata when `if` is true (variable value) | parts from Relay: Relay skips a deferred fragment's fields when the initial payload already holds them and waits for the later part; Baton writes what the response holds. |
| @defer returns metadata for @defer within a plural | parts from Relay: Relay skips a deferred fragment's fields when the initial payload already holds them and waits for the later part; Baton writes what the response holds. |
| @defer returns metadata with prefixed path | kept, passes |
| @stream normalizes when if condition is false | dropped: batonc: `@stream` on a field has no meaning in Baton |
| @stream normalizes and returns metadata when `if` is true (literal value) | dropped: batonc: `@stream` on a field has no meaning in Baton |
| @stream normalizes and returns metadata when `if` is true (variable value) | dropped: batonc: `@stream` on a field has no meaning in Baton |
| @stream normalizes and returns metadata for @stream within a plural | dropped: batonc: `@stream` on a field has no meaning in Baton |
| @stream returns metadata with prefixed path | dropped: batonc: `@stream` on a field has no meaning in Baton |
| Client Extensions skips client fields not present in the payload but present in the store | dropped: a store seeded by hand before the first payload |
| Client Extensions skips client fields not present in the payload or store | dropped: a store seeded by hand before the first payload |
| Client Extensions ignores linked client fields not present in the payload | dropped: a store seeded by hand before the first payload |
| Client Extensions ignores linked client fields not present in the payload or store | dropped: a store seeded by hand before the first payload |
| User-defined getDataID single field overwrite fields in same position but with different data | dropped: a custom `getDataID`: Baton keys by configured fields, not by a function |
| User-defined getDataID single field overwrite fields in same position but with different data in second normalization | dropped: a custom `getDataID`: Baton keys by configured fields, not by a function |
| User-defined getDataID single field stores user-defined id when function returns an string | dropped: a custom `getDataID`: Baton keys by configured fields, not by a function |
| User-defined getDataID single field falls through to previously generated ID if function returns null  | dropped: a custom `getDataID`: Baton keys by configured fields, not by a function |
| User-defined getDataID single field falls through to generateClientID when the function returns null, and no previously generated ID | dropped: a custom `getDataID`: Baton keys by configured fields, not by a function |
| User-defined getDataID plural fields stores user-defined ids when function returns an string | dropped: a custom `getDataID`: Baton keys by configured fields, not by a function |
| User-defined getDataID plural fields uses cached IDs if they were generated before and the function returns null | dropped: a custom `getDataID`: Baton keys by configured fields, not by a function |
| User-defined getDataID plural fields falls through to generateClientID when the function returns null and there is one new field in stored plural links | dropped: a custom `getDataID`: Baton keys by configured fields, not by a function |
| User-defined getDataID plural fields falls through to generateClientID when the function returns null and no previously generated IDs | dropped: a custom `getDataID`: Baton keys by configured fields, not by a function |
| User-defined getDataID plural fields overwrite fields in same position but with different data in second normalization | dropped: a custom `getDataID`: Baton keys by configured fields, not by a function |
| normalize queries with provided variables | dropped: batonc: Expected a non-variable identifier (e.g. 'x' or 'Foo') |
| warns in __DEV__ if payload data is missing an expected field | kept, passes |
| does not warn in __DEV__ if payload data is missing for an abstract field | kept, passes |
| warns in __DEV__ if a single response contains conflicting fields with the same id | kept, passes |
| does not warn if a single response contains the same fields with the same id | kept, passes |
| does not warn if a single response contains the same scalar array value | kept, passes |
| warns in __DEV__ if a single response contains conflicting fields with multiple same ids | kept, passes |
| warns in __DEV__ if a single response contains conflicting linked fields | kept, passes |
| warns in __DEV__ if a single response contains conflicting linked fields with null values | kept, passes |
| warns in __DEV__ if payload contains inconsistent types for a record | dropped: one id of several types (`1`): Relay merges them into one record, Baton keys by type (docs/decisions/identity-is-configured.md) |
| does not warn in __DEV__ on inconsistent types for a client record | dropped: one id of several types (`client:1`): Relay merges them into one record, Baton keys by type (docs/decisions/identity-is-configured.md) |
| leaves undefined fields unset | kept, passes |
| when treatMissingFieldsAsNull is true set undefined fields to null | dropped: `treatMissingFieldsAsNull`: Baton has no option that writes a missing field as null |
| when treatMissingFieldsAsNull is true skips client fields not present in the payload but present in the store | dropped: `treatMissingFieldsAsNull`: Baton has no option that writes a missing field as null |
| when treatMissingFieldsAsNull is true does not warn if a single response contains the same fields with the same id | dropped: `treatMissingFieldsAsNull`: Baton has no option that writes a missing field as null |
| "falsy" IDs in payload should create client IDs for "falsy" values in payload | parts from Relay: Relay keys an object whose id is the empty string by its path; Baton keys it `User:`, one record for every such object of the type. |
| "falsy" IDs in payload should create client IDs for "falsy" values in payload - same id | parts from Relay: Relay keys an object whose id is the empty string by its path; Baton keys it `User:`, one record for every such object of the type. |
| "falsy" IDs in payload should create client IDs for "falsy" values in payload for list | parts from Relay: An `ID` the server sends as a number or a boolean: Relay keys the object by its path; Baton's ingest rejects the response. |
| records which concrete types implement which client schema extension interfaces | dropped: batonc: Unknown type 'ClientInterface'. Did you mean `ClientObject`? |
| when field error handling is enabled normalizes queries with multiple field errors | parts from Relay: Relay keeps every error of a field as a list of messages; Baton keeps one error a field, the last, with its absolute path. |
| when field error handling is enabled normalizes queries with field errors that bubbled up | parts from Relay: Relay keeps every error that bubbled to the nulled field, with paths relative to it; Baton keeps one, the last, with its absolute path. |
| when field error handling is enabled when noncompliant error handling on lists is disabled ignores field errors on an empty list | parts from Relay: An error whose path ends at a list that is not null: Relay drops it; Baton places it on the list's field, the last field its path reaches. |
| when field error handling is enabled when noncompliant error handling on lists is enabled stores field errors on an linked field that is an empty list | dropped: a Relay feature flag: `ENABLE_NONCOMPLIANT_ERROR_HANDLING_ON_LISTS` |
| when field error handling is enabled when noncompliant error handling on lists is enabled stores field errors on an scalar field that is an empty list | dropped: a Relay feature flag: `ENABLE_NONCOMPLIANT_ERROR_HANDLING_ON_LISTS` |
| Prototype-less objects (e.g., from graphql-js executor) normalizes prototype-less payloads with type discriminator | kept, passes |
| Prototype-less objects (e.g., from graphql-js executor) normalizes prototype-less payloads for union types | parts from Relay: The payload lacks the `__isNode` the server text asks for: Relay then skips `... on Node { id }` and stores no `id`; Baton knows from the schema that `Page` is a `Node` and stores it. |

The client extension files batonc rejects, left out of `schema/extensions/`:

- `AstrologicalSign.graphql`: the client field `AstrologicalSign.id` is non-null: a client field is nullable, since no server promises it
- `Client3D.graphql`: the client field `Persona.id` is non-null: a client field is nullable, since no server promises it
- `ClientInterface.graphql`: the client field `ClientTypeWithNestedClientInterface.client_interface` is non-null: a client field is nullable, since no server promises it
- `IAnimal.graphql`: the client field `Chicken.id` is non-null: a client field is nullable, since no server promises it
- `Todos.graphql`: the client field `Todo.todo_id` is non-null: a client field is nullable, since no server promises it
<!-- /harvest -->
