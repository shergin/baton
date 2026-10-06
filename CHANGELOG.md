# Changelog

Notable changes, written so a person can read them. Pre-1.0, breaking changes
are expected and listed without apology.

## Unreleased

- A field whose type is a list of lists, `[[Int!]!]!`, is a compile error
  at the field. The plan says of a type that it is a list or not, so such
  a field was lowered to a flat list and read wrong; the refusal stands
  until the plan carries a type that can say the depth. A fragment spread
  that reaches the normalization program, which Relay inlines, is an
  internal error rather than a silent skip.
- `RecordedTransport` and `SilentTransport` move to `BatonTesting`, a
  library product of the package for an app's tests and previews, so that
  neither ships in the app. A test or a preview that uses them adds
  `import BatonTesting`.
- The boundaries inside the runtime module are checked:
  `scripts/check-boundaries.sh`, in CI and among the local checks, holds
  the module decision's rules (one file imports SwiftUI, one imports
  SQLite, the record, the plan and the ingest do not name the store, the
  store's files do not name the environment or a transport, and the runtime
  imports nothing else) as a ratchet whose list of tolerated violations
  can only shrink. SwiftUI's part of the runtime, the environment value,
  the storages behind the marker macros and the `ForEach` initializers,
  now sits in one file.
- A custom scalar is its text: a string's contents, or the bytes of any
  other token exactly as the server wrote it, so `1.50`, an integer past
  2^53 and an object or array all read back unchanged. Before, numbers were
  rounded through `Double`, and objects and arrays were stored as null.
- Ingest errors instead of wrong values or traps: an `Int` field given a
  fraction, an exponent or a value outside `Int` fails the response with an
  `IngestError` (it wrapped, rounded, or trapped), and `Int.min` reads. A
  null inside a list of scalars is stored as a null element; it failed the
  whole response. The generated readers, typed as lists of non-optional
  values, still leave such elements out. A `\u` escape cut short by the end of a string, or a high
  surrogate followed by an escape that is not a low surrogate, reads as
  U+FFFD; the first read past the string and the second trapped.
- Storage keys are built from the arguments, not parsed from text. A
  string argument holding `$` (`price(format: "$0.00")`) was read as a
  variable, a lookup argument holding a comma was cut at it, and a list or
  input object with a variable inside was stored under its own text; an
  input object's keys were written unquoted and unsorted. Floats in keys are
  written as the runtime renders a variable. A lookup in `baton.json` whose
  argument the selection does not pass is a compile error.
- Plans know types and conditions. The normalization plan was flat: every
  field of every type condition was expected on every record, so the
  availability check failed right after an operation's own response for any
  selection on an interface or union, and the ingest bound a response key to
  the first field of that name, storing a Location's `label: dimension` in
  its `name`. The compiler now decides, for each abstract selection, the
  fields each group of concrete types reads, and turns `@include` and
  `@skip` into guards the plan settles once per set of variables; the
  ingest reads an object by its type's variant, and the check, collection
  and deferred parts follow the same variants.
- Lenses follow types and conditions. A type condition on an interface
  emitted `asNode` behind a test of the record's concrete type, so it was
  always nil; it is now tested against the set of types that satisfy it,
  emitted once in the shared file, and folds into the parent when every
  type the parent admits satisfies it. An accessor under `@include` or
  `@skip` is optional and reads nil, reporting nothing missing, when its
  condition does not select; `totalCount @include(if: $x)` read 0 and
  reported missing data. A field selected twice, or a fragment spread
  twice, emits one accessor: the file did not compile. An aliased spread
  of a fragment on an interface or union is tested against the types that
  satisfy it; it was always nil.
- A field no variables can select, such as one under `@include(if: $x)`
  and `@skip(if: $x)` at once, is fetched and read under no variables; it
  was planned as always selected, so the check waited for a field the
  server never sends. A field the initial part and a deferred one both
  select is read from the initial payload by its own selection; the
  deferred copy could come first, and the initial fields under it were
  dropped.
- One write path. Everything a batch does, field errors and deletion
  included, is in its undo log and its net notification: a failed
  optimistic write to a field no longer loses the server's error on it, an
  optimistic response that revived a deleted record no longer leaves it
  revived when it fails, and a server commit under a layer that deletes a
  record no longer fires every channel of it twice.
- A deletion is announced to the bodies that hold it. A body that read
  only a list, or a connection's `nodes`, kept a row for a record
  `@deleteRecord` removed, because the slot holding the link did not
  change; the commit that changes whether a record is deleted now notifies
  every slot that links to it, in one pass over the store (2.2 ms for a
  commit that deletes one record from 8,965 on an M1 Pro, against 7 µs
  without the pass). A read of a deleted record's field reports nothing
  missing.
- Identity is the key alone. The store indexed entities by bare id as well,
  last created wins across types, and `@deleteRecord`, `@deleteEdge` and
  lookups without a type resolved through it: in the Rick and Morty data
  `Character:1`, `Location:1` and `Episode:1` coexist, and the index named
  the episode. The index is gone. `@deleteRecord` deletes the one live
  record of any type with the id, and when several types have it deletes
  nothing and calls the new `Store.reportAmbiguousIdentity` (debug builds
  print); `@deleteEdge` drops the edges whose node has the id; a lookup
  without a type probes the field's possible types with the same rule. A
  lookup the image cannot answer no longer leaves an empty record behind.
  `Store.existing(id:)` is removed. An interface is keyed by id when the
  types that implement it have one, as a union is. An object under an
  interface or union that is keyed by its path is a record per concrete
  type; before, a payload of another type at the same path wrote its fields
  into the first type's record. The image's format moved to 2, so an image
  an earlier version wrote is discarded at the next launch.
- `baton.json` is checked: each lookup's field, argument and `type` against
  the schema, and an unknown key is an error.
- A superseded fetch does not commit. A response that arrived, or was still
  being read, after a refetch replaced its fetch landed after the newer one
  when the transport did not hear the cancellation. Ingest now runs in the
  fetch's own task, so cancellation and priority reach it. A mutation's
  request runs apart from its caller's task, and its payload commits
  whoever stopped waiting, because the server applied it; with
  `URLSessionTransport` a cancelled caller cancelled the request, and the
  payload, and an optimistic layer with it, was lost.
- `refetch()` on an operation value and on its handle is `async throws`:
  a refetch that fails throws its error, and the data on screen stays. It
  was dropped before. Breaking: a call site needs `try`.
- `phase` changes only when it changes. A fetch that changed nothing
  assigned an equal `.ready` and re-ran every body that read the phase; a
  ready handle now stays as it is, and so does a failure on the same field
  errors. A `@throwOnFieldError` or bubbling operation's phase follows any
  commit that changes a field error, a null, a link or a deletion in the
  store, not only its own fetch, and a parked one is settled again when a
  view attaches it. Both read the same errors: the operation's own
  selection's, as Relay's reader of the operation does (an error inside a
  spread is the fragment's to weigh), and those its last response carried
  that no field holds. `.networkOnly` no longer sends a handle another
  view shows back to `.loading`, nor reads the store, and the image, to
  decide. A preload's fetch serves the first attach while its data is
  fresh; the attach made a second request when the preload had finished.
- A field error under a parent the server nulled lands on that parent. The
  walk that places an error left a `switch` where it meant to stop, so an
  error at `character.origin.name` with `origin` null was stored on
  `character.name`. An error keeps its whole path, and one with no path, or
  a path that names nothing selected, is kept in
  `ChangeSet.unplacedErrors` and counts as uncaught for
  `@throwOnFieldError`; before, it was dropped.
- Generated code states its isolation: `Types`, `Slots` and every generated
  type are `nonisolated`, readers stay `@MainActor`, so a target built with
  the Xcode template's default of main-actor isolation compiles them (it
  failed on `static let plan`).
- The compiler comes with the package. A package that depends on Baton
  downloads the compiler bundle its release published, named by checksum in
  `Package.swift`; a checkout that built its own with
  `scripts/build-compiler.sh` runs that one (`BATON_COMPILER=local` or
  `release` overrides the choice). The release workflow builds the bundle
  for both Mac architectures and writes the release commit.
- A handle outlives its environment: a view that releases its handle after
  the environment is gone no longer traps; the release does nothing.
- A damaged image is a miss, never a crash. A file damaged under the open
  connection could leave a read stepping a statement already finalized; a
  row with a name id past any table, a link that names no type, or lists
  nested in lists trapped or recursed without bound. Such a row is used as
  far as it reads.
- Each slot is its own invalidation channel. A record had sixteen, so a
  body woke for a change to a field sixteen slots from one it read; on the
  query root, where each field with arguments is a slot, a screen woke for
  root fields other screens fetched (four wakes of an unrelated root-field
  reader in the bench, now none). A tracked read costs about 620 ns against
  560 on an M1 Pro; an untracked read is unchanged at 29 ns.
- A schema whose root types have other names, such as `QueryRoot` or
  `query_root`, works: the compiler interns them by the names the store's
  root records have, `Query`, `Mutation` and `Subscription`, as Relay's
  root record is a `__Root` in any schema. Before, the root fields' slots
  belonged to the schema's type and were written into a record of another.
  A schema that renames a root and also has a type of that root's store
  name, or whose renamed root implements an interface or belongs to a
  union, is an error. `Store(rootType:mutationType:subscriptionType:)` is
  removed.
- Reads never write. A lens read of a root field that was never fetched
  resolved its lookup and wrote the link, notifying, inside the body that
  read it. The availability check binds a lookup before a handle is ready,
  as it did; a lens read of a missing link now reads nil and reports it.
  The `lookup:` parameters of `Anchor.linked`, `requiredLinked` and
  `throwingLinked` are removed. See
  [the decision](docs/decisions/lookups-bind-in-the-check.md).
- Readers say what they could not read. A `required*` reader that finds a
  null reports it through the new `Store.reportUnexpected`, and one that
  finds no value reports the miss; both still return the zero value. A
  value of another kind than the reader's reads nil and is reported; it
  was nil silently. A `@required` field the store never received is
  reported missing before its lens bubbles. A non-null link without a
  record reads one placeholder per type, so the fields below it report
  nothing a second time; a record was allocated per read. A `@catch` on a
  non-null list reports a null as the other readers do.
- A field error inside a type condition, `... on Character { name }` under
  an interface, counts for `@throwOnFieldError` and `@catch` when the
  record is of the type; the lens's error scan skipped the condition.
- A `@required` link to a record `@deleteRecord` removed is null, as every
  other read of the link is: the lens bubbles, a `THROW` collects the
  error, and an operation that bubbles to its root fails. The lens read a
  blank record and the operation stayed ready.
- A connection's `nodes` builds its lenses in one pass instead of an array
  of anchors mapped into a second one: 110 µs for 2,100 nodes against 124
  µs on an M1 Pro.
- A field selected on an interface or union reads through an
  `AbstractSlot`, which resolves its key once per concrete type: 22 ns per
  untracked read against 56 ns, which took the registry's lock and hashed
  the key on every read. The `key:` readers of `Anchor` are removed.
- Keys with variables and fragment arguments are resolved once per owner,
  Relay's fragment owner: the scope a lens reads in, which a handle makes
  once and keeps. A root field with a variable argument rendered its key,
  took the registry's lock and hashed it on every read, 232 ns; it reads
  in 28 ns, against 25 ns for the untracked read of a field with a constant
  key. A spread with `@arguments` built two dictionaries per read and gave
  its child a scope that never compared equal to the last: 453 ns for the
  read and one variable of the child's scope, 45 ns now, and the spread
  alone makes its lens in 10 ns. An
  `Anchor` is a record, an owner and the record it was reached from, and
  two are equal when those are the same objects. Breaking for code that
  builds anchors: `Anchor(record:owner:parent:)` replaces the `parent:`
  form, and `binding` takes the spread's `ArgumentSite`.
- The ingest keeps the last value per field. An entity the response names
  at many paths was written once per appearance and the commit picked the
  winners on the main actor, taking the registry's lock per record; the
  ingest now groups the change set by record, one entry per slot, off the
  main actor. On an M1 Pro, a commit of the fixture's unchanged payload
  takes 152 µs against 182, a commit that changes one field 154 µs against
  185, and the ingest 2.95 ms against 2.78. Placing field errors scans the
  record's entries instead of indexing every entry.
- A commit compares a list where it is stored before building the new
  one, so a list that did not change allocates nothing: the fixture's
  unchanged payload commits in 133 µs against 152.
- A plan resolves once where it can. A handle's fetch uses the resolution
  the handle holds, a selection with no variable below it resolves once
  and keeps the result, and each field's response key bytes and fixed key
  are taken when the static plan is built. Resolving the fixture's plan for
  another page takes 0.69 µs against 8.5 µs without the kept resolutions.
- A subscription frame, an incremental part's envelope and the `errors`
  array are read by a scanner of the response bytes alone; each built the
  plan-driven cursor and its 48 scratch buffers. A 69-byte frame reads in
  375 ns against 2.21 µs.
- A small response costs what it is. The change set reserved room for
  32,768 entries whatever the response, the cursor made 48 scratch buffers
  before reading a byte, and the change set the ingest returned was copied
  on its first append. Reservations now follow the response's size, a
  buffer is made when the walk first reaches its depth, and the change set
  is built where it is filled: a 64-byte mutation payload ingests in 2.4 µs
  against 4.5 µs.
- A floating-point number is read where it lies in the response; each one
  was copied into a new array first, and a number the plan skips was
  parsed.
- A mutation's root fields are keyed without their arguments. Each
  distinct input numbered a permanent slot on `Mutation`, named by the
  input's text; now a field is keyed by its name, or by its alias when it
  has one. The store dumps under `spec/` changed accordingly. The data a
  `mutate` returns is the latest payload of its field.
- The multipart reader drops a preamble, which it returned as a first
  part, lets go of each part once its delimiter is read instead of keeping
  the whole response, and reads a part without headers. It scans the
  chunks it is given rather than a byte at a time: 978 KB of 20 parts in
  16 KB chunks parse in 0.50 ms against 14.6 ms.
- The compiler emits `Types.schemaDigest`, the MD5 of the schema's text, for
  an app to pass as its image's `version`: an image written under another
  schema is discarded. The version is the app's to pass, because generated
  constants are made on first use and nothing has made one when the file
  opens.
- A deferred fragment the image holds only half reads absent, and its
  operation fetches. A record read from the image holds every cell of its
  row, a deferred fragment's link among them, while the records behind it
  may be gone, and the check passes over deferred fields: the fragment
  read present and empty. The deferred fields are now checked apart, in
  memory and then in the image; one whose records are not whole is
  cleared, unless the initial part selects the same field, whose data
  stays, and a store-or-network attach fetches while the initial part
  renders.
- An image that lost a batch, written in vain or dropped while the file
  could not open, is discarded at the next open; it served rows older
  than memory had known, a deleted record among them.
- An edit the store cannot make in memory makes the image forget what it
  would have changed. An edge directive on a connection the store held
  only in the image was dropped, and an insert into the empty record a
  link had made wrote a connection of one edge over the image's; a
  `@deleteRecord` of a record only the image held left it there, to come
  back at the next launch. The connection, or every record with the id,
  is dropped from the image and read as missing until a response gives
  it again, so the screen fetches.
- A read of the image writes nothing first. The availability check wrote
  the writer's whole queue on the main actor before reading, and every
  launch's first reads queued stamps that the next check then wrote there.
  A batch being written lands before a read takes the file, and the
  records of a batch still queued, with those its root fields link to, are
  kept by the collector until written, so a read never meets a row older
  than memory held.
- Data read every launch keeps its age. A fetch time was kept only by the
  fetch that wrote it, so data an app read from the image at every launch
  without fetching went stale at every second launch; a launch that reads
  a fetch time now keeps it for the next.
- `Store.check` says where its answer came from: `.memory`, `.image` or
  `.miss`. A handle took the image's part from a change in a global
  counter, which missed the root's fields and records an earlier check had
  filled, so data from the image without a fetch time could read as fresh.
  `Store.hydratedRecords` is no longer public. Breaking: `check` returned a
  `Bool`.
- `removeAll()` deletes the image's file. It queued deletes that a failed
  open dropped and a failed batch rolled back, and it kept the interned
  names, which hold argument values; work queued before it is dropped
  too. A sign-out releases the old environment's handles, removes the
  image and makes a new environment over it. A store made before the
  removal reads, writes and dates nothing in the image after it, so a
  response that lands late for the user who signed out reaches neither
  the file nor the next user.
- `Persistence.close()` writes what is queued and closes the file, so a new
  image can take it over. The new image counts as a launch, though the
  process is the same: the rows the closed one wrote that it does not read
  age out a launch sooner. A sign-out keeps one image: it removes it and
  hands it to the next environment.
- Opening the image scans nothing. The rows no launch has read since the
  one before last were deleted at open, three scans the first frame
  waited for; a read now treats them as gone and the writer's first batch
  deletes them. A database of another kind at the image's path turns the
  image off for the process instead of being opened again every second.
  The generation moves once per image, not per connection, names are
  written with a plain insert, so a second connection that took an id
  fails its batch instead of renaming every row written with it, and an
  image past 65,536 names starts again.
- One `invalidate`: `Environment.invalidate()`. `Store.invalidate()`, which
  marked memory stale but left the image's fetch times, so data read back
  from the image counted as fresh, is internal and does both.
- Diagnostics point where they are. An error in the schema is positioned
  in the schema file; it printed `1:1`. Related places print as `note:`
  lines, and a message Relay writes over several lines prints on one. A
  state of Relay's programs the lowering relies on never meeting is an
  internal error at the place it was met, where it lowered into an empty
  plan.
- A linked field named `type`, `self`, `protocol` or `any` gets a nested
  lens with `Lens` after its name; it emitted `struct Type` or `struct
  Self`. A selection named or aliased `anchor` or `recordID`, which every
  lens has for itself, is a compile error at the name that asks to alias
  the field or to choose another alias.
- Generated slots are nested per type, `Slots.Character.name`; a type's
  name and a field's ran together, so `A_b.c` and `A.b_c` were both
  `Slots.A_b_c`.
- A variable named like a Swift keyword, `$where` or `$in`, is escaped in
  the operation value; it emitted `public var where`.
- A directive Baton gives no meaning to is a compile error at the
  directive, by place: `@inline`, `@relay(plural:)`, `@relay(mask: false)`,
  `@raw_response_type`, `@preloadable` and `@stream` compiled through
  Relay's transforms and did nothing, or, for `mask: false`, read unmasked
  data that Baton has no word for. A marker holds exactly one definition
  of its own kind: `@Fragment("query …")` and two fragments under one
  `@Query` compiled.
- A persisted id is the MD5 of the operation's text as the app holds it.
  The hash took the printed text with its trailing line break, which the
  emitted `text` drops, so no text the app held matched its id. The ids
  change.
- `onError` is decided at compile time: `"onError"` in `baton.json`, sent
  with every operation the target compiles. Under `NULL` the fields the
  schema types non-null are typed by their semantic nullability, so an
  accessor no longer reads `""` or `0` for a field an error nulled.
  `Environment.errorBehavior`, a switch at run time that changed what the
  compiled types meant, is removed.
- The default fetch policy is `FetchPolicy.default`, `.storeOrNetwork`, as
  Relay's queries default to: the store answers when it can. It was
  `.storeAndNetwork`, spelled in five places, so every attach of every
  screen made a request. Breaking for code that relied on that default:
  name `.storeAndNetwork`. `Environment.releaseBufferSize` is set at init
  and fixed after.
- The data a mutation returns stays readable. Nothing kept its payload
  alive, so after the next collection it read nil; the environment now
  keeps the completed mutation as a root, and its data lives until later
  mutations push it out.
- Kinds are types. An operation value conforms to `Query`, `Mutation` or
  `Subscription`, each refining `Operation`, and each API takes only its
  kind: `handle(for:)`, `preload`, `fetch` and `@Query` queries, `mutate`
  and `@Mutation` mutations, `subscriptionHandle` and `@Subscription`
  subscriptions. A `@Query` holding a mutation compiled, ran on attach and
  wrote the mutation root's slots into the query root. A subscription
  value carries its handle as a query value does; it found it in a table
  of the whole process, keyed by the value, which equal values in two
  environments shared. Breaking: `OperationKind` and `kind` are removed,
  and code generic over operations names the kind it needs.
- A subscription survives a bad event. An event with errors and no data
  ended the subscription for good; it now sets `error` and the stream goes
  on, and the next good event clears it. `retry()` opens a stream the
  server or the socket ended. A stream that a newer one replaced no longer
  closes the newer one's state when it ends. The WebSocket transport reads
  an `error` frame's GraphQL errors as the messages, where it showed the
  frame's text, and closes the socket when its last subscription ends.
- Incremental delivery reads all of the format. A part's `subPath` places
  its data below the announced path, its own `errors` land on the fields
  they name, and an announced part that `completed` with errors puts them
  on the fields it would have filled, where `@catch` reads them; all were
  skipped. A part with `hasNext: false` ends the stream, where the fetch
  waited for the connection to close. Later parts are parsed and
  normalized off the main actor, and the first part's announcements are
  read in the pass that ingests it rather than parsed a second time on
  the main actor.
- A deferred response is fetched when its stream completes, and its fetch
  time is stamped then; it was stamped at the first part, as if the whole
  response had come. A stream that breaks after the first part leaves no
  fetch time, and the deferred parts it lacks make the next store-or-network
  attach fetch again; the first part still renders at once.
- `URLSessionTransport` reads an incremental response from its data task's
  own delegate, in the chunks the loading system delivers; it iterated the
  body a byte at a time. The bench's 978 KB response reads in 1.2 ms
  against 6.1 ms.
- `@defer` in a mutation or a subscription is a compile error. It compiled,
  and the response was read as one part.
- The ingest takes a type's name once per selection rather than from the
  registry, under its lock, for every entity and path key, and reads a
  list of links into a buffer kept per depth rather than a new array per
  list.
- The compiler reads a marker qualified by the module, `@Baton.Query`,
  and raw string literals (`#"""` to `"""#`), in which only a backslash
  followed by the literal's hashes is an escape. A bare `@Query` whose
  first argument is not a string literal, such as SwiftData's
  `@Query(sort:)` or `@Query(FetchDescriptor<Item>())`, is that other macro
  and is left alone; it was an error. The other markers and `@Baton.Query`
  still want a literal. The plugin hands the compiler every file that names
  a marker.
- A `.graphql` or `.gql` file in a target writes its own output; its
  documents compiled and their lenses were never written. Outputs are named
  by the source's path in the target, so `Thing.swift` and `Thing.graphql`,
  or two files of one name in two directories, no longer write one file;
  `batonc generate --out` names them the same way. A `Baton.swift` at the
  target's root that declares GraphQL, whose output would be the shared
  `Baton.baton.swift`, is an error naming it; the shared file overwrote its
  output, or the build failed on two producers of one file. A document with
  an error writes nothing, where every output was overwritten with a stub,
  and a file holding GraphQL that no output is named for is an error.
- Each `batonc` command takes only its own options, and any other is an
  error naming the ones it takes: `--schem x` was ignored, and the schema
  then came from wherever else it could.
- The check that a marker's property is typed as its document's generated
  type finds the definition by its file and its place among the file's
  documents. It searched the document's text for the longest known name, so
  a query that spread `HomeDetail_character` was taken for the operation
  `HomeDetail`. A subscription's property typed `.Action` is now warned
  about; only a mutation's may be.
- A parked `@throwOnFieldError` or bubbling handle that was ready is
  settled again when a view attaches it. A commit made while it was parked
  that put a field error or a null into its selection left it ready; only
  a failed one was settled.
- The first part of a deferred response settles the phase by the errors
  with no path that part carried. It read the last response's, so a
  `@throwOnFieldError` operation whose first part carried one rendered
  ready until the stream completed, and stayed ready when the stream broke
  after it; one whose last response carried one stayed failed until a
  clean response completed.
- A `@throwOnFieldError` operation failed by an error with no path fetches
  again when a view attaches it under `storeOrNetwork`. No record holds
  such an error, so no commit could clear it, and the failure stayed until
  `retry()`. A failure on field errors or a `@required` null, whose data is
  in the store, goes stale as ready data does, so `invalidate()` and the
  expiration refetch it, and a refetch that fails at the transport leaves
  it as it leaves ready data; `isStale` was false for every failure.
- `Environment.fetch(_:)` of a `@throwOnFieldError` operation throws the
  field errors its handle fails on. It threw for every uncaught error the
  response placed, one inside a spread among them, so the fetch threw where
  the handle was ready.
- A stream a retry replaced leaves the new one's `error` alone. A bad
  event the old stream was still reading when `retry()` ran set its errors
  on the handle, and the new stream showed them until its first good event.
- A subscription whose transport ends its stream with a `CancellationError`
  of its own ends: `isActive` is false and the next `retain()` opens it
  again. The handle stayed active over a stream that had ended, and no
  retain could reopen it short of `retry()` or a full release.
- Completed mutations take no place in the release buffer. Each one
  took a place of its own, so ten mutations pushed out the query of a
  screen the user had left, and going back to it loaded and fetched again.
  The environment keeps them apart, one per operation value and as many as
  `releaseBufferSize`, and one pushed out is collected at once; its records
  stayed until some unrelated release scheduled a collection.
- A subscription that opens the WebSocket just after the last one closed
  it keeps its socket. The closed socket's read, failing as it closed,
  ended whichever socket was current, and the new subscription failed with
  a cancellation. Each socket's frames and end now concern that socket
  alone, a socket is not closed while a subscription is opening it or
  starting on it, and the one that opens it no longer waits for an
  acknowledgement that came, or a socket that failed, while its
  `connection_init` was on the way.
- A subscription whose reader goes away before the server acknowledges
  the connection leaves nothing behind: it stops waiting for the
  acknowledgement, and the socket closes when no other subscription is on
  it or starting. The socket stayed open with no subscription on it until a
  later one ended, and without an acknowledgement the subscription's start
  waited for good.
- A `@required(action: LOG)` field below a placeholder logs nothing. Reads
  under a placeholder report nothing, since the non-null link above it was
  reported missing, but a LOG field there still told
  `Environment.requiredFieldMissing`, naming the placeholder's key.
- Floats read as JSON writes them whatever the locale. They were read by
  the thread's locale, in place in the response, so under one with a
  decimal comma `0.25` read as 0, `[1,5]` as `[1.5, 5]`, and a response cut
  off in digits was read past its end; they are read in the C locale now,
  and never past the number the scan found.
- A deferred part the server could not deliver fails an operation the
  same however many errors it sent. Each error after the first was
  unplaced, so with two a part whose fields are all under `@catch` failed a
  `@throwOnFieldError` fetch and handle, and a spread's part failed a
  handle though the spread's fragment weighs its own errors. The errors
  count as uncaught now only when a field the part would have filled is
  under no `@catch`; a part with no field on its record's type leaves them
  all unplaced, where it dropped the first.
- A fragment on the mutation type reads the payload. Its fields kept their
  arguments in their keys while the mutation wrote them without, so a
  mutation that spread it read nil; they are keyed as the mutation's own
  root fields are.
- Of two fields whose lenses would take one name, the second is checked
  through its own lens. Its lens is numbered, `TypesLens2` beside a
  `TypesLens`, but `fieldErrors` and `satisfied` named it again without the
  number and checked the first field's lens, so a field error or a missing
  `@required` field in the second went unseen.
- A linked field named `mainActor`, `double` or `optional` gets a nested
  lens with `Lens` after its name, as `type` and `string` do. Its lens hid
  the attribute on every accessor, the `Double` a `Float` field reads as,
  or the `Optional` a caught spread is wrapped in, and the generated code
  did not compile. The names held back are every type and attribute a
  lens spells unqualified, and Swift's own.
- An edge directive's commit looks no key up by name. Each edit took the
  registry's lock and hashed `edges`, `node`, `cursor` and
  `__connection_next_edge_index` several times; it now edits the
  connection by the slots its plans resolved, which the registry keeps
  under the connection's type. A directive that names a record no
  connection field made, or inserts an edge of another type than the
  connection's edges, leaves it alone; it wrote edges into the record, or
  an edge the connection's readers read by another type's slots.
- The docs say what runs on the main actor: reads, commits, the
  availability check with its reads of the image, collection, and the
  normalization of an optimistic response. The vision, the store principle
  and the README said collection and all normalization ran off it; a
  decision record now says why they do not, with the numbers that would
  move the check and collection.
- A view's storage releases its handle as SwiftUI drops the view's state,
  on the main actor. It released it from a task started for each
  teardown, so the handle stayed retained, and a root, until the task ran.
- A request with nothing to send it fails with `EnvironmentError`, which
  says what is missing: a view's environment, a lens's, the one that made a
  handle and is gone, or a subscription transport. It failed with a
  `TransportError` whose status code was 0 and whose description read as
  an HTTP status.
- An operation whose root a `@required` field bubbled to fails with a
  `RequiredFieldError` that names it in `operationName` and says the root
  bubbled. Its path was the operation's name, so the error described a
  null field of that name.
- A preloaded operation is settled on its first attach. When the preload's
  fetch had finished with fresh data, the attach returned before reading
  the phase again, so a commit that put a field error or a null into the
  selection while the handle waited for a view left it ready.
- A deferred part the server could not deliver lists each of its errors
  once among the uncaught ones. Its first error is placed on every field
  the part would have filled, and was counted once for each such field
  under no `@catch`, so a part of two of them listed it twice.
- A spread alone under an aliased `@catch`, `... @alias(as: "x") @catch {
  ...F }`, compiles whatever the fragment's error policy and reads the
  field errors in the fragment: a failure under `RESULT`, nil under `NULL`.
  It called `F.caught`, which only a fragment with `@throwOnFieldError` had,
  so the generated code did not compile for any other fragment, and under
  `@catch(to: NULL)` such a fragment's accessor threw instead of reading
  nil.
- Every name the generated code declares comes from one allocator per
  scope, which knows the names the scope spells unqualified and the
  program's fragments and operations, and a name the document spells never
  moves. A field aliased `asCharacter` beside `... on Character` declared
  `asCharacter` and `AsCharacter` twice; the condition's accessor and lens
  take the next number, `asCharacter2` and `AsCharacter2`. A field named
  like a fragment or an operation the lens names, such as
  `testNotes_character`, got a lens that hid it; the lens takes `Lens` after
  the name. A spread's accessor named like a field takes the fragment's
  whole name. A connection's `nodes` read `Edges.Node` whatever names those
  lenses took. An optimistic builder for a payload field named `type`,
  `self`, `string` or `sendable` was `struct Type`, hid `String` or
  conformed to itself; it takes `Response` after the name. A name a scope
  would still declare twice is an internal error naming both declarations,
  where the Swift did not compile.
- A variable named `self` is a parameter, a property and a request
  variable of that name. The value's initializer, `variables` and `hash`
  read the instance itself in its place, and the generated code did not
  compile. A variable named `hasher`, or `commit` in a mutation, compiles
  too: `hash(into:)` combined its own parameter in its place, and the
  action called the parameter for its `commit`.
- A plan's edge directive is an `Edit`, as the change set's
  `ChangeSet.Edit` it becomes, so "handle" means only the operation handle.
  Breaking for a plan built by hand: `Handle` is `Edit`, `ResolvedHandle`
  is `ResolvedEdit`, the `handle` properties of `PlanField` and
  `ResolvedField` are `edit`, and `.scalar` and `.linked` take `edit:`.
- A mutation's action passes a variable named like a Swift keyword, such
  as `$self`, by its bare label: Swift warns about an escaped label at a
  call site, and a build that treats warnings as errors refused the
  generated code.
- A key rendered from variables no longer widens the records of its type.
  Each cursor and each id renders a key the process keeps, and keys were
  numbered in one sequence per type, so a field first used after a long
  session was numbered past all of them and every record given it made
  room for each. In the bench's session of 2,000 lookups and 500 pages,
  2,000 characters given such a field took 28.2 MB and 5.86 ms to commit;
  they take 1.1 MB and 1.71 ms. A key the compiler emits as a constant,
  with arguments or without, keeps its place among the type's slots; a
  record keeps the rendered keys written to it in a list of its own
  sorted by key, which a read of one searches by halves: a root field
  with a variable argument reads in 31.6 ns against 28.8 ns, and the
  newest of the session's 2,000 keys in 50.7 ns. A list of 5,000 rows,
  each holding three fields with a variable, commits in 4.76 ms against
  4.08 ms for three constants, and each row holds 96 bytes more. A key
  keeps the kind it is first met as: a constant whose text was rendered
  first, or that the image named first, is read through the search.
  `Slot.index` is negative for a rendered key, and `Registry.slotCount`
  counts both kinds.
- One image in a process holds its file. A second `Persistence` made on a
  file another holds, under any spelling of its path (`/tmp` and
  `/private/tmp`, before the file exists and after), runs without the image,
  as over a database of another kind, and stops a debug build where it is
  made; it opened a second connection, which moved the generation again and
  could fail the first's batches on a name both interned. `close()` and the
  image's end hand the file over; a closed image whose file another has
  taken reads, writes and removes nothing there.
- `RecordedTransport.requests` is read under the lock `execute` appends
  under. It was read without it, so reading it while a request arrived
  off the main actor was a data race.
- A `TransportError` with no response behind it, from a WebSocket that
  closed under a subscription or a `RecordedTransport` with nothing
  recorded for the operation, describes itself by what went wrong; it
  read `HTTP 0: ...`. Its `statusCode` is still 0, now documented as no
  response.
- `isRefreshing` is true while an operation that failed on field errors or a
  `@required` null, with its data in the store, fetches again, and `retry()`
  leaves such a failure in place, its data visible, as `refetch()` does.
  `isRefreshing` was set only behind ready data, so a view showing that data
  and the failure did not see the refetch; `retry()` showed loading over the
  data, and when its fetch failed at the transport the failure became the
  transport's, which no later commit could clear. A handle that shows
  loading is not refreshing: a `networkOnly` view that attached while a
  refetch behind ready data was in flight, and a fetch started behind it,
  kept `isRefreshing` true over a screen that showed nothing.
- A name the document chose that the generated code needs is an error at
  that name, which says what it clashes with and asks for an alias or a
  rename: a variable named `variables`, or `resolution` in a query or a
  subscription; a mutation's payload field named `variable`, which its
  optimistic builder declares; an inline fragment `@alias(as:)` names
  `anchor` or `recordID`, which every lens has; a field named or aliased
  `hasNext`, `hasPrevious`, `isLoadingNext`, `isLoadingPrevious`,
  `connectionID` or `nodes` in a connection; and a fragment or operation
  named `Types`, `Slots` or `Baton`, a refetch query among them. Each was an
  internal error without a position that asked to report it, and a fragment
  named `Baton` hid the runtime's module from the generated code. A fragment
  or operation named `Swift`, `Self` or `Any`, or like a standard library
  name the generated code spells (`String`, `Int`, `Double`, `Bool`,
  `Optional`, `Result`, `MainActor`, `Hasher` or `Sendable`), is such an
  error too: it hid that name from the whole module, and the generated code
  did not compile. So is a field named `Types`, `Slots`, `AbstractSlots` or
  `Sites` where its lens, or a lens nested in it, reads through that shared
  enum, which the field's accessor hid; a variable named `Baton`, `Types` or
  `Slots`, or `AbstractSlots` or `Sites` where the operation's lenses read
  through them, which the variable hid from the operation's code; and a
  mutation's variable named `optimistic`, which its action takes as a
  parameter of its own. A clash between two names the compiler chose stays
  an internal error.
- A field named `Baton` compiles in any lens. A lens under `@catch` or
  `@throwOnFieldError`, a refetchable fragment's and a connection's named
  the runtime's module in expressions, which the field's accessor hid; a
  lens now names it only in types.
- An operation's `text` is a raw literal delimited by one `#` more than the
  longest run of them in the text. A document in a raw literal of two or
  more hashes can hold `\#`, as in `search(name: "\\#1")`, which the
  literal of one hash read as an escape, and the generated code did not
  compile.
- A schema type named `Baton`, `Type`, `Protocol` or `Any` is `Baton_`,
  `Type_`, `Protocol_` or `Any_` in `Types`, at its constant and at every
  reference, as in `Slots`, where a field named `Any` is `Any_` too.
  `Baton` referred to itself in its own initializer and hid the runtime's
  module from the other constants, Swift read `Types.Type` and
  `Types.Protocol` as metatypes, and Swift lets no member be named `Any`,
  so the shared file did not compile. A field or a variable named `Any` is
  escaped where the generated code declares it, as `Type` is. The shared
  file's sets of types are `Swift.Set`, which a type of the module named
  `Set` no longer hides.
- The `RequiredFieldError` of a root that a `@required` field bubbled to
  has the path of that field, the first required field that is null, as
  `character.origin`, and says it: "TestRequiredOrigin: the @required field
  character.origin is null and bubbled to the root". The generated root
  lens, and each lens its check recurses into, has `missingRequiredField`,
  which `Lens` declares and which reads and reports what `satisfied` does;
  `satisfied` is unchanged.
- The store's writes, the ingest and the store's counters belong to the
  package, not to an app: `Store.commit`, `commit(_:replacingOptimistic:)`,
  `applyOptimistic`, `revertOptimistic`, the availability check `check`,
  `optimisticLayers`, `existing`, `invalidationEpoch`, the root records
  and their keys, `ChangeSet`, `Ingest`, the resolved plan
  (`Plan.resolve`, `ResolvedSelection` and its parts), `Store.count`,
  `Environment.collections`, `rootCount`, `unconfigured` and `resolve`,
  the handles' `retainCount`, `MutationState` and the storage-key
  renderings of `Variable` and `Variables` are `package`. The tests and
  benchmarks reach them; an app writes through operations and reads
  through lenses. Breaking for code that committed or ingested by hand.
- The interface generated code calls is SPI, and generated files open with
  `@_spi(Generated) import Baton`. `Anchor`, `Owner`, `Registry`,
  `AbstractSlot`, `DynamicKey`, `ArgumentSite`, the plan types, the
  numbers inside `TypeID` and `Slot`, `Record.read`, `error` and `is`, and
  `Lens`'s `anchor`, `init(anchor:)` and static checks are
  `@_spi(Generated)`, as are an operation's `plan` and its flags; a lens's
  `anchor`, `init(anchor:)`, `connection` and `refetchable` are generated
  as SPI too. An app reads through accessors and cannot rebuild one
  fragment's lens as another's from another module. The `anchor`,
  `init(anchor:)` and `plan` that batonc generates for every lens and
  operation default to a trap, so Baton builds with library evolution, as
  a framework built for distribution builds it; a lens or an operation
  written by hand that leaves them out compiles and traps where it is
  read. `Slot.storageKey` and `TypeID.name` stay public: the store's
  reports hand an app a slot and a record. Breaking for code that read a
  record, built an anchor or a lens, or named a plan: it needs
  `@_spi(Generated) import Baton`, as the tests and benchmarks have.
- A mutation's payload field named or aliased `Baton` compiles. Its
  optimistic builder wrote each scalar as `Baton.Variable(value)`, which
  the field's property hid in the builder and in every builder nested in
  it; a builder now names the runtime's module only in types and writes a
  scalar as `.init(value)`.
- A spread's accessor compiles where a member is named like its fragment:
  a field aliased like the fragment it is spread beside, as
  `TestRow_character: name ...TestRow_character`, a variable of the
  operation, or the accessor itself, which a fragment named in lower case,
  as `fragment row`, gives its name. The accessor spelled the fragment in
  expressions, as `row(anchor: anchor)` and `row.satisfied(anchor)`, which
  the member hid; it now builds the lens as `.init(anchor:)` and calls the
  fragment's checks through a local alias of its type.
- `refetch()`, and a connection's `loadNext` and `loadPrevious`, compile
  where a field is named like the fragment or its refetch query, in the
  fragment's lens or in the connection's. They named both in expressions,
  as `anchor.refetch(TestNotesPaginationQuery.self,
  TestNotes_character.refetchable)`, which the field hid; `refetch()` now
  reads the descriptor as `Self.refetchable`, and the query, and in a
  connection the fragment, are named through local aliases of their
  types.
- A mutation's payload field that is a list of floats or of booleans
  compiles in its optimistic builder, and so does a variable of either
  list type: `Variable` has initializers from `[Double]?` and `[Bool]?`.
  With those from `[String]?`, which lists of strings, IDs, enums and
  custom scalars take, and from `[Int]?`, every list of scalars a builder
  or a variable writes has one.
- A variable that is a list of input objects, such as
  `$filters: [FilterCharacter!]!`, compiles: `Variable` has an initializer
  from a list of variables, which the operation value's `variables` calls.
- A spread that binds sixteen or more of a fragment's arguments compiles,
  and so does the refetch query of a fragment that declares as many. The
  closure that binds them returned a dictionary whose type Swift inferred
  from the literal, which took twice as long with each argument, and Swift
  gave up on it at sixteen; the closure now states its type.
- A spread argument that is a list or an input object holding a variable
  beside a constant, as `@arguments(ids: [$id, "2"])`, compiles. The
  binding defaulted every item to null, `.string("2") ?? .null`, which
  Swift warns about, and a build that treats warnings as errors refused the
  generated code; only a variable, which the scope may lack, is defaulted.
- A field, a selection, an argument or a variable named `rethrows`,
  `fallthrough`, `precedencegroup` or `_` is escaped as Swift's other
  keywords are; the generated code declared `public var rethrows` and
  `var _`, which Swift refuses. A mutation's action passes a variable
  named `$_` by an escaped label, since Swift reads a bare `_:` as no label.
- A variable, or a field of a mutation's payload, named `await` compiles.
  Its value was read bare, as in `self.await = await` and `if let await`,
  where Swift reads the keyword; it is escaped wherever it is declared or
  read.
- A mutation's variable named `$var` or `$let` compiles in a build that
  treats warnings as errors. Its action passed it by an escaped label,
  which Swift, 6.2 as much as 6.3, warns needs no backticks; at a call site
  only `inout` and `_` take them.
- A variable named `hashValue`, or `phase`, `isRefreshing` or `isStale` in
  a query, a refetchable fragment's arguments among them, or `subscription`
  in a subscription, is an error at the variable that asks to rename it.
  Each became a property of the value that took the place of the one the
  runtime gives every such value: `isStale` read the variable where a view
  meant the handle's state, without a word when both were `Bool`, and
  `hashValue` stood beside `Hashable`'s, so the generated code did not
  compile. Swift tells `refetch()` and `retry()` from a property by the
  call, so variables of those names still compile.
- A mutation's payload field named `fields` compiles. Its optimistic
  builder collected the response in a local `fields`, which `if let fields`
  hid; the local takes a name none of the builder's fields binds,
  `fields2`.
- A field or a variable named `Self` compiles beside `@throwOnFieldError`
  and `@catch`. The `caught` check they give a lens built the lens as
  `Self(anchor:)`, which the member hid from that lens and from every lens
  nested in it; it builds it as `.init(anchor:)`. Where a body still
  reaches a lens's own static member through `Self`, as a refetchable
  fragment's `refetch()` and a connection's members do, a field named
  `Self` in that lens or in one around it, or a variable of that name, is
  an error at the name.
- A fragment, a query, a subscription or a refetch query named like a
  Swift keyword, as `fragment class` or `@refetchable(queryName: "each")`,
  compiles. Its name was written bare wherever it stood for a type,
  `public struct class` or `typealias Query = each`; a type a document
  names is escaped wherever the generated code spells it, as a property
  is.
- A mutation named like a Swift keyword, or like what its action declares
  or calls (`Op`, `callAsFunction`, `commit` or `optimistic`), compiles,
  and so does a mutation with a variable named like it, as
  `mutation Favorite($Favorite: ID!)`. The action extended
  `MutationAction where Op == Favorite` and spelled the mutation in its
  signature and its call, `Favorite(Favorite: Favorite)`, where the
  parameter, the action's own members or its type parameter took the
  name's place. It extends `Favorite.Action`, so the mutation is named
  once, where only types are looked up, and its body writes `Op.Data` and
  `self.commit(.init(Favorite: Favorite))`.
- The spread of a fragment named from an underscore, as `..._hidden`,
  compiles. Its accessor took the owner's prefix before the first
  underscore, which is empty, and declared `var : _hidden`; it takes the
  fragment's whole name, `_hidden`.
- A fragment named `Data` is an error at its name where an operation
  spreads it, and so is one named `Action` or `OptimisticResponse` where a
  mutation does. Inside the operation value those names are its own types,
  so the spread's accessor read the fragment as the operation's root lens,
  which compiled and returned the wrong lens, or as the mutation's action
  or builder, which did not compile.

## 0.6.0 (Anchor Leg) — 2026-10-03

The store outlives the process: an image on disk, written behind every
commit, that a launch renders from before the network answers.

- Persistence. `Persistence(url:)`, or `Persistence(name:)` for a file in the
  caches directory, handed to `Store(persistence:)` or to
  `Environment(url:headers:subscriptions:persistence:)`. The image is one
  SQLite file through the system's library: a row per record (flags, the
  type, then a cell per field: storage key, a tagged value, the field's error
  if it has one), the query root a row per field, and type names and storage
  keys interned by name, because slot numbers belong to a process. A commit
  of server data hands the records it changed to a writer, at the cost of an
  array retain each on the main actor; encoding and the transaction run off
  it. What a commit writes under optimistic layers is the server's values:
  a layer never reaches the image, nor do the mutation and subscription
  roots, a connection's loading flags, or the link a lookup wrote back.
- Hydration. The availability check answers from memory first, as before, at
  the cost it had. When memory cannot answer and the store has an image, the
  same walk runs again holding the image's connection in one read
  transaction: a record that lacks a field reads its row once and fills the
  slots it lacks, a missing root field reads its own row, a link to a record
  the collector swept is pointed at the live record of that key, a deleted
  record comes back deleted, and a connection's client record comes back
  with its merged pages. So an operation an earlier launch fetched is
  `.ready` when its handle is made, before the first body, and a screen the
  release buffer let go is read back instead of refetched. Memory wins
  wherever it holds a value. A lookup is satisfied by an entity only the
  image holds, when the lookup names its type. `Store.hydratedRecords`
  counts the rows read.
- Age survives a launch. The image stores when each operation last committed
  a response; a handle whose data is complete and that has not fetched takes
  its age from there, so `isStale`, `queryCacheExpiration` and
  `storeOrNetwork` mean after a launch what they meant before it. Data that
  had to be read from the image and has no fetch time is stale.
  `Environment.invalidate()` forgets the stored times, so an invalidation
  outlives the launch.
- Unreadable is a miss. An image of another format, an image written under
  another `version` (the app's own cache version, for a release whose schema
  gives a field another type), a corrupt file and a file over `sizeLimit`
  (64 MB unless told otherwise) are deleted and started again; a row that
  does not decode is used as far as it reads. A database that is not an image
  is left alone and the store runs without one. A file that cannot be opened
  for any other reason, a device still locked among them, is tried again on
  the next use.
- Lifetime by generation. Every row carries the launch that last wrote or
  read it; at launch, rows no launch has touched since the one before last
  are deleted. A record survives one whole launch unread, and no longer.
- `Persistence.removeAll()` empties the image for a sign-out; `flush()` waits
  for what was committed to be written, for tests and for an app about to be
  suspended.
- The Rick and Morty sample keeps its store on disk: quit and launch again,
  and the list is on screen before the request returns.
- A record's `type`, `key` and `entityID` are `nonisolated`, `entityID` is
  immutable, and `Value` is `Sendable`: another thread may hold a record and
  read its identity.
- The benchmark runs itself as a new process to time a launch, and the
  release's numbers are in `BENCHMARKS.md`: 898 records are in the store
  1.8 ms after their handle asks when the file opened off the main actor,
  under 5 ms when the main actor had to wait for the open. A Mac, not a
  phone.
- Known limits. A record a response writes before the image was asked for it
  replaces its row, so fields only the image held are lost and fetched again
  when a screen needs them. The image is bounded by generations and by
  `sizeLimit` at launch, not by a size-ordered eviction. Reads from the image
  happen on the main actor, inside the check; a read that lands behind a
  write waits for it. One process uses an image.
- Fixed: an entity whose `id` arrives after a linked field is keyed by its
  id. Relay prints the `id` it adds to a selection last and a server answers
  in that order, so the ingest had settled such an object on a path key
  before the `id` came: a second record for the entity, apart from the one
  every other operation writes. In the Rick and Morty sample the detail's
  episodes query moved the root link to that record, and the header read
  missing data until its own response arrived. The ingest now finds the `id`
  and the `__typename` ahead of the first child, in any order; the look ahead
  runs only for an object whose identity follows a link. Two recorded
  responses with the `id` last join `spec/rickandmorty`, and the tests read
  them through the detail's lenses over the list's records.
- Fixed: a refetch or retry during a fetch no longer loses the handle's
  fetch. The superseded fetch used to clear the handle's task and
  `isRefreshing` as it ended, so `isRefreshing` read false with a request in
  flight, `settle()` returned early, the next attach started a duplicate
  request, and eviction could not cancel the live one. A fetch cancelled
  with an error of its own (URLSession reports the cancellation as one)
  could also put a loading handle in `.failed`. A cancelled fetch now leaves
  the handle to whoever cancelled it.
- Fixed: a subscription value's handle is dropped when its last owner
  releases it. `@Subscription` storage used to list the handle on every body
  and nothing took it off, so each subscription value an app ever showed
  kept its handle for the life of the process. The handle now lists itself
  on `retain()` and leaves on the last `release()`, so `subscription` also
  answers for an owner that is not a view.
- Fixed: `GraphQLTransportWebSocket` gives every stream a subscription id of
  its own. It used to look up the subscription to end by operation name and
  variables, so with two equal subscriptions on one socket the end of one
  completed the other, which received nothing more and never finished. The
  transport has its first test over a real socket: the test target runs a
  `graphql-transport-ws` server on the loopback interface.
- The Rick and Morty sample's `baton.json` sits beside the sample, like every
  other target's. The package root has none, so a target without its own
  gets the plugin's warning instead of the sample's schema.
- The Swift emitter has golden tests. `cargo test` compiles the documents of
  the Swift test target as the build plugin does and compares the generated
  files byte for byte with `compiler/src/tests/goldens`, and compiles them
  twice to hold the output deterministic. A change to the emitter or to a
  test document now arrives with its diff of generated code;
  `BATON_BLESS=1 cargo test` rewrites the goldens.
- Continuous integration. A GitHub Actions workflow runs the gates on every
  push to `main` and every pull request: the compiler's `cargo fmt --check`,
  `cargo clippy -D warnings` and `cargo test` on Linux; the package on
  macOS 26 with the current Xcode, every target with warnings as errors, the
  tests in debug and in release, and the library built for iOS; and the
  tests again on Xcode 26.0, the declared floor. The Swift jobs build the
  compiler from the checkout first.

## 0.5.0 (Baton Pass) — 2026-10-03

Honest data on the wire: field errors stored beside their fields, Relay's
error directives in Swift's terms, `@defer` over the incremental formats, and
subscriptions.

- Field errors. The ingest reads a response's `errors`, resolves each `path`
  through the plan to the record and slot it names, and the commit stores the
  error beside the field; a payload that answers the field clears it, and
  either change notifies the field. A plain accessor reads an errored field
  as null, as before; `@catch` reads the error; a cached read sees what the
  network read saw. A response with `data: null` and errors fails the fetch
  with `GraphQLErrors`; errors whose path leads nowhere in the plan are dropped.
- `@required(action:)`. A required field reads non-optional. NONE and LOG
  bubble at the lens boundary, as Relay nulls the enclosing object: the
  accessor that produces a lens (a linked field, a spread, a list element, a
  connection node) produces nil when a required field in it is null, through
  a generated `satisfied`; LOG also reports the path through
  `Environment.requiredFieldMissing`. THROW makes the field's own accessor
  `get throws`, raising `RequiredFieldError`. A root whose required fields
  bubble fails the operation, since there is no null data.
- `@catch(to:)`. RESULT makes the accessor a `Result<T, FieldErrors>` whose
  failure holds the field's error and every error below it, THROW-required
  nulls included; NULL keeps the optional type and reads errors as null.
- `@throwOnFieldError`. On a fragment, the spread accessor is `get throws`
  and throws `FieldErrors` for an uncaught error inside; on an operation, an
  uncaught field error puts the handle in `.failed(FieldErrors)` with the
  data in the store regardless. Under either, and inside `@catch`,
  `@semanticNonNull` fields read non-optional, as Relay types them.
- `Environment.errorBehavior` sends the `onError` request parameter
  (`PROPAGATE`, `NULL`, `ABORT`) when set.
- `@defer`. An operation with a deferred spread asks for `multipart/mixed`
  and reads the parts as they arrive: the first commits and renders, each
  later part is normalized at the record its path names with the fields its
  label marks, and the availability check does not wait for deferred fields.
  Three shapes are read: the June 2023 `incremental[{data, path, label}]`,
  the 2024 `pending`/`incremental[{id, data}]`/`completed`, and Relay's
  `{data, path, label}` per part. A deferred spread's accessor is nil until
  the fragment's fields are present. The schema has to declare `@defer`; a
  server without it gets Relay's "Unknown directive", which is the truth.
- Subscriptions. `@Subscription("…") var live: NoteAddedSubscription` expands
  like `@Query`: the storage subscribes while the view lives and closes the
  stream when it goes; the handle exposes `events`, `latest`, `error` and
  `isActive`. Every event is normalized at `client:root:subscription` and
  committed, so its entities merge and edge directives on a subscription
  payload work. `GraphQLTransportWebSocket` speaks `graphql-transport-ws` over
  `URLSessionWebSocketTask`; `SubscriptionTransport` is the protocol behind
  it, passed as `Environment(transport:subscriptions:)`.
- `Transport.stream(_:)`, with a default that answers once;
  `MultipartParser` splits `multipart/mixed` bodies however the bytes arrive.
- The GitHub sample: `@catch` on the repository lookup shows the server's
  reason for a missing repository; issue rows require an author with
  `@required(action: LOG)`, so an issue without one is no row.

Tests: field errors land beside the field and a plain read, a `@catch` read, a
`@catch(to: NULL)` read and a cached read each see what they should; a
payload that answers an errored field clears the error and notifies; NONE
drops the list element, LOG reports the path, THROW throws at the read;
`@throwOnFieldError` throws at the spread and fails the operation while a
caught error does not; a semantic field reads non-optional; a response with
errors and no data fails with the messages; `onError` is sent; a deferred
fragment is absent after the first part and present after the second in both
incremental formats; a subscription's events commit and append through
`@appendEdge` and the stream closes on release; the multipart parser splits
parts at any chunking. The bench measures a payload with twenty field errors
and the cost of a `@catch` read and a `satisfied` check.

Deliberately not added: `@stream`; operation-level `@catch` (accepted, no
effect; `@throwOnFieldError` is the operation's policy); reconnection and
retry for the WebSocket transport beyond a clean error; `extensions` on
field errors; a sample screen for `@defer` or subscriptions, because neither
public API supports them (both ship on fixtures); the missing-data heal (a
refetch of the owning operation), still planned.

## 0.4.0 (Hand-off) — 2026-10-03

Lists: Relay's connections with pagination, fragment arguments, `@alias(as:)`,
and the declarative edge directives.

- Connections. A field with `@connection(key:)` is read through Relay's
  handle key. The page lands under its server storage key as always; the
  commit then merges it into a connection record keyed by Relay's connection
  id (`<parent>:__<key>_connection(filters)`), as `ConnectionHandler.update`
  does: a page fetched without a cursor becomes the connection, one fetched
  after a cursor appends, one fetched before a cursor prepends, edges
  deduplicate by node, `pageInfo` merges per direction, and a page after a
  cursor that is no longer the end is ignored. The lens over the field
  exposes `nodes`, `hasNext`, `hasPrevious`, `isLoadingNext`,
  `isLoadingPrevious` and `connectionID`; the loading flags are client fields
  on the connection record. Roots mark through the connection as well as
  through the page they fetched, so merged pages live as long as any root
  reaches the connection, whatever fetched them.
- Pagination. A fragment with `@refetchable(queryName:)` whose connection
  takes `first`/`after` from `@argumentDefinitions` gets `loadNext(_:)` on the
  connection lens (`loadPrevious(_:)` for `last`/`before`): the generated
  query runs with the lens's variables, the merged end cursor and the owner's
  id, as a fetch with no handle and no root; the count defaults to the
  argument's default. Every `@refetchable` fragment lens has `refetch()`.
- Fragment arguments. A spread binds the target's `@argumentDefinitions`
  into the child lens's scope over the parent's variables: the passed literal
  or variable, else the default, else null (Relay's fragment variables). A
  storage key with a fragment variable resolves against that scope; the
  normalization and the operation text have the arguments inlined, by Relay.
- Edge directives. `@appendEdge`/`@prependEdge(connections:)`,
  `@appendNode`/`@prependNode(connections:, edgeTypeName:)`,
  `@deleteEdge(connections:)` and `@deleteRecord` become edits the ingest
  records in the change set and the store applies after the entries, under
  the same transaction and undo log, so an optimistic insert shows at once,
  rebases under commits and reverts on failure. `connections` is a variable
  of connection ids (`comments.connectionID`). Inserted edges are copied into
  records the connection owns, numbered by Relay's
  `__connection_next_edge_index`, because a payload's edge record is keyed by
  its path and the next mutation would alias it. A deleted record reads as
  null through links, is skipped by lists and `nodes`, and tells every
  observer; a payload that names it again revives it.
- `@alias(as:)` names the accessor verbatim, for spreads and inline fragments;
  without `as:` the derived names stay.
- Records size their values by what is written, not by the type's slot
  count: a cursor-paginated field registers a storage key per page on its
  parent type, and the other records of that type no longer pay for pages
  they never saw. The scroll bench's footprint fell from +6.5 MB to +4.4 MB.
- `Environment.fetch(_:variables:)` fetches an operation by type without a
  handle. `Anchor` keeps the record it was reached from and binds scopes with
  `binding(_:)`. `ForEach` takes an array of lenses, for `nodes`.
- The GitHub sample: open issues as an infinite-scroll connection on the
  repository screen; comments as a connection with "load more"; the comment
  composer appends through `@appendEdge` instead of refetching the issue; the
  issue screen's spread is aliased. All four read operations were checked
  against the live API.
- The compiler's property-type check takes the longest matching document
  name, so `TestAddNoteFirst.Action` no longer warns about `TestAddNote`.

Tests: two pages merge in order with the last page's info and a stale page is
ignored; a refetch of the first page replaces the merged list and an equal
page notifies nothing; `loadNext` fetches after the end cursor, appends,
toggles `isLoadingNext`, is a no-op at the end and creates no root;
`@appendEdge` and `@prependEdge` insert once per node; an optimistic edge
shows at once, survives a page under it, is replaced by the server's edge and
reverts on failure; `@deleteEdge` removes the edge and `@deleteRecord` makes
the record read as null; `@arguments` binds the scope and defaults apply;
`@alias(as:)` renames. The bench merges 42 pages of 50 notes into one
connection.

Deliberately not added: `@stream_connection` and `prefetchable_pagination`;
refetch with new variables (replace the lens; watch list); null arguments in
storage keys (Relay omits them, Baton renders `null`; both sides agree, and
the format is internal until persistence); page-based lists (watch list);
`@required`, `@catch` and `@defer` (0.5).

## 0.3.0 (Exchange Zone) — 2026-10-03

The write side: mutations as action values, optimistic responses as layers
that rebase under every commit, abstract types, lookups by id, and a second
sample against GitHub's API.

- Mutations. `@Mutation("…") var star: StarMutation.Action` expands to an
  action value after SwiftUI's `dismiss` and `openURL`: the compiler generates
  `callAsFunction` with one labelled parameter per variable plus
  `optimistic:`; it is `async throws`, returns the mutation's data lens, and
  `isInFlight` is observable. Mutation payloads root at
  `client:root:mutation`; the entities inside merge into their records as
  always, so a view reading a repository re-renders when a star mutation
  answers.
- Optimistic responses. The compiler generates an `OptimisticResponse`
  builder tree per mutation (every field optional, memberwise initializers).
  It renders to JSON and goes through the same ingest and plan as a server
  response, so optimistic data obeys the oracle rule and masking. The store
  keeps optimistic layers with undo logs; a commit while layers exist lifts
  them, applies the payload, re-applies them, and notifies only slots whose
  value differs in the end. The server's answer replaces its layer in one
  batch; a failure reverts it and the error is rethrown.
- Abstract types. Selections on interfaces and unions key each object by
  the payload's `__typename` (the compiler adds it to every abstract
  selection; the ingest settles the key when the typename arrives, before or
  after the id). Lenses read such selections through the record's concrete
  type; `asRepository`-style accessors and conditional spreads work. Relay's
  rule applies unchanged: a spread inside an inline fragment on an abstract
  selection needs `@alias`.
- Lookups by id across types. A lookup without a `type` (`Query.node`)
  resolves through an id index the store keeps for every entity, so
  `node(id:)` renders from the store for anything a list already fetched.
- Per-target `baton.json`: read from the target's directory first, then the
  package root, so one package holds the Rick and Morty sample, the GitHub
  sample, the tests and the benchmarks against three schemas.
- The GitHub sample (`examples/GitHubTriage`,
  `GITHUB_TOKEN=$(gh auth token) swift run GitHubTriage`): the viewer's
  assigned and authored issues and pull requests over the `SearchResultItem`
  union, a repository screen with an optimistic star toggle, an issue screen
  with comments and reactions and a comment composer. Its schema has about
  1,800 definitions and compiles in 35 ms.
- The compiler renders constant arguments in storage keys as JSON, as
  Relay's `formatStorageKey` does (`issues(states:"OPEN")`), and escapes them
  in generated Swift; it accepts `<Operation>.Action` and module-qualified
  property types.
- `TransportError` has a public initializer, for transports and tests.

Tests: an optimistic response shows at once and is reverted when the server
fails; the server's answer replaces the layer in one batch and the mutation
returns its data; a server payload commits under a live layer and the layer
stays on top until it resolves; resolving or reverting a layer notifies only
the slots whose value differs in the end; objects behind a union are keyed by
their concrete type in either typename order; `node(id:)` finds a cached
entity by id across types.

Deliberately not added: the declarative edge directives (`@appendEdge`,
`@prependEdge`, `@deleteEdge`, `@deleteRecord`), which ship with
`@connection` in 0.4; imperative updaters; `@alias(as:)` renaming (the
directive is accepted, the accessor keeps its default name); typed input
objects (variables of input-object type are still `Baton.Variable`); a
mutation queue or offline retry (never, see the non-goals).

## 0.2.0 (First Leg) — 2026-10-02

Lifetime: the store now forgets, on purpose and on Relay's terms.

- Retained roots. A `@Query` storage retains its handle while the view lives
  and releases it when SwiftUI drops the view's state. Released handles wait
  in a release buffer (`Environment.releaseBufferSize`, default 10, oldest
  out first); retained and buffered handles are the roots that keep records
  alive.
- Collection. Mark and sweep over the roots' plans, coalesced into one pass
  per batch of releases; swept records are cleared so cycles break, and the
  root's links to them are dropped. `Environment.collect()` runs it on demand.
- Fetch policies, as `@Query("…", fetchPolicy:)`: `storeOrNetwork`,
  `storeAndNetwork` (the default), `networkOnly`, `storeOnly`. A `storeOnly`
  operation without data fails with `MissingDataError`.
- Staleness. `Environment.invalidate()` marks everything stale and refetches
  retained handles while their data stays visible; `queryCacheExpiration`
  does the same by age; `isStale` on every operation value.
- Preload parks a fetching handle in the buffer; a view attaching within the
  window finds the request in flight or the data present. Equal operation
  values share one handle and never fetch twice at once; `settle()` awaits
  the fetch in flight.
- `RecordedTransport` takes a responder closure, for tests and benchmarks that
  serve many pages.
- The compiler's scanner skips attribute arguments after the GraphQL literal.

Tests: re-entry within the buffer makes no request and eviction does;
collection removes unreachable records and keeps shared ones; each policy's
first-attach behaviour; invalidation and expiration refetch; preload. The
bench scrolls 42 synthetic pages through a buffer of 10 and reports records,
roots and footprint per page, plus the cost of a collection pass.

Deliberately not added: field-level invalidation, off-main marking, a
collection budget per pass, `holdGC` for optimistic updates (0.3).

## 0.1.0 (Starting Blocks) — 2026-10-02

The vertical spine: one query through every layer, done properly, against the
public Rick and Morty API.

- The compiler (`batonc`, Rust): finds `@Fragment`, `@Query`, `@Mutation` and
  `@Subscription` literals in Swift sources and accepts `.graphql` files;
  validates against the schema with Relay's front end (`graphql-syntax`,
  `schema`, `graphql-ir`, `relay-transforms` at v21.0.1, pinned); reports
  errors at the exact character inside the Swift string literal; emits a lens
  struct per fragment and operation (one line per field), an operation value
  per query with its text, persisted id and normalization plan as static
  data, and a per-target `Baton.baton.swift` of interned types and slots.
  Lookups in `baton.json` let a root field such as `character(id:)` be
  satisfied by a cached entity.
- The runtime (`Baton`, Swift): a `Registry` of interned types and storage
  keys; `Record` objects that drive Observation through sixteen invalidation
  channels so a body re-runs only when a field it read changes; a main-actor
  `Store` with synchronous reads, atomic commits that compare before they
  allocate or notify, and an availability check; a plan-driven `Ingest` that
  decodes response bytes into an arena change set in one pass; a
  `URLSessionTransport`; an `Environment` injected as `\.baton`; operation
  values that resolve to an `OperationHandle` with a synchronous `Phase`.
- The SwiftUI surface: `@Fragment` and `@Query` marker macros (`@Query` is an
  accessor-plus-peer macro over `OperationStorage`, so a parent passes
  variables and a body reads the resolved handle), `Baton.List` with a
  `ForEach` overload keyed by record identity, `phase`, `isRefreshing`,
  `refetch()` and `retry()` on every operation value.
- The build plugin: one `batonc generate` per target with one declared output
  per Swift file that embeds GraphQL plus the shared slots file; outputs are
  rewritten only when their content changed.
- The sample (`examples/RickAndMorty`, `swift run RickAndMorty`): characters,
  character detail, episode and location screens over one store, with the
  list prefetching the detail header so a detail renders from the store in
  its first body.
- Tests prove the two claims the release exists for: a character already in
  the store renders in the first body of its detail (through a lookup, with
  the network silent), and a commit that changes one field invalidates
  exactly one row. The response is the oracle: lens reads of the fixture
  agree with the raw JSON field for field.
- Benchmarks (`swift run -c release BatonBenchmarks`) and `BENCHMARKS.md` with
  the first recorded numbers, including the comparison with Apollo iOS 2.4 on
  the same fixture.

Deliberately not added: mutations, pagination, retention and garbage
collection, persistence, `@defer`, abstract types, `@required`/`@catch`,
enums as Swift enums (they read as `String` for now), and lists of nullable
items (null items are dropped). Each has its release on the ladder.

Known shortcuts, honest about them: a detail screen that needs more than the
list prefetched is two operations rather than one with `@defer`; variables of
input-object type are passed as `Baton.Variable`; the fetch policy is
store-and-network only.
