# Docs

What to read when.

- **What is this, and why is it shaped this way?**
  [vision.md](vision.md) — the argument and the five rules.
- **Why is this decision the way it is?**
  [principles/](principles/) — one file per constraint: the failure mode it
  avoids, the idea, the consequences, the rejected alternatives, and how it
  is spelled in code today.
- **Why this and not the alternative?**
  [decisions/](decisions/) — one file per choice: context, decision,
  evidence, what was not chosen, and what would reopen it.
- **How does this compare with the other native clients?**
  [comparison.md](comparison.md) — approaches, numbers, pros and cons.
- **What does this word mean?**
  [terminology.md](terminology.md) — the vocabulary contract, updated in the
  same change as the code. Concepts marked *(planned)* do not exist yet.
- **How do I…** — [recipes/](recipes/), one page per composition of what
  ships: [the exchange](recipes/exchange.md), a challenge, a retry and a
  deadline over the transport's one verb, [`batonc`](recipes/batonc.md),
  the compiler's command line for a build outside SwiftPM, and
  [previews and tests](recipes/testing.md), a store without a server,
  [UIKit and AppKit](recipes/uikit.md), a handle held by a controller, and
  [porting from Relay](recipes/porting-from-relay.md), Relay's words beside
  Baton's, and [derived state outside views](recipes/derived-state.md), a
  model over `Observations`, and [discover once, refresh through
  `nodes(ids:)`](recipes/discover-once.md), the pattern for external keys.
  The rest arrive with the releases that make them true.
- **What did a decision open up?** — [openings/](openings/), written as the
  project ships. None yet.
