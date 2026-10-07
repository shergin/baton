# The runtime contract

What a Baton runtime does with a plan, a response and a store, in no
language's terms. The fixtures beside this file hold the facts a runtime is
compared against; this file holds the rules that produce them, one
paragraph a rule. Each paragraph ends with the fixture that holds the rule,
or with *unheld*, which means the Swift runtime proves it in its own tests
and no language-neutral fixture does yet. A rule marked unheld is still the
contract; the mark says where the proof is missing, not that the rule is
open.

The words are [the terminology's](../docs/terminology.md); the reasons are
[the principles'](../docs/principles/) and [the decision
records'](../docs/decisions/). Where a rule names a Swift type, it is for
the reader who has the Swift runtime open; the rule stands without it. The
last section says which of the Swift runtime's mechanisms are not part of
the contract.

The manifest's case kinds are in [`README.md`](README.md): a *case*
commits responses into an empty store and compares the dump, the reads and
one optimistic override; a *script*, the second kind, runs steps and
compares what each leaves. Rules held by scripts name the script.

## 1. Types, keys and records

**Types are interned by name.** A runtime knows a schema type by its name
and gives it a number once per process. The three roots are typed `Query`,
`Mutation` and `Subscription` whatever the schema calls its root types; the
compiler interns a `QueryRoot` or a `query_root` by the store's name. The
root records' keys are `client:root`, `client:root:mutation` and
`client:root:subscription`. *Held by* every dump: the root record is
`client:root`.

**A storage key is the field's name and its arguments.** Relay's rule: the
field name, then `(` and the arguments as `name:value` in the compiler's
order, which is by name, joined by `,`, then `)`; a field without arguments
is its name. An argument whose value is a variable that is null or absent
is left out, and when every argument is left out the parentheses go, so
`notes(first:2)` names the first page whether or not the document passed
`after`. A value is rendered as JSON: a string quoted with `"`, `\`, `\n`,
`\r`, `\t` and the control characters below U+0020 escaped and nothing
else; an integer in decimal; a boolean as `true` or `false`; `null`; a
list in brackets with `,`; an object in braces with its keys sorted and
quoted. *Held by* tests/keys-1 (`character(id:"a,b")`,
`characters(filter:{"name":"Rick","status":"Alive"})`,
`charactersByIds(ids:["7","2"])`, and a key with `after:null` left out);
the escaping of a string inside a key and a boolean argument are *unheld*.

**A float in a storage key is rendered one way.** A constant float in a
document is rendered by the compiler, and a float variable by the runtime,
and the two must agree: the shortest decimal that reads back to the same
value, with a `.0` when it has no fraction, and in exponent form as
`<mantissa>e<sign><two digits>` when the exponent is below -4 or at 16 or
above. This is `decide/keys.rs::swift_double` and Swift's `description`,
and a second runtime reproduces it. *Unheld*: a case with a float variable
in a key is owed.

**A key the build names is the process's; a key a session renders is the
store's.** A storage key the compiler emitted as a constant, with arguments
or without, is numbered by the process the first time it is met, densely
per type, in one table every module shares. A key rendered from variables
at run time is numbered by the store that rendered it, apart from the
build's numbers, and a record keeps those written to it in a short sorted
list, so a session's keys never widen the records they were not written
to. A text has one slot in a store: a rendering whose text the build names
takes the constant's slot, and a constant the build names after the store
rendered its text is adopted, the two slots becoming twins the store
writes together. The store frees a rendered key's number once nothing can
name it (section 7) and forgets every key at its end. *Unheld* as a rule
of numbering; what the dumps hold is the text, which is the same either
way.

**An entity's key is its type and the values of its key fields.** The
fields `baton.json`'s `identity` names for the type, after the type's name
and a colon: `Character:1`. One value is written as it is. Several are each
written with every `\` and `:` prefixed by `\` and joined by `:`, so that
no two lists of values meet: `Quote:BTC:USD`. A key field's value is the
text of its scalar: a string's contents, or a number as the server wrote
it. The compiler selects the key fields wherever the type is read and the
plan names them per variant, so the ingest knows no field by name. *Held
by* every dump with entities; the composite and configured keys by
tests/quote-by-pair, tests/quote-list, tests/asset-by-uuid and
tests/asset-list.

**An object without its key is keyed by its path.** The parent record's
key, then `:` and the field's storage key, then `:` and the list index for
an element of a plural link, and under an interface or union `:` and the
object's concrete type, so that a payload of another type at the same path
is another record: `client:root:characters(page:1)`,
`client:root:search(name:"Rick"):0:Character`. *Held by*
rickandmorty/characters-page-1 (`client:root:characters(page:1)`),
tests/union-path-character and tests/union-path-location.

**A mutation root's fields are keyed without their arguments.** `addNote`
rather than `addNote(text:"...")`, and an aliased one by its alias,
`addNote(as:"first")`: a caller reads a payload once, and a key per input
would number a slot for every call. A subscription root's fields keep their
arguments, since two live subscriptions of one field must not share a slot.
*Held by* tests/add-note-n9 and tests/note-added-1 as dumps.

**A connection's records hang off the parent.** The client record every
page merges into is keyed by the parent's key, `:` and Relay's handle key,
`__<key>_connection` with the filters; its page info is `<connection
key>:pageInfo`; an edge the connection owns is `<connection
key>:edges:<n>`, numbered by the connection's `__connection_next_edge_index`
client field. *Held by* tests/notes-page-1, tests/add-note-n9 and
tests/add-note-node-n7.

**A record holds slots, and a slot holds one of a closed set of values.**
Missing, which means the store never received the field; null, which the
server said; a boolean; an integer; a float; a string; a link to one
record; a list of links, each a record or null; a list of scalars, each a
value or null. A custom scalar is a string: its text exactly as the server
wrote it, a quoted string's contents or the bytes of any other token. A
field error sits beside the slot it names. A record carries a deleted flag.
A record's dump is its slots by storage key, the type as `__typename`, a
link as `{"__ref": key}`, a list of links as `{"__refs": [key]}`, the
errors under `__errors`, a deleted record as `null`. *Held by* every dump;
custom scalars as text by tokenizer/custom-tokens.json, read through the
lens.

**A placeholder stands behind a non-null link without a record.** One
record per type, keyed `client:placeholder:<Type>`, never among the
store's records, every field missing; a lens below it reads zero values and
reports nothing a second time (section 9). *Unheld.*

## 2. The plan

**A plan is one selection per operation, declared once per distinct
selection.** A selection has a type, the response keys of the type's key
fields in the configured order (empty for a type keyed by its path), whether
the type is abstract, the membership answers the response may carry, and
variants. A variant serves a group of concrete types (or every other type,
or every type a response says satisfies a condition), may override the key,
and lists its fields. Two selections are the same, and shared, when every
fact of them is equal: type, key, fields, slots, guards, labels and the
selections below. *Held by* the goldens under
`compiler/src/tests/goldens` and the plans under `compiler/src/tests/plans`
for the compiler's side; for the runtime's, by every case, since every
read goes through one.

**A field is a response key, a storage key and a kind.** The kind is a
scalar (string, int, float, bool or custom; a list or not) or a link (a
selection; plural or not; a lookup, for a root field an entity satisfies; a
connection). A field may carry an edit (an edge directive), a `@defer`
label, whether it or an ancestor is caught by `@catch`, whether it is a
client field no server answers, whether it is a transient root field, and
its guards: alternatives of conjunctions of `@include` and `@skip`
conditions, the field being selected when any alternative holds, empty
when it always is. *Held by* the goldens and plans.

**A plan is resolved once per set of variables.** Resolution binds the
variables: a field whose guards fail is dropped; a key with variables is
rendered and numbered by the store; a lookup's key is composed from its
arguments' values as the ingest composes a key from key fields; a
connection learns its merge mode from its cursor arguments (an `after`
present appends, a `before` present prepends, neither replaces; a variable
given null is not present); an edit's connection ids come from its variable
or constant list. A selection that reads no variable is resolved once and
shared by every store. The variant of each listed type is resolved at once;
the variant of a type the plan did not list is resolved when a record of
it first comes, from the fields every type reads and then the fields under
each condition the type satisfies, by response key, the first winning, and
is kept per type and per set of conditions. *Held by*
tests/conditions-included and tests/conditions-excluded (guards),
tests/notes-page-2 (a connection's mode), tests/union-unknown-type (an
unlisted type's variant).

**A fragment's arguments bind over the parent's variables.** A spread
with `@arguments` binds the fragment's scope over the parent's: for each
argument the passed literal or variable, else the default, else null; the
compiler inlines the values into the normalization plan and the text, as
Relay does, and the lens's owner binds the scope once per parent owner. *Held
by* tests/author-notes-page-1 and tests/notes-page-2 through their keys.

**An operation's expiration is a constant of its plan.**
`@cacheExpiration(seconds:)` is emitted as a constant of the operation,
left out of the text a server receives; the store reads it against the
root's age, an operation that states none takes the store's default, and
no timer is armed. *Held by* script `ages`.

**The compiler decides what the runtime relies on.** An operation's text
is printed compact, with Relay's printer's own option (no newline,
indentation or optional space, a comma between items, strings as they
are), the fragments it reaches after it, and that one text is sent, hashed
and kept in the persisted file. An operation of client fields alone is
refused, since a server answers one field at least. A spread inside an
inline fragment on an abstract selection carries `@alias`, Relay's rule.
Under `onError: NULL` a field the schema types non-null is typed by its
semantic nullability: non-optional under `@throwOnFieldError` and inside
`@catch`, optional elsewhere. *Held by* `spec/documents/*.graphql`, written
from the generated code and checked against it, for the text; the rest by
the compiler's goldens.

**Resolution makes the lists the walks use.** From a variant's fields: the
fields a response is read by (every field but `__typename`); the ones a
complete response must carry (the server's own, outside any deferred part,
not the client's); the ones the availability check waits for (the same);
the connections' client links; the links the collector follows (every
link, deferred or not, and the client links); the client fields a payload
writes. A walk tests no field for what it is. *Held by* the cases through
their reads and dumps; as a rule, *unheld*.

## 3. The ingest: a response to a change set

**The envelope.** A response is an object with `data`, `errors`, and for an
incremental response `pending` and `hasNext`; other members are skipped.
`data` null with errors is a request error, which fails the fetch with the
errors and writes nothing; `data` absent with no errors is malformed. The
change set is grouped by record when the walk ends, so the commit writes a
record's slots in a run. *Held by* spec/tokenizer/malformed.json for
malformed responses; a request error's failure by scripts `phase` and
`events`.

**An object is read against a selection.** Under an abstract selection the
object's `__typename` is read first, by scanning ahead from the first
member before any field is matched, and settles the variant the object is
read with; a name the plan lists is matched by its bytes, an escaped or
unlisted name through the registry. Members are then matched to the
variant's fields by response key, in the order the plan expects first and
by search otherwise; an unmatched member is skipped. The object's key is
settled from its key fields as they arrive; when a link is reached before
the key is complete, the scan looks ahead for the key fields not yet seen,
since a child's path key may run through this object. A selection may nest
twenty-four levels deep; deeper is malformed. *Held by* every case;
tests/union-1, tests/node-fields-character and tests/node-fields-episode
for the type read first; the key found after a link by tests/keys-1.

**A scalar is read by its kind.** A string, int, float or bool as JSON
gives it; an int field answered with a float that is a whole number reads
as that int; a custom scalar as its text; null as null. A list of scalars
keeps its nulls. *Held by* spec/tokenizer/response.json and the tokenizer
cases (integral floats, ints beyond the platform's range, surrogates,
escapes).

**A link is read as the object or list it holds.** A null link is null; a
plural link's null element is a null entry; each object is read against the
child selection with this record as its parent and the field's storage key
and index as its path. A connection field's page is the server's record;
the client record it merges into is written beside the page as a client
link on the parent, and a merge edit is recorded with the mode. A field
with an edge directive records the insertion of the linked record, or, for
a scalar id under `@deleteRecord` or `@deleteEdge`, the deletion by that
id. *Held by* every dump with links; the connection link and merge by
tests/notes-page-1; the edits by tests/add-note-n9, tests/add-note-node-n7,
tests/delete-note-n2 and tests/remove-note-n2.

**A complete response answers every field the plan expects.** A server's
response to an operation is complete: an object that omits a field the
variant expects (the server's own, outside a deferred part, not the
client's) is malformed, and the fetch fails as a response of another kind
fails it. An optimistic response and a payload committed by hand are not
complete and may carry part of a selection. *Held by*
tests/characters-7-8 and tests/characters-with-gaps as `complete: false`
cases; the malformed fetch is *unheld*.

**Memberships come from the response.** Relay's `__isX: __typename`
answers are read while the type is, for a type the plan did not list; the
change set carries them, the commit learns them, and the image keeps them
for the next launch. A type the plan lists needs no answer. *Held by*
tests/union-unknown-type; the image's keeping is *unheld*.

**An error lands on the last field its path reaches.** Each entry of
`errors` with a path is walked from the root through the plan and the
entries just read: the walk stops at a field whose value is null, a link
the response does not continue, or a list index it does not have, and the
error lands on the last field it reached, which under GraphQL's null
propagation is the nullable ancestor. An error whose path reaches no field,
or that has no path, is unplaced: it belongs to the response and to no
record. An error on a field that is, or whose ancestor is, under `@catch`
is caught, and does not fail a `@throwOnFieldError` operation. *Held by*
tests/character-errors, tests/negative-error-index,
tests/float-error-index.

**An incremental response is parts.** The first part is a response with
`hasNext` and, in the 2024 shape, `pending` announcing the parts to come by
id, path and label. A later part carries `incremental` items, each by its
own path and label (the June 2023 shape) or by the id of an announced part
and a sub-path below it, and `completed` entries naming announced parts
that are done, with errors when the server could not deliver one. An item
finds its record by walking the path from the root through the store, and
its selection by the label's deferred fields at that record, or by the
object's own selection below a sub-path; the object is then read as any
object is, and committed. A completed part with errors is a failed part:
the errors land on the fields it would have filled. A part that names a
place the store or the plan does not have is dropped and logged. *Held by*
tests/character-deferred, tests/character-deferred-pending and
tests/node-deferred; a dropped part by script `events`; a failed part is
*unheld*.

## 4. The commit

**Every write is a batch, and a batch has a kind.** A server batch is
written to the image; an optimistic batch keeps its undo with its layer and
the image is not told; a local batch, the runtime's own writes (a page's
loading flag, a lookup's link bound, a link repaired, a cell filled from
the image), neither. Nothing outside a batch writes a record. A batch ends
by notifying the observed fields whose value or error differs from before
the batch, netted: a slot changed and changed back notifies nobody, and a
record the batch created notifies nobody, since nothing had read it. A
plain server batch under no optimistic layer notifies as it writes, since
nothing in it can change back. *Held by* scripts `notifications` and
`optimistic`.

**A change set is applied in one order.** Memberships are learned; records
are found or created by key; for each record, a deleted one a payload
names again is revived, room is made, each slot the set carries without an
error has its error cleared, and each entry is written, last entry winning
per record and slot, a value equal to the slot's current value writing
nothing (strings compared in place, lists of links by identity, lists of
scalars by value); then the edits, in the set's order; then the field
errors. *Held by* every dump; the equal-value rule by script
`notifications`.

**A page merges into its connection as Relay's handler merges it.** The
connection's own fields follow the page's, except the edges and the page
info link. Edges replace, append after or prepend before by the mode the
page was fetched with, deduplicated by node, the first edge for a node
kept, null edges dropped; a page fetched after a cursor that is no longer
the connection's end, or before one no longer its start, is ignored. The
page info merges per direction: a replacing page sets all four fields; an
appending page `hasNextPage` and `endCursor`; a prepending page
`hasPreviousPage` and `startCursor`; a field the page's info lacks is left
as it was. *Held by* tests/notes-page-1 and tests/recent-notes-page-1 (a
replace); the merge of a second page, a refetch's replacement and a page
after a cursor that is no longer the end by script `connections`; a
prepending page's merge is *unheld*.

**An edge directive edits a connection the store holds.** The connection
an edit names must exist in memory, live, and hold what the image has or
more (hydrated, or never empty); one the store does not hold that way is
forgotten in the image instead, so the next read fetches it. An edit on a
record no connection field made, or an edge of another type than the
connection's, is left alone. `@appendEdge` and `@prependEdge` copy the
payload's edge into an edge the connection owns and insert it, unless an
edge for the same node is already there; `@appendNode` and `@prependNode`
make an edge of the named type with the node and a null cursor;
`@deleteEdge` removes every edge whose node is an entity with the id;
`@deleteRecord` deletes the one live record of any type with the id, and
when memory holds none asks the image to forget every record with it, and
when it holds several does nothing and logs the ambiguity. *Held by*
tests/add-note-n9 (append), tests/add-note-n0 (prepend),
tests/add-note-node-n7 and tests/add-note-node-n0, tests/delete-note-n2,
tests/delete-note-7, tests/remove-note-n2; an edit into a connection that
already has edges by script `connections`.

**A deleted record reads as absent.** Its values are cleared through the
batch, so the bodies that read them are told; its flag is set, so links to
it read as null and lists skip it; and at the batch's end every slot that
links to it, a link or a list with it among its elements, is notified. A
payload that names the record again revives it, told the same way. *Held
by* tests/delete-note-7 (the record as `null`); the notifications by
script `notifications`.

**An optimistic layer rebases under every commit.** An optimistic response
is normalized by the mutation's plan at the mutation root and applied as a
layer with an undo log, on the main thread, so it shows in the turn of the
call. A server batch under live layers lifts every layer, applies the
payload, re-applies the layers and notifies the net difference; the
server's answer to the mutation replaces its layer in that same batch; a
failure reverts the layer, later layers re-applied over the gap. A layer
is never written to the image. *Held by* every case's `override` for one
layer's reads; the rebase, the replacement and the revert by script
`optimistic`; later layers re-applied over a gap are *unheld*.

**A server batch is handed to the image.** A snapshot of every record the
batch changed, and each changed field of the query root one by one, taken
after the layers were lifted so the values are the server's; and what the
batch could not change in memory, for the image to forget. *Held by* the
oracle's second store over the image, for the records; as a rule,
*unheld*.

## 5. The availability check and hydration

**The check answers from memory, then with the image.** Whether every
field the selection waits for is present from the record it starts at:
memory is walked first; when it cannot answer and the store has an image,
the same walk runs again with the image at hand, inside one read
transaction, filling what memory lacks. The answer is one of three: in
memory, with the image's help, or a miss. What the walk writes, a lookup's
link bound, a link repaired, a cell filled, is one local batch notified
once the walk is over; nothing observes a walk in progress. *Held by* each
case's `complete`, which says whether the check passes on the responses;
the image's answer by the oracle's second store and by script `check`;
the lookups by script `check`; the batch is *unheld*.

**The walk.** For each field the variant waits for: a missing scalar is a
miss; a missing link with a lookup is satisfied by the entity the lookup
names, if the store or the image holds it, and the link is written; a
missing link without one is a miss; a null link is fine; a link is
followed, a deleted target not entered; every element of a list is
followed. Then the client fields, which are hydrated and never waited for,
and the records behind a client link brought back. Then the connections'
client links: a connection record that holds nothing, swept or never
filled, is a miss in memory and walked with the image at hand, and a link
to a connection the image has no row for stays a miss. The query root's
link to a connection is a cell of its own in the image, read here. *Held
by* `complete`; the rules one by one are *unheld* (script `check`).

**A lookup binds in the check, never in a read.** A typed lookup names
`Type:value`, live in memory or read from the image, where a record is
registered only once the image had its row. A lookup without a type probes
the members of the field's interface or union that one value keys: the one
live entity with the id among them, or none when several have it, which is
logged. *Held by* tests/search-1 as a dump; the binding from a cached list
without a fetch, in memory and from the image, by script `check`.

**Hydration fills what memory lacks, once.** A record's row is read once,
and the slots the record lacks are filled; a slot that holds a value is
left alone, since memory is the truth. The query root is stored a row per
field and never marked read, so each of its fields is filled on its own. A
link to a record the collector swept is pointed at the live record of that
key. A row the image was told to forget reads as missing until a response
writes the record again. A row that stops making sense is used as far as
it went. The operation's age comes with its data (section 7). *Held by*
the oracle's second store; the rules one by one are *unheld*.

**The deferred parts are checked apart.** Whether every deferred part of
the selection is whole, in memory or in the image. A record read from the
image holds every cell of its row, a deferred fragment's link among them,
with nothing behind it: such a field is cleared, so its fragment reads
absent rather than empty, unless a field outside the deferred part reads
the same slot. Either way the operation fetches; the rest of it renders
meanwhile. *Unheld.*

## 6. The lens reads

**A read is a slot load that registers.** A lens holds an anchor: its
record, its owner (the scope of variables, which renders a key with
variables once and settles an `@include` or `@skip` condition once) and its
origin (the record the enclosing fragment starts at). An accessor reads one
slot of the record and registers the read with the platform's observation
of that slot alone; a body is invalidated when that slot of that record
changes and at no other time. *Held by* every case's `reads` for the
values; the invalidation by script `notifications`.

**Two anchors are equal when their three words are the same objects.** The
record, the owner and the origin, by identity; a lens is equal when its
anchor is, and no lens is hashable. *Unheld*; the rule is the platform's
diffing to use.

**An `@inline` fragment reads as a value.** A fragment so marked compiles to
a value of its fields in place of a lens: a nested value per link, a list
per plural link. The spread's accessor on the parent's lens builds it from
the record when it is called, on the main thread, through the readers a
lens's accessors use, so what the build registers and reports is the same;
a conditional or deferred spread yields an optional value. A value's field
errors include those of the values it spreads; a value with
`@throwOnFieldError` is not spread inside another value; an inline fragment
spreads only inline fragments and takes no `@connection`, `@refetchable` or
`@required`; a non-null mapped scalar in it reads optional. *Unheld* (the
Swift tests prove it); the reads could be rows of `reads`.

**A scalar reads as its type or reports.** A string reads a string, and a
number or boolean as its text; an int reads an int, or a float that is a
whole number; a float reads a float or an int; a bool a bool. A null in a
field typed nullable is nil. A null in a field typed non-null is a zero
value (the empty string, zero, false) and is logged as unexpected. A value
of another kind reads as nil, or as the zero value where non-null, and is
logged as unexpected. A missing value reads as nil or the zero value, is
logged as missing, and asks for the heal (section 7). *Held by* `reads`
for the values; the missing and unexpected events by script `heal`; the
zero values are *unheld*.

**A list of scalars follows its element type.** A list whose elements the
schema types non-null drops an element it cannot hold, a null or a value
of another kind, and reports it once; a list whose elements are nullable
reads a null element as nil and a value of another kind as nil, reported
once. *Held by* tests/asset-prices and tests/lists-statuses with their
`note` rows.

**A mapped scalar converts at the read.** The store keeps the text; the
accessor converts it to the type `customScalarTypes` names and says the
conversion can fail: optional wherever the schema puts the field, unless a
directive says what a failure does. A text that does not convert reads as
nil, is logged as unexpected and never as missing, and never reads as a
zero. Under `@required` and `@throwOnFieldError` the accessor throws the
conversion's error; under `@required(action: NONE)` or `LOG` the lens is
unsatisfied as a null would leave it; under `@catch` the `Result`'s failure
carries it. An enum reads as the type generated for it, with an unknown
case for a value the build does not know, so the conversion cannot fail and
the accessor keeps the schema's nullability; a null on a non-null enum
reads as the unknown case with an empty text and is reported. *Held by*
tests/asset-prices, tests/asset-by-uuid and tests/lists-statuses.

**A link reads as a lens or nil.** A link to a live record is the child's
lens; to a deleted record, nil; null, nil; missing, nil and reported. A
non-null link with no record, missing, null or deleted, reads the type's
placeholder, so the reads below it yield zero values and the link alone is
reported. A plural link is a collection of lenses over the live records in
order, null entries and deleted records dropped, and the elements a
`@required` field of theirs rejects dropped as Relay nulls them; a nullable
list reads as an optional collection, since the server's null and its
empty list differ. *Held by* `reads` at paths through links and lists.

**The error directives read in Swift's terms, by Relay's rules.**
`@required(action: NONE)` and `LOG` bubble: the accessor that produces the
lens produces nil when a required field in it is null, and LOG logs the
path; `THROW` makes the field's accessor throw, with the field's error or a
required-field error. A root whose required fields bubble fails the
operation with the path of the first one null. `@catch(to: RESULT)` reads a
result whose failure holds the field's error and every error below it,
required nulls included; `NULL` reads errors as null. `@throwOnFieldError`
on a fragment throws at the spread for an uncaught error inside; on an
operation, fails the operation for an uncaught error in its own selection
(a spread's fragment weighs its own) or one the response carried without a
field to hold it. Semantic non-null fields read non-optional under either,
and inside `@catch`. *Held by* tests/character-name-hidden,
tests/character-errors and tests/two-spreads-1 through their `note` rows;
the phase's failure by script `phase`.

**A type condition reads by membership.** A lens under an interface or
union tests a record's type against the condition's members: the set the
build compiled, or what a response said; the test is a table lookup and
hashes nothing. A concrete type's lens sees the fields selected under the
interfaces and unions its type satisfies, under their conditions. *Held by*
tests/union-1, tests/union-unknown-type, tests/node-fields-character,
tests/node-fields-episode.

**A deferred fragment is present once its fields are.** The spread's
accessor is nil until a field the label marks holds a value. *Held by*
tests/character-deferred's reads.

**Pagination and refetch read the fragment's record.** A connection lens
reads the merged edges' nodes (null edges, null nodes, deleted records and
rejected nodes dropped), `hasNext`, `hasPrevious` and the loading flags
from the connection record. `loadNext` fetches the fragment's refetch query
with the lens's variables filtered to the query's, the count, the merged
end cursor and the id of the fragment's record (its origin), read from the
slot the query names or else from the record's key, and does nothing while
a page is loading or when there is no next page; `loadPrevious` mirrors it.
`refetch` runs the query with the lens's variables and the record's id and
updates the records in place. The loading flag is set on the connection
record as a local write for the fetch's duration. *Held by*
tests/notes-page-2 and tests/notes-page-3 for the pages' dumps; the walk
from a lens is *unheld* (script `connections`).

## 7. The lifetime: roots, retention, ages, collection

**A root is an operation's selection and the record it starts from, kept
by the store.** Its key is the operation's name and its variables as JSON.
A root is made on first sight and lives while a holder keeps it; `retain`
counts a holder, with whether the holder's policy allows the network; at
no holder a query's root waits in the release buffer, oldest out first, as
many as the buffer holds (ten by default), and a root pushed out leaves,
with its handle and the fetch it had in flight. A subscription's root
leaves at once when released. A completed mutation's root waits apart from
the buffer, one per operation value and as many as the buffer holds, so
mutations push no released query out. *Held by* script `lifetime`; a
subscription's root leaving at once is *unheld*.

**Every server write dates its root.** The commit of a response stamps the
operation's root with the store's time and the invalidation it was fetched
under, and counts the fetch; the image is told, except for an operation
selecting a transient root field, whose stamp would name what the field
was asked with. A query just written that nothing retains waits in the
release buffer, as a preload does. A deferred response is dated when its
stream completes. *Held by* script `ages` for a fetch's stamp, here and
across a launch; the transient root field and the deferred response are
*unheld*.

**An age is the root's, and an unknown age is stale.** A root this launch
has not fetched takes the age the image knows, the time since an earlier
launch fetched it; data that needed the image and has no such time is
stale wherever an expiration applies. Data is stale when its root's
invalidation is older than the store's, or when the operation's own
expiration, `@cacheExpiration(seconds:)`, or else the store's default,
has passed since the stamp; no expiration means never. `invalidate` marks
everything stale, in memory and in the image, and refetches the retained
roots whose holders allow the network; `revalidate` refetches the retained
roots that are stale or whose last fetch failed, where a holder allows the
network, and marks nothing. *Held by* script `ages`; a revalidation of a
failed fetch is *unheld*.

**The collector marks from retentions and from nothing else.** A pass runs
on the next turn of the main thread after a root left the store (pushed
out of the buffer, dropped, or a completed mutation evicted) or a server or
optimistic batch moved or dropped a link (a list that only grew does not
count). It marks every record reachable from every root through the links
the plan follows, the connections' client links among them; the records an
optimistic layer wrote; and the records whose rows wait to be written to
the image, so the image is never older than memory. Every other record is
removed: its values cleared so cycles break, the roots' links to it
dropped. Then the store frees every rendered key's number that no live
resolution or scope holds, no layer carries and no waiting row names: the
records drop their entries under it, the image forgets its name, and the
number is used again lowest first. *Held by* script `lifetime` for the
marking from the roots and the sweep; the marks from layers and from rows
waiting for the image, and the numbers freed, are *unheld*.

**The heal.** A read that finds a slot the store never received logs it
and tells the owner's environment, which marks the owner's root stale and
refetches it if a holder allows the network, once per fetch of that root;
a field still missing after the heal's own refetch is logged as unexpected
and healed no further. A lens made by hand, with no root, is logged and
not healed. A deleted record's fields and a client field report nothing.
*Held by* script `heal`; a deleted record's fields and a client field are
*unheld*.

**A page's fetch has no handle and no root of its own.** The fetch runs the
fragment's refetch query, the connection owns the merged pages, and the
root the fetch makes waits in the release buffer like any fetch nothing
retains. *Unheld* (script `connections`).

**A session ends once.** The environment's end cancels every fetch and
stream it started, drops the roots, clears every record, closes the image
and forgets the session's keys. An ended store commits nothing: a response
that lands after the end, which cancellation could not reach, reaches
neither memory nor the image nor the log. A handle still held reads failed
with the environment gone and tells its observers; a lens still held finds
its records cleared; every later call fails the same way. *Held by*
script `end`; the image closed and the keys forgotten are *unheld*.

## 8. The handle: policies, phase, fetch

**A handle is a view of a root and of a fetch.** The environment makes one
per operation value, shared by equal values, with the root among the
store's and the fetch in flight among its own; `preload` makes one and
parks its root in the buffer, so the first attach finds the fetch made or
on the way and makes none. *Held by* script `phase` for a handle shared by
equal values; `preload` is *unheld*.

**A value is resolved by a view, and no environment is not a session.**
Outside any view an operation value is unresolved and reads as loading. A
view's storage resolves it to a handle in the environment the view sees,
retains the root for the view's life, and resolves again when the value or
the environment changes. A view outside every environment gets no handle:
the value reads as failed with the environment error that says so, its
fetch is idle, a refetch throws that error, and nothing is fetched; a
mutation action outside every environment throws it too. No placeholder
environment and no store stand in. *Unheld* (the Swift tests prove it).

**An attach applies a policy.** The store is checked for the operation's
data (not under `networkOnly`, which asks it nothing); a complete answer
takes the age; with data the phase settles to what the data deserves
(section 8, the verdict). Then: `storeOnly` fails with a missing-data error
when the store cannot answer and the phase is loading; `storeOrNetwork`
fetches when the store cannot answer, when the deferred parts are not all
held, when the data is stale, or when the last response carried errors no
field holds; `storeAndNetwork` and `networkOnly` fetch, and `networkOnly`
shows loading until its own response if nobody shows the handle yet. One
fetch is in flight per handle at a time. *Held by* script `phase`, and the
fetch of stale data by script `ages`; the fetches for deferred parts not
held and for errors no field holds are *unheld*.

**The fetch is a value beside the phase.** Idle, in flight, or failed with
the failure and when it failed. A fetch that fails behind data leaves the
phase as it was and is read here by every view of the handle; the next
response replaces it. `isRefreshing` is data present and a fetch in flight.
`refetch` fetches again and throws the failure rather than showing it;
`retry` after a failure with no data behind it shows loading, and after one
with data in the store refreshes behind it. A fetch superseded by another
leaves the handle's state to whoever superseded it. *Held by* script
`phase`; a superseded fetch is *unheld*.

**A failure says its kind.** The transport's, carrying what the transport
threw unchanged; a request error, the server's errors with no data; a
malformed response the plan could not read; the environment's, when
nothing could send the request. A field error is not a kind. *Held by*
scripts `phase` and `end`; the log names the kind, held by script
`events`.

**The verdict is what the data deserves.** Ready, unless `@throwOnFieldError`
finds an uncaught field error in the operation's own selection or among the
errors the last response carried with no field to hold them, or a bubbling
`@required` root finds a required field null; then failed with those,
while the data stays in the store and ages as ready data does. The verdict
is settled after the fetch, after every attach that finds the data, and
after every commit that changed a null, a link, an error or a deletion; a
verdict equal to the last is no change (the same errors, the same path).
The verdict is the root's, settled by the store, and the handle's phase is
derived from it, from whether the root holds the data, and from the fetch;
with data the phase reads the verdict and not the fetch, so a body that
reads the phase is not woken by a fetch that changed nothing. *Held by*
script `phase`; a verdict equal to the last is *unheld*.

**A subscription's handle holds a stream.** The stream is a value: idle, or
parked while the environment is inactive; connecting until the first
event; open; waiting until the instant it tries again after a failure;
ended by the server's completion, by a request error (which a retry would
repeat), or by the environment's end. Each event is committed at the
subscription root through the door, and counted; an event with errors and
no data is one bad event and the stream goes on. A failure while the
handle is retained waits and reopens by a fixed backoff: a step doubling
from one second to thirty, jittered to between half and the whole of it,
reset by an event. The environment's `isActive` parks every retained
stream while false and resumes them when true; every reopening counts as a
resumption an owner may observe. Released to no holder, the stream closes
and the root leaves at once. *Held by* tests/note-added-1 and
tests/note-added-2 for one event's commit; the states by script
`subscriptions`; an end by a request error and the backoff are *unheld*.

## 9. The image

**The image is the store's records and nothing derived from them.** A row
per record keyed by the record's key; the query root a row per field; the
time each operation last fetched; the memberships responses taught; and a
table of names, because slot numbers belong to a process. It is written
behind every server batch, off the main thread, and read by the
availability check and by nothing else. An optimistic layer never reaches
it. A record of a transient type is not written, nor the cell, the key or
the stamp of a transient root field, and a slot linking to a transient
record is left out of its row. *Held by* the oracle's second store (the
records come back); transient rows by tests/secrets and
tests/character-secret as dumps; the rest *unheld*.

**A row is replaced or merged.** A record whose row the check has read is
replaced by the batch's snapshot of it; a record memory has not read has
the snapshot merged into its row, the batch's cells over the row's, so a
response with a few of a record's fields leaves the rest for the next
check. A deleted record replaces its row, and a deleted row's cells are not
merged into a record a payload names again. *Unheld.*

**One image holds a file, and a takeover is a launch.** One process uses a
file through one image at a time: a second image made on a file another
holds runs without it, and stops a debug build where it is made. An image
that takes a file over after the environment that held it ended counts as
a launch, though the process is the same, so the rows the closed one wrote
and it does not read age out a launch sooner. The file is made with the
protection class the app names, or its directory's default. Removing the
file is a step apart from the end, under a marker the next open finishes
if a crash interrupts the deletion. *Unheld*.

**The image is a cache.** A file of another format, version or protection
class, a corrupt file and a file that is not an image are deleted and
started again (a database that is not an image is left alone). Rows age
out by launch: a record that goes a whole launch unread is dropped at the
next, and the names no row uses go with the rows. A file over its size
limit evicts the rows of launches before the last, then the last launch's,
and starts over only with nothing left to evict. An image is made for one
store and lives as long as it: the environment's end closes it for good,
and the next environment makes its own; one process holds a file through
one image at a time. A file that cannot be taken, locked or full, is waited
for, the writer keeping its work, a read meanwhile missing, and work past
fifty thousand rows dropped with the image started again. *Unheld*, and
per platform in its bytes: a second runtime's rows need not read as the
Swift runtime's.

## 10. The environment and the wire

**A request says its kind and carries text or id.** The operation's name,
its kind (query, mutation, subscription), its document (the text the
compiler printed, or the id it was registered under, as the build decided
and never both), its variables, the `onError` value when `baton.json` names
one, and whether the response may arrive in parts. The standard encoding
writes `operationName`, `query` or `documentId`, `variables`, and `onError`
when set, in that order, as one JSON object. A client field is left out of
the text and the id a server receives. *Held by* script `transport` for a
text, with a client field and client directives left out of it; the
`documentId` and `onError` members are *unheld*, since the test target
sets no `persistConfig` and no `onError`.

**A variable is sent as its JSON value.** A variable of a mapped scalar or
an enum is sent as its text; an input object as the object its fields
render, a field left unset absent from the request, as GraphQL
distinguishes absent from null, and an explicit null written as a constant
in the document. A variable the caller leaves unset is absent from the
request, and one the operation declares with a default is sent as that
default, as Relay sends it, so the server and the store's keys see one
value; GraphQL applies an argument's own default only to an absent
variable, never to a null. A server with another convention replaces the
encoding on the built-in transports and keeps them. *Held by* script
`transport` for an enum and a list of it, a `Decimal` and a list of it,
and a list of input objects with fields left unset; the explicit null
constant, an unset variable (absent, or its declared default) and a
replaced encoding are *unheld*.

**An environment error says what is missing.** The view's environment, the
lens's (a lens made by hand asked to fetch), the one that made a handle and
is gone or has ended, or the subscription transport. *Unheld*.

**A transport has one verb.** A request yields a stream of payloads: one
for a query or a mutation, the parts of a deferred response, the events of
a subscription. The built-in HTTP transport posts the body, asks for
`multipart/mixed` for an incremental response and `text/event-stream` for a
subscription (`graphql-sse`, distinct connections), reads credentials per
attempt, and fails a response outside 2xx with its status and body,
except a request error: a response outside 2xx whose media type is
`application/graphql-response+json` and whose body is errors and no data
(or null data) fails with those errors, the request kind of failure, as a
2xx response of errors and no data does, so a subscription refused so ends
rather than waits. The socket transport speaks `graphql-transport-ws`. A
failure without a response has status 0 and says what went wrong. A mutation is never sent
twice by anything the runtime does. *Unheld*; the framings are proved in
the Swift tests alone.

**The door's cancellation rules.** A query's fetch checks for cancellation
before the commit, so a response superseded while it was read never lands;
a mutation does not, since the server applied it, and its request runs in
a task the caller's cancellation does not reach; a subscription commits
until its task ends. *Unheld.*

**A transport for tests is a transport.** A recorded transport answers by
operation name from recorded responses or from a function of the request;
a scripted one holds an operation until the test replies or refuses, drives
a subscription's events, and lists what was sent; an operation with no
answer fails with status 0 and says so; a silent one never answers. Nothing
behind them can tell. *Unheld*; each runtime's test product.

**The log is value-free.** The environment calls one function with each
event: a fetch started, completed with its duration, or failed with its
failure's kind; a server or optimistic batch committed with the slots it
changed in records that existed; a field error no `@catch` handled, by
operation and response path; the image opened, unavailable, written with
its batch count, or failed; a field read and never fetched; a value a
reader's type cannot hold; an id naming records of several types; a
`@required(action: LOG)` field null; a deferred part dropped. Never a
record, a slot, a value, a variable or a response body. A debug build
prints the missing-data cases until a log is set. *Held by* script
`events` for a fetch's events, the commits, a field error and a dropped
part, and by script `heal` for missing and unexpected data; the image's
events, an ambiguous id and a `@required(action: LOG)` null are
*unheld*.

## 11. What is not the contract

The Swift runtime relies on these, and a second runtime need not:

- **Deallocation as an event.** A retention releases its root when it is
  deallocated, a scope's hold on a key's number ends the same way, and a
  store clears its records when it goes. The rules are: a token's end
  releases; a number is used again once nothing that could name it is
  alive; a session ends when its environment is ended. A runtime with a
  collector gives the token an explicit end and unpins at collection; it
  needs no net.
- **The clock.** The store reads a monotonic clock in memory and the wall
  clock across launches; which clocks, and how a test advances them, are
  the runtime's.
- **The observation mechanism.** One invalidation channel per slot of a
  record, made once per slot index and shared by every record, is how the
  Swift runtime makes a body depend on the fields it read and on nothing
  else. The rule is the dependency; the channel is Swift's.
- **The main thread.** Reads, commits, the check with hydration,
  collection and the normalization of an optimistic response run on the
  main thread; decoding a response and writing the image run off it. How
  a runtime confines them is its own.
- **Representations.** Integers are 64 bits wide; a change set keeps a
  string as a range of the response's bytes until it wins; a slot numbered
  by the store is a negative index; a record's dense values are one
  contiguous array. Of the representations, two reach the contract because
  they reach the dumps: the rendering of a float and the escaping of a
  string in a storage key (section 1).
