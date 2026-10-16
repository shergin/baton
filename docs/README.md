# Docs

What to read when.

- **What is this, and why is it shaped this way?**
  [vision.md](vision.md). The argument, and the five rules.
- **Why GraphQL at all, and where do my view models go?**
  [why-graphql.md](why-graphql.md). For iOS and Android engineers who have
  built on REST: what it is, what it changes, what it costs.
- **Why is this decision the way it is?**
  [principles/](principles/). One file per constraint. The failure it
  avoids, the idea, the consequences, the rejected alternatives, and how
  it is spelled in code today.
- **Why this and not the alternative?**
  [decisions/](decisions/). One file per choice. Context, the decision,
  the evidence, what was not chosen, and what would reopen it.
- **How does this compare with the other native clients?**
  [comparison.md](comparison.md). Approaches, numbers, pros and cons.
- **Why this shape, argued at length?**
  [articles/](articles/). One essay per choice that shapes the library.
  Relay without the read side. What Meta built. Why it is fast. The first
  frame. Two runtimes. The compiler. How a fast store stays honest. The
  twelve words. Baton beside fate. The small lies a client tells. How it
  is built.
- **What does this word mean?**
  [terminology.md](terminology.md). The vocabulary contract, updated in
  the same change as the code. Concepts marked *(planned)* do not exist
  yet.
- **Where is it, in each runtime?**
  [runtimes.md](runtimes.md). The map of both trees, a file per concept,
  checked by the boundary script.
- **How do I...** [recipes/](recipes/). One page per composition of what
  ships. [integrating Baton with a coding agent](recipes/agents.md), the
  page an agent reads first. [the exchange](recipes/exchange.md), a
  challenge, a retry and a deadline over the transport's one verb.
  [`batonc`](recipes/batonc.md), the compiler's command line for a build
  outside SwiftPM. [Bazel](recipes/bazel.md), the compiler as a toolchain
  and one rule over its command. [Gradle](recipes/gradle.md), the Kotlin
  runtime from Maven Central and the compiler as a task.
  [previews and tests](recipes/testing.md), a store without a server.
  [UIKit and AppKit](recipes/uikit.md), a handle held by a controller.
  [views and view models](recipes/views.md), a Kotlin handle without a
  composition. [outside views](recipes/outside-views.md), a fetch, a read
  and a write from code that is not a view.
  [accounts](recipes/accounts.md), a sign-out, a switch and what the disk
  keeps. [porting from Relay](recipes/porting-from-relay.md), Relay's words
  beside Baton's. [derived state outside views](recipes/derived-state.md),
  a model over `Observations` or `snapshotFlow`.
  [discover once, refresh through `nodes(ids:)`](recipes/discover-once.md),
  the pattern for external keys. The rest arrive with the releases that
  make them true.
- **What did a decision open up?** [openings/](openings/), written as the
  project ships. None yet.
