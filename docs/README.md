# Docs

What to read when.

- **What is this, and why is it shaped this way?**
  [vision.md](vision.md) is the argument and the five rules.
- **Why GraphQL at all, and where do my view models go?**
  [why-graphql.md](why-graphql.md) is for iOS and Android engineers who
  have built on REST: what it is, what it changes, and what it costs.
- **Why is this decision the way it is?**
  [principles/](principles/) has one file per constraint: the failure it
  avoids, the idea, the consequences, the rejected alternatives, and how
  it is spelled in code today.
- **Why this and not the alternative?**
  [decisions/](decisions/) has one file per choice: the context, the
  decision, the evidence, what was not chosen, and what would reopen it.
- **How does this compare with the other native clients?**
  [comparison.md](comparison.md) sets out the approaches, the numbers, and
  the pros and cons.
- **Why this shape, argued at length?**
  [articles/](articles/) holds one essay per choice that shapes the
  library: Relay without the read side, what Meta built, why it is fast,
  the first frame, two runtimes and the compiler. Further essays cover how
  a fast store stays honest, the twelve words, Baton beside fate, the small
  lies a client tells, and how it is built.
- **What does this word mean?**
  [terminology.md](terminology.md) is the vocabulary contract, updated in
  the same change as the code. Concepts marked *(planned)* do not exist
  yet.
- **Where is it, in each runtime?**
  [runtimes.md](runtimes.md) is the map of both trees, a file per concept,
  checked by the boundary script.
- **How do I...** [recipes/](recipes/) has one page per composition of what
  ships. [integrating Baton with a coding agent](recipes/agents.md) is the
  page an agent reads first. [the exchange](recipes/exchange.md) is a
  challenge, a retry and a deadline over the transport's one verb.
  [a budgeted transport](recipes/budgeted-transport.md) is a queue, a
  meter and an outage over the same verb.
  [`batonc`](recipes/batonc.md) is the compiler's command line for a build
  outside SwiftPM. [Bazel](recipes/bazel.md) is the compiler as a toolchain
  and one rule over its command. [Gradle](recipes/gradle.md) is the Kotlin
  runtime from Maven Central and the compiler as a task.
  [previews and tests](recipes/testing.md) is a store without a server.
  [UIKit and AppKit](recipes/uikit.md) is a handle held by a controller.
  [views and view models](recipes/views.md) is a Kotlin handle without a
  composition. [outside views](recipes/outside-views.md) is a fetch, a read
  and a write from code that is not a view.
  [accounts](recipes/accounts.md) is a sign-out, a switch and what the disk
  keeps. [porting from Relay](recipes/porting-from-relay.md) sets Relay's
  words beside Baton's.
  [derived state outside views](recipes/derived-state.md) is a model over
  `Observations` or `snapshotFlow`.
  [discover once, refresh through `nodes(ids:)`](recipes/discover-once.md)
  is the pattern for external keys.
  [an unpaged collection](recipes/unpaged-collection.md) is a whole list in
  one request, grouped on the client and carried by the image.
  [fields a server nulls by path](recipes/fields-by-path.md) is what a list
  fragment selects. [a `Json` scalar](recipes/json-scalar.md) is a value
  with no type of its own, read as a type of the app's. The rest arrive
  with the releases that make them true.
- **What did a decision open up?** [openings/](openings/) is written as the
  project ships. There are none yet.
