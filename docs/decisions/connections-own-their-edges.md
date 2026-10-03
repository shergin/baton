# Connections reference page edges and own inserted ones

Status: accepted, 2026-10-03. Serves
[The store is the UI's state](../principles/store-is-the-ui-state.md) and
[Relay's words](../principles/relays-words.md). Reopen if a server pages a
connection under a storage key that does not change with the cursor, or if
persistence needs edge records that survive their page's record.

## Context

Relay's connection handler copies every edge of every page into a record the
connection owns (`client:<connection>:__connection_next_edge_index`), so the
merged list survives the page records being collected and so that mutation
payloads, whose edge records are keyed by their path, cannot alias each
other. Baton's records are objects and its collector marks from roots through
plans, so the question was what to copy.

## Decision

A page's edges are referenced, not copied: the connection record's `edges`
list holds the page's own edge records. The page's storage key carries the
cursor (`issues(after:"c",first:20)`), so pages never share edge keys, and a
refetch of the first page writes the same records again. Roots mark through
the connection's client slot as well as through the page they fetched, so
the edges and nodes of every merged page stay as long as any root reaches the
connection; the page's own record and page info are collectable once no root
fetched them.

An edge a mutation inserts (`@appendEdge`, `@prependEdge`) is copied into a
record the connection owns, numbered by `__connection_next_edge_index`, as in
Relay; `@appendNode`/`@prependNode` create such a record directly.

## Evidence

- The bench (2026-10-03): 42 pages of 50 notes merged into one connection
  cost one notification per page; after collection the store kept 4,207 of
  4,289 records, the 82 that went being the 41 pagination pages' own records
  and their page infos, with every edge and node kept.
- The optimistic-edge test found the aliasing Relay copies for: two
  `addNote` mutations share the payload record `client:root:mutation:addNote:noteEdge`,
  and the second optimistic apply rewrote the node of the edge the first had
  inserted. Copying inserted edges fixed it; copying page edges was never
  needed.
- Lifetime: records now size their values by what is written, because a
  cursor-paginated field registers a storage key per page on its parent type
  and pre-sizing every record of that type to the type's slot count cost the
  scroll bench 1 KB per record (+15.8 MB against +4.4 MB).

## Not chosen

- Copying every edge, as Relay does: a record and a list rebuild per page for
  no visible benefit; the marker already reaches the edges.
- Copying nothing: inserted edges alias across mutations of the same kind.
- Retaining the pagination queries as roots: Relay does not, and the
  connection, not the page, is what the screen reads.
