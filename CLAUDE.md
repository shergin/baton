# Working in this repository

Read `notes/README.md` first when it exists in your checkout (the `notes/`
tree is private and git-invisible; a fresh clone does not have it). The public
design argument is `docs/vision.md`, the constraints are `docs/principles/`,
the vocabulary is `docs/terminology.md`. These files outrank any default.

## The rules of the project

- The concept inventory is closed. A feature is a composition of existing
  concepts or a Relay directive the compiler understands, or it does not
  ship. Name a concept in `docs/terminology.md` before naming it in code.
- Relay's words and directives, not Apollo's. Do not invent a word where Relay
  or the GraphQL specification has one.
- Reads are synchronous on the main actor; everything else runs off it. Never
  add an asynchronous read API for views. Never parse GraphQL at run time.
- The response is the oracle: a change to the store, the tokenizer or the
  record layout is behavior-frozen under `spec/` fixtures.
- A claim without a bench does not ship. Numbers in docs come from the bench
  suite and are recorded in `BENCHMARKS.md` with device, OS and date.
- Public docs are updated in the same change that makes them stale: README,
  CHANGELOG, `docs/terminology.md`, the sample.
- Settled stays settled. Decisions of public interest are recorded in
  `docs/decisions/` (context, decision, evidence, what would reopen them);
  the full log stays in the planning notes. Do not relitigate without new
  evidence; when evidence arrives, supersede the record rather than editing
  its history.

## Git

- One meaningful change per commit; imperative subject under about fifty
  characters; a body only when the diff cannot speak for itself.
- No attribution lines, trailers or session links in commits or pull
  requests.
- Release commits are `Release <version> (<Name>)` and touch only the
  manifests and the changelog.

## Swift

- Swift 6 language mode, strict concurrency. Every public and generated
  declaration states its isolation explicitly (`@MainActor` or
  `nonisolated`), because consumers may compile with default main-actor
  isolation.
- The runtime depends on Foundation and Observation only. The macro package is
  the only target that may depend on swift-syntax.
- No `Any`, no dictionaries and no `Codable` on the read path. Records are
  slots; values are enums.
- Observation key paths used as invalidation channels must be stored
  properties or computed properties with distinct bodies; identical getters
  are merged by the optimizer and collide in the registrar. Test release
  builds.
- Prefer early returns. Name things with full words; the only accepted
  abbreviations are the idiomatic ones (`id`, `url`).
- Tests live beside the module they test, named for the behaviour they prove
  in full sentences (`a_refetch_that_changes_one_field_evaluates_one_body`).
  Use `spec/` fixtures over hand-written data. No mocks of our own types.
- Doc comments on public items are noun phrases for types and third-person
  sentences for functions; only comment what is not obvious from the code.

## Rust (compiler/)

- Stable toolchain; `cargo fmt` before `cargo check`; `clippy -D warnings`
  clean.
- The Relay front-end crates are consumed at a pinned revision behind our
  driver. Everything after the plan IR is ours; do not reach into Relay's
  codegen or typegen.
- Errors use `thiserror` with `#[from]`; early returns over nested matches.
- Generated output is deterministic and byte-stable; golden tests cover every
  emitter.
- Diagnostics are printed as `path:line:column: error: message`, pointing
  into the GraphQL text inside the host file.

## Comments

- Comment to explain non-obvious logic, a design choice, or a component; not
  to narrate the code.
- Full English sentences ending with a period; ASCII only; identifiers in
  backticks; no decorative characters.
