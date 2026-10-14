# Articles

The design argued at length. Each page takes one choice that shapes the
library, says what the alternatives were and what they cost, and puts the
evidence beside it: the numbers from [BENCHMARKS.md](../../BENCHMARKS.md), the
decision records under [decisions/](../decisions/), and the public record of
the clients Baton is compared with. The short forms are the
[vision](../vision.md) and the [principles](../principles/); these are the
long ones, in reading order.

- [Relay without the read side](relay-without-the-read-side.md): why Baton
  keeps Relay's compiler and the write side of its store and deletes the read
  side, because Observation and snapshot state already answer the question
  Relay's runtime was built to answer.
- [What Meta built, and what you can download](what-meta-built.md): the public
  record of Meta's in-house native client, where Baton makes the same choices,
  and where it goes further.
- [Materialization is the bill](materialization-is-the-bill.md): why Baton is
  faster than Apollo iOS and Apollo Kotlin on the same data, itemized on a Mac
  and on a phone, with the caveats.
- [The first frame has the data](the-first-frame.md): synchronous reads on the
  main actor, the image on disk, what a phone measured, and the fix the trace
  asked for.
- [Two runtimes, no bridge](two-runtimes-no-bridge.md): why the runtime is
  written twice instead of shared through a Rust core, and what holds the two
  to one behaviour.
- [A compiler, not a configuration](a-compiler-not-a-configuration.md): what
  is settled at build time, why the runtime has no parser and no policy
  object, and why that matters more now that agents write screens.
- [How a fast store stays honest](how-a-fast-store-stays-honest.md): the
  oracle, the fixtures, Relay's own tests measured against, and the benches
  that keep every claim checkable.
- [Twelve words, and why the list is closed](twelve-words.md): the closed
  vocabulary, what it refused and why, and how it looks beside a client
  that dropped GraphQL and the clients that chose configuration.
- [Baton beside fate](baton-beside-fate.md): a client that took Relay's
  insights and removed GraphQL, beside one that kept the compiler; where
  they agree, where they part, three mechanisms watched, and a proof against
  fate's own server.
- [The small lies a client tells](the-small-lies.md): six ways GraphQL
  clients lie about data, and the types, directives and events that keep
  Baton from each.
- [Settled stays settled](settled-stays-settled.md): how Baton is built,
  habit by habit, each with the mechanism that fails when the habit is
  dropped.
