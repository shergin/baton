# Releases are frequent and named for bread

Status: accepted, 2026-10-07. Reopen if adopters ask for fewer releases
than master's pace gives them, or if the list below runs out and no bread
is left that the rule admits.

## Context

Eight releases from 0.1.0 to 0.8.0 were each cut when a planned step was
done, and named by the owner on a relay theme, one at a time. After 0.7.0
the owner dropped formal release cycles for commits and iteration, and
0.8.0 then gathered everything since 0.7.0 in one release. An adopter
depends on Baton by its tag, so a change that is on master and not in a
tag does not reach them; each release also had to wait for someone to
pick its name.

## Decision

- Releases are frequent: days apart, not weeks. A release is cut when the
  changelog's Unreleased section holds something an adopter can use and the
  local checks pass. It waits for no step, theme or batch of work.
- The name is chosen automatically, not asked for: whoever cuts the
  release takes the first name in the list below that no release has used,
  and writes it into the changelog's heading and the workflow's input.
- The names are breads of Russian, Ukrainian and Belarusian baking, and
  their variants, transliterated into ASCII as one capitalized word, as
  English most often spells them.
- *Baton*, the loaf the project is named for, is kept for 1.0.

The names, in order, from 0.9.0:

1. Krendel
2. Vatrushka
3. Karavai
4. Palianytsia
5. Bublik
6. Kalach
7. Sushka
8. Pampushka
9. Kulich
10. Knysh
11. Baranka
12. Borodinsky
13. Pyshka
14. Perepichka
15. Bukhanka
16. Rasstegai
17. Pletinka
18. Kulebyaka
19. Shanga
20. Zhavoronok
21. Paska
22. Lepyoshka
23. Sloika
24. Darnitsky

When the list runs out, names that follow the same rule are appended to it
before the next release; a name already used is never used again.

## Evidence

- The repository: tags `v0.1.0` to `v0.8.0`; 0.8.0's changelog section
  covers the whole spine and the lanes, a month of planned steps in one
  release.
- The release workflow (`.github/workflows/release.yml`) takes the version
  and the name as inputs and checks that the changelog has the section
  `## <version> (<name>)`; nothing else in a release needs a person.

## Not chosen

- A release per planned step: the steps are done, and work since lands as
  single commits that would wait for a step that is not coming.
- Names chosen by the owner each time: a release would wait on a question
  with no technical content.
- Keeping the relay theme: its words ran out with the race, and *Photo
  Finish*, which it promised to the last release before 1.0, is retired
  with it.
