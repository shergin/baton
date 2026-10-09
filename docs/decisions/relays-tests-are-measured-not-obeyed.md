# Relay's store tests are measured against, not obeyed

Status: accepted, 2026-10-09. Serves
[The response is the oracle](../principles/response-is-the-oracle.md) and
[Relay's words](../principles/relays-words.md). Reopen if the statuses stop
being reviewed, so that a known issue becomes a place where behaviour is
parked rather than decided.

## Context

Relay's runtime tests state, for a document, variables and a payload, the
records Relay's store holds afterwards. `scripts/relay-harvest/` records
those calls under Relay's own jest suite and translates the records into
Baton's keys, so that Baton's store can be compared with Relay's on inputs
nobody here chose. The first harvest, `RelayResponseNormalizer-test.js`,
gave 60 tests: 13 where Baton agrees, 10 where it does not, and the rest
using features Baton does not have (`@match`, `@module`, `@stream`, handles,
a custom `getDataID`) or a store the test seeded by hand. Of the ten, some
are Relay's choices where GraphQL says nothing, one is a payload no
conforming server sends, and one is Baton dropping errors. Treating Relay's
dumps as Baton's oracle would make each of Relay's choices Baton's by
default; dropping every disagreeing case would lose the measure.

## Decision

- Relay's tests are ingested as widely as the translation allows, and
  measured against, not obeyed. A harvested case has a status:
  `possible-bug`, `unspecified-behaviour`, `invalid-input`, `by-design`, or
  `unsupported-feature`; a case without one must pass.
- A case with a status other than `unsupported-feature` runs as a known
  issue: its result is ignored, and it fails when it starts passing, so the
  status is revisited. An `unsupported-feature` case is ingested, its
  document kept under `spec/relay/unsupported/`, and left out of the runs.
- A status carries a note saying how Baton and Relay differ and, once the
  owner has decided, a decision saying what is to be done. The statuses live
  in `scripts/relay-harvest/expectations.json`; a harvested dump is never
  edited, and a change of mind changes a status.
- The owner's direction for the normalizer's cases (2026-10-09): where
  GraphQL does not specify the behaviour, document it and copy Relay unless
  that costs performance (an empty-string `id`, an `ID` sent as a number or
  a boolean, an error whose path ends at a list that is not null); keep
  every error of a field as Relay does, under the same condition. A
  deferred fragment's fields in the initial payload and a payload missing
  its `__isX` answer are open.

## Evidence

- `spec/relay/README.md`: the harvest's table, each test with its status.
- Relay's `_normalizeDefer` skips a deferred selection's data in the
  initial payload on purpose; the test payloads carry it incidentally.
- Relay's `_normalizeInlineFragment` applies an abstract fragment only when
  the payload answers its `__isX` key; Baton takes memberships the plan
  lists from the schema, which a conforming response agrees with.

## Not chosen

- Relay's dumps as the oracle: each of Relay's unspecified choices would
  become Baton's without a decision, and a feature Baton left out on
  purpose would read as a failure.
- Only the agreeing cases: the disagreements are the measure, and a case
  that starts agreeing would go unnoticed.
