# The small lies a client tells

GraphQL clients lie in small ways that compound. They type every field
nullable because any field can fail, so product code handles permutations that
never happen. They hide a field error behind a `null` and the view shows an
empty label. They return nothing for data a related write made disappear, and
the first `.count` crashes. They serve a cached value as if it were fresh, and
a product team routes around the cache with mutations, as Netflix wrote it did
([Unlocking dynamic
pages](https://netflixtechblog.com/unlocking-dynamic-pages-the-evolution-of-netflixs-client-server-graphql-apis-8b4631a59b39),
2025). Relay spent its eighteenth release fixing the first two with `@catch`,
`@throwOnFieldError` and semantic nullability. The opposite failure is a
client that crashes on any imperfection, which SwiftData's invalidated-model
trap stands for. Baton's rule is one sentence: data is what the schema says,
and what the schema cannot say is a value a view can read, never a surprise it
cannot. This page is the list of lies and the mechanism that refuses each.

## The first lie: every field is optional

Types follow the schema. A non-null field is a non-optional property; a
nullable one is optional. `title` on GitHub's `Issue` is `String!` in the
schema and a `String` in Swift; `name` on Rick and Morty's `Character` is
`String` and reads as an optional. A view stops guarding what the server
promises and stops trusting what it does not.

The rule goes down into lists. A list `[String]`, whose elements the schema
types nullable, reads as `[String?]?`, and a null element reads as nil; a list
`[String!]!` reads as `[String]`. That was a shortcut in 0.1.0, which dropped
null elements on the way with no decision recorded, and the record that fixed
it says why the exception for lists of records stands: a `List` of lenses is
keyed by its records' identities, for `ForEach` and for diffing, and a null
entry has no identity to be keyed by, so the store keeps the entry and the
lens shows the records ([the
decision](../decisions/a-lists-null-elements-are-typed.md)).

The schema is sometimes the one lying, and the directives are for that.
`@required(action:)` says a view cannot do without a field the schema allows
to be null, and moves the null up to where the product wants to handle it:
`NONE` and `LOG` make the field non-optional and bubble the null to the lens
boundary, so the accessor that produces the lens produces nil instead, and
`LOG` logs the path; `THROW` makes the field's own accessor throw, `get
throws` in Swift and a throwing getter in Kotlin, at exactly the read. A null
that bubbles all the way to an operation's root fails the operation with the
path of the field, because a phase has no null data to offer a view ([the
decision](../decisions/error-directives-in-swift.md)). What that record
refused is the usual answer: throwing accessors everywhere, or `Result`
everywhere, so that any error could surface at any read. Then every body is a
`try` and the schema's nullability stops meaning anything.

## The second lie: an error is a null

A field error is a server's failure to resolve one field, with the rest of the
response intact. Most clients return the null and drop the error, or hand the
error to whoever made the request and not to the view that reads the field.
Baton stores the error beside the field it names, with its message, its path
and its `extensions`, resolved by path at ingest, kept in memory and in the
image, and cleared by the next payload that answers the field. A cached read
sees the same error the network read saw. A plain accessor keeps reading the
field as null; `@catch(to: RESULT)` reads a `Result`, success with the value
or failure with the errors, so the view can say what went wrong; `@catch(to:
NULL)` keeps the optional for a field the view would rather blank.
`@throwOnFieldError` on a fragment makes its spread accessor throw, and on an
operation puts the handle in `failed` with the errors while the data stays in
the store. A schema's `@semanticNonNull` reads non-optional under either, as
Relay's rule says.

The fixtures hold responses with errors on them. The notifications script
commits a response with errors for three fields and requires those three slots
to notify, then commits one that answers them and requires the three to notify
again; the specification's expected reads require a `@catch` read, a plain
read and a cached read of the same errored field to agree with the response.
The GitHub sample shows the point: a missing repository comes back as `null`
with a field error, and `repository @catch` shows the server's sentence
instead of a guess.

A response without errors pays nothing at ingest for the machinery. On an
Apple M1 Pro on 3 October 2026, twenty field errors added about a quarter of a
millisecond to the ingest of the 686 KB fixture, most of it the index the path
walk needs, built only when errors exist; a `@catch` read of a field without
an error costs 122 ns against 29 ns for a plain read; a `satisfied` check of a
lens with one `@required` field costs 29 ns
([BENCHMARKS.md](../../BENCHMARKS.md), the 0.5.0 entry).

## The third lie: a failure is a string

The specification names two kinds of error. A request error is raised before
execution begins, and the response then has no data; a field error is raised
while a field executes, and the response has partial data. A client that gives
a view `any Error` makes every render site match on types, and the runtime
itself cast at eight places before the decision that closed the set ([the
decision](../decisions/a-failure-says-its-kind.md)). A fetch now fails in one
of four kinds: the transport's, carrying what the transport threw unchanged; a
request error, carrying the server's errors; a malformed response, one the
plan cannot read; or the environment's, when nothing can send the request. The
same kinds classify how a subscription's stream ended and what the log
reports, so there is no second vocabulary to drift from the first. And an
error keeps its `extensions`, where the specification's own example puts a
code, so an app branches on the server's code and never on its message.

A failure behind data is not a failure of the data. When a refresh fails, the
data stays on screen and the handle's `fetch` carries the failure with its
kind and the time it failed, so a view shows the content and a notice rather
than a blank and an alert.

## The fourth lie: missing data is nothing

Missing data is the one case the types cannot express. It arises only when
another operation retargets a link to a record fetched with fewer fields: a
list fetched a location's name, a detail fetched its dimension, and a later
response points a character's `origin` at a location the store knows only by
name. A client that returns nothing here crashes on the first `.count`; a
client that suspends hides the screen. Baton does neither and invents nothing:
the lens reads nil, or the type's zero value where there is no nil, the
environment logs a `missing` event naming the type and the field, the owning
operation is marked stale and refetched once, and a debug build is loud about
it. The view shows a blank for a moment and then the truth. The heal script
fixes the sequence: the read logs the miss and the owner refetches, the
refetch restores the value, and a second miss after the heal's own refetch is
logged as unexpected and healed no further ([the
principle](../principles/honest-data.md)).

A response that omits a field the operation selected is not missing data. It
fails the fetch as malformed, so a hole in the store can only come from a
retargeted link, never from a server that stopped sending a field.

## The fifth lie: a value that does not fit is zero

A null in a non-null field, or a string where an integer was promised, is
reported as unexpected through the log and reads as nil or as the zero value;
it is never silently a value. The first adopter put the sharper case: an
amount that does not parse must never render as `0`
([#11](https://github.com/shergin/baton/issues/11)). So a custom scalar mapped
to an app's type, `Decimal`, `Date`, `URL`, or a Kotlin type with its
converter, converts at the read and is a fallible read: its accessor is
optional wherever the schema puts the field, unless `@required` or
`@throwOnFieldError` says what a failure does, and a text that does not
convert is reported and never zero ([the
decision](../decisions/a-mapped-scalar-is-a-fallible-read.md)). A mapped type
has no honest zero: zero is an amount, a date's zero is a date, and a URL has
none.

Enums are the same boundary with one difference: the conversion cannot fail,
so it keeps the schema's nullability. Each schema enum compiles to an enum
with a case per value, spelled as the schema spells it, and one more carrying
the text of a value the build did not know, `unknown(String)` in Swift and
`Undeclared` in Kotlin, as Relay types every enum with a future value. A
schema that grows after the build is not a client failure ([the
decision](../decisions/an-enum-reads-as-a-generated-enum.md)).

## The sixth lie: cached is fresh

A handle's phase is `loading`, `ready` or `failed`, and beside it `isStale`
says whether the data is older than its operation's expiration or was marked
stale by an invalidation. The age survives a launch, because the image keeps
when each operation last fetched. The expiration is stated in the document,
`@cacheExpiration(seconds:)`, the one directive Baton has that Relay does not.
Stale data stays visible; a `storeOrNetwork` attach refetches it, and
`revalidate()` on the app's return refetches whatever went stale meanwhile.
Nothing is served as fresh without a way to tell.

## What it costs, and what it buys

A sloppy schema costs `if let`. The Rick and Morty API marks nearly everything
nullable, which is why the rows on this site read `character.name ??
"Unknown"`; GitHub's marks `title` and `number` non-null, so a row over GitHub
reads them straight. The error machinery costs nothing at ingest without
errors, and a `@catch` read costs about a hundred nanoseconds more than a
plain one per field, error or not. And a mapped scalar's accessor is optional
where a less honest client would have handed over a zero.

What it buys is a data layer whose every imperfection is a value: an optional
where the schema allows null, a `Result` where a field failed, a kind where a
fetch failed, a log event and a refetch where data went missing, a case where
an enum grew, and a flag where data went stale. Those are the cases that page
people at two in the morning, and in Baton each of them is something a view
reads and a test asserts, on both runtimes, under the same fixtures.
