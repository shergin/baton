# An operation is sent as its text or its id, and the build decides

Status: accepted, 2026-10-04. Serves
[The compiler decides](../principles/compiler-decides.md) and
[Relay's words](../principles/relays-words.md). Reopen the default wire
shape if the GraphQL-over-HTTP specification settles persisted documents
otherwise than its open proposal does. Reopen pinned documents for a server
whose registry cannot take new documents.

## Context

The compiler prints each operation's text and hashes it to an id, with MD5,
and the artifact carries both. So does a request. Its body always writes
`query`, the socket's subscribe payload does too, and nothing sends the id.
The comparison page lists it among Baton's gaps.

The first adopter's servers accept only registered operations
([#7](https://github.com/shergin/baton/issues/7)). The issue asks for a
choice of algorithm, a mode on the transport that sends the id and never
the text, a manifest for the registration step, and documents pinned to a
text the server already has.

Relay has the setting: `persistConfig`, with `file` and `algorithm`. Under
it an artifact carries the id and no text. The wire has no settled word.
The GraphQL-over-HTTP specification says nothing of persisted documents
yet; its working group's appendix is an open pull request that names the
parameter `documentId`. Servers in the field take other shapes: the issue
names Apollo's `extensions.persistedQuery` and a bare `id`, and Relay's
guide shows `doc_id`.

## Decision

The build decides what an operation is sent as. All of it is *(planned)*.

- Text or id, never both. Under `persistConfig` the artifact carries the id
  and no text; without it, the text and no id. A request says which it
  carries.
- No transport has a mode, and there is no fallback: the binary holds no
  text to fall back to. That holds for a query, a deferred response and a
  subscription alike, and the documents stay out of the shipped app.
- The keys are Relay's, in `baton.json`: `persistConfig.file` and
  `persistConfig.algorithm`, which is MD5, SHA256 or SHA1. The file is
  Relay's map from id to text, written in a stable order: what a
  registration step consumes and a review reads.
- One string is the id in the artifact, in the file and on the wire. The
  runtime hashes nothing.
- One function turns a request into the JSON a server receives, for the
  HTTP body and for the socket's subscribe payload. By default it writes
  `query`, or `documentId` after the working group's proposal. A server
  with another convention replaces the function and keeps the built-in
  transports. Its exact shape is settled with the transports' credentials.
- Pinned documents are refused. The plan is derived from the text the
  compiler prints, and a document of another shape is a response the plan
  was not made for. Register what `batonc` prints: it is deterministic and
  byte-stable.

## Evidence

- As built, by reading: `pipeline.rs` hashes the text with MD5;
  `Request.body` writes `query` and never the id; the socket's payload
  writes `query`; nothing at run time reads `persistedID` but the
  environment that copies it into a request.
- Relay's guide to persisted queries, read 2026-10-04: the keys, the
  artifact's `id` with a null `text`, the file as a map from id to text,
  and `doc_id` in its example of a network layer.
- [graphql/graphql-over-http#264](https://github.com/graphql/graphql-over-http/pull/264),
  read on its branch 2026-10-04: an optional extension; the parameter is
  `documentId`; an identifier is prefixed, as `sha256:` and 64 hexadecimal
  characters, or custom, with no colon, and Relay's MD5 is named as a
  custom one; an unknown identifier is answered with a response of one
  error. The older RFC calls itself superseded by this appendix. The
  appendix is not merged.
- Nothing is measured, and nothing needs to be: no read or commit changes.

## Not chosen

- A mode on the transport that sends ids only, as the issue asks and a
  review of the same code recommended. It is a switch at run time for a
  fact of the build, "never answer with the text" becomes a rule every
  transport has to keep, and the text ships in the binary.
- Text and id in every artifact, as built: nothing says which one the
  server wants, and the document ships either way.
- Keys of our own, `persistedQueries.algorithm` and `.manifest`: a web
  project already has Relay's.
- A list of wire shapes on the transport: it grows with every server's
  convention.
- Leaving another shape to an app's own transport: it would write the
  multipart stream and the socket protocol again.
- Registering on a miss, the automatic kind: it needs the text and the id
  at run time, Relay never had it, and the working group took it out of
  its proposal.
- A hash made by the runtime, or a prefix it adds: the id is the compiler's
  output, and one string everywhere cannot drift.

## Built, 2026-10-11

As decided: `persistConfig` with `file` and `algorithm`; the artifact's
`document` is the text or the id, never both; the standard encoding writes
`query` or `documentId`; one encoding function serves the HTTP body and the
socket's payload and is replaced on the built-in transports; `batonc
generate` writes the file, beside the configuration by hand and into the
build's output directory under the SwiftPM plugin, whose sandbox keeps the
source tree. The id is the hash's lowercase hexadecimal with no prefix, as
Relay writes it; a server wanting the working group's `sha256:` prefix adds
it in its encoding. The transport's one verb and the request's kind landed
in the same change, and the credentials are read per attempt, so the exact
shape this record deferred to #19 is settled with it. The retry, the
challenge and the deadline a production endpoint needs are a wrapper over
the one verb that the app owns: `docs/recipes/exchange.md` walks through
`examples/Exchange`, which the GitHub sample sends through.
