# The environment logs value-free events

Status: accepted, 2026-10-11. Answers
[#15](https://github.com/shergin/baton/issues/15)'s event sink and the
plan's D-N17. Serves [Honest data](../principles/honest-data.md) and
[What earns a concept](../principles/what-earns-a-concept.md). Reopen a
case when an adopter shows the number it needs and cannot derive; reopen
the value-free rule never.

## Context

The runtime reported through four hooks: the store's `reportMissing`,
`reportUnexpected` and `reportAmbiguousIdentity`, and the environment's
`requiredFieldMissing`, each a closure handed a `Record`, a `Slot` or a
`Value`. A production app wanted one place to attach its logging and
metrics, and a privacy rule: a hook that hands over a record makes it one
line to log a slot's value. The hooks also kept `Record`, `Value`, `Slot`
and `TypeID` public for a mechanism's sake. Relay's environment takes a
`log` function called with each `LogEvent`.

## Decision

One sink, `Environment.log`, called with each `LogEvent`: a value-free enum
of names and counts, never a record, a slot, a value, a variable or a
response body. The first cases are the fetch (started, completed with its
duration, failed with its failure's kind), the commit (its kind and the
slots it changed in records that existed), a field error a fetch's response
carried that no `@catch` handled, by operation and response path, the image
(opened, unavailable, written with its batches, failed) and missing data (a
field read and never fetched, a value a reader's type cannot hold, an id
naming records of several types, a `@required(action: LOG)` field that is
null), each by type and field name. The four hooks are gone, not forwarded.
Debug builds print the missing-data cases by default, as the hooks did; a
release build logs nothing until the app sets `log`. A case earns its place
as a concept does: by an adopter's number that cannot be derived from the
cases that exist.

## Evidence

Every event is raised where the runtime already knew the fact: the hooks'
four call sites, the two fetch paths, the commit's one door, the image's
open and write. A bench row measures a fetch and a commit with a counting
log installed, in `BENCHMARKS.md`.

## Not chosen

- Durations, byte counts, slot counts and notification counts on every
  event, as #15 drafts them. Each is a measurement the runtime would make
  for a sink that may be absent; the fetch's duration is kept because the
  handle times it already. The rest wait for the number an adopter needs.
- Keeping the hooks as forwarders. Two doors to one fact drift, and the
  hooks' signatures are what kept the record types public.
- A protocol for the sink. A closure is Relay's shape and an app's logger
  wraps in one line.
