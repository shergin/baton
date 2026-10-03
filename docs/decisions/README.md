# Decisions

Choices made among real alternatives, with the evidence that decided them
and the condition that would reopen them. One file per decision.

These are not principles. Principles are rules that must not rot; a decision
may be superseded, and says so in its status line. A decision never overrides
[vision](../vision.md) or a [principle](../principles/); where a principle
rests on a decision, the principle names it.

Each record has the same shape: a status line (accepted or superseded, with
the date, the principle it serves, and what would reopen it), then Context,
Decision, Evidence, Not chosen. Keep them short; the argument belongs in the
principle, the proof belongs here.

- [Native runtimes, not a shared core](native-runtimes.md)
- [Relay's front end, pinned, behind our driver](relay-front-end.md)
- [Marker macros carry the GraphQL](marker-macros.md)
- [Floors at the 26 releases](platform-floors.md)
- [Lookups satisfy root fields from cached entities](lookups.md)
