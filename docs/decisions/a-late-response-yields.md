# A late response yields to a newer deletion and to a newer response of its root

Status: accepted, 2026-11-05. Serves
[The response is the oracle](../principles/response-is-the-oracle.md) and
[Honest data](../principles/honest-data.md). Reopen a generation per slot,
fate's answer, if a fixture shows a late response overwriting a field a
newer response of another operation wrote, on a real screen.

## Context

The store commits responses in the order they arrive, and the contract
said nothing of the order between operations. A fetch issued before a
mutation and answered after it lands on the mutation's work: a list fetched
under `storeAndNetwork` before a `@deletes` mutation, answered after the
server confirmed the deletion, names the deleted record again, and "a
payload that names the record again revives it". The adopter at hand
cannot meet it, since its transport holds one request in flight; the next
adopter will. fate stamps every request with a generation when it is
issued and drops an older response's write over a newer one's per field;
its 1.15 release fixed "a delayed read can no longer bring back a deleted
record". The watch list carried the question since the fate note of
2026-10-09 as W2.

## Decision

The store numbers the requests its environment issues, and a response
carries the number of the request it answers.

- A deletion remembers the number current when it was made. A response
  issued before it, whose number is not greater, does not revive the
  record: its entries for the record are not written, and the record stays
  deleted. A response issued after it revives the record, as before. A
  payload committed by hand, an optimistic response and a subscription's
  event carry no number, so each may revive. The deletion's number is the
  one current when its commit lands, not its mutation's own, so a fetch
  issued while the mutation was in flight cannot revive the record either.
- A root remembers the number of the last response committed for it. A
  response of the same root with a smaller number is dropped at the door
  and logged: a newer answer to the same question has already landed.
- Nothing else is ordered. Two operations that write one field in opposite
  orders of issue and arrival still let the last arrival win, as the
  contract has always said; that is the reopening line above.
- The numbers live in memory only. The image keeps no generation, so a
  record read from the image after a relaunch may be revived by any
  response, which no stale fetch survives to do. A root's number lives
  with the root: one collected and made again while an older fetch of it
  is still in flight starts from nothing, and that response lands.

## Evidence

- Script `ordering` under `spec/scripts/`: a list attached, a second
  handle of the same list left in flight, a `@deletes` mutation committed,
  the in-flight fetch answered with the response that names the deleted
  record, which stays deleted; a fetch issued after the deletion revives it.
- fate `packages/fate/src/store.ts` and `client.ts`, read through the
  survey of 2026-11-05: `writeGeneration` stamped at issue, per-key
  `writeVersions`, `fetchByIdAndNormalize` under a generation.
- Nothing is measured and nothing needs to be: one integer per record and
  per root, one comparison per record a response names, one per response at
  the door.

## Not chosen

- A generation per slot, fate's model: four bytes a slot and a rule for
  every merge, hydration, connection page and streamed item, for a hazard
  no fixture shows yet. The reopening line names the fixture that would.
- Dropping every response older than the store's last commit: a slow
  fetch of one screen would be thrown away because another screen was
  faster, and the first screen would show loading until it fetched again.
- Ages per record or per field, which the roots decision refused: a
  generation is an order, not an age, and nothing reads it as freshness.
