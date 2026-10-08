# swift-syntax spans the floor to the newest release

Status: accepted, 2026-10-07. Answers
[#39](https://github.com/shergin/baton/issues/39). Serves
[Floors at the 26 releases](platform-floors.md). Reopen when a swift-syntax
release breaks the macros in a way one source cannot serve on both ends of
the range, or when the floor moves.

## Context

The macro target, `BatonMacros`, depends on swift-syntax, whose major
version follows the Swift release: 602 for Swift 6.2, 603 for 6.3, 604 for
6.4. `Package.swift` asked for `from: "602.0.0"`, which SwiftPM reads as
602 alone. An app that pins swift-syntax to its compiler's release, as
swift-syntax advises a macro package's consumers to, and as an app with a
second swift-syntax consumer must, could not resolve Baton at all on Swift
6.3: SwiftPM refused the graph before any of Baton was built, and its
message did not say which side to change.

The issue asked for `"602.0.0"..<"604.0.0"`. swift-syntax 604.0.0 had been
released three weeks before it was filed.

## Decision

- The macros accept every swift-syntax release from the one matching the
  floor's toolchain (602, for Swift 6.2 tools) to the newest one released,
  as a closed range: `"602.0.0"..<"605.0.0"` today.
- The upper bound moves when a swift-syntax major ships: the range is
  raised to admit it once the macros build and their tests pass on it. The
  lower bound moves with the floor.
- CI builds and tests the package at both ends: the `swift` and `floor`
  jobs on the committed `Package.resolved`, which stays at the floor's
  release, and the `newest-syntax` job on the newest release the range
  allows, resolved by `swift package update swift-syntax`, so the day a
  major ships is a red job here rather than an adopter's failed resolve.

## Evidence

- The macros build with warnings as errors against 602.0.0, 603.0.2 and
  604.0.0 on Swift 6.3.3 (Xcode 26.6), and the whole test suite passes
  against 604.0.0 (2026-10-07). The target uses `SwiftSyntax`,
  `SwiftSyntaxBuilder`, `SwiftSyntaxMacros` and `SwiftCompilerPlugin` in
  ways unchanged across those releases.
- swift-syntax's releases: 602.0.0 on 2025-09-15, 603.0.0 on 2026-03-24,
  604.0.0 on 2026-09-15, none of them a prerelease.
- Resolved at the toolchain's own release (603.0.2 on Swift 6.3.3),
  SwiftPM downloads swift-syntax's prebuilt macro support and the macro
  target builds in seconds; resolved at 602 on the same toolchain, it
  builds swift-syntax from source, about a minute. A range lets an app
  have the prebuilt.

## Not chosen

- `"602.0.0"..<"604.0.0"`, as asked: 604 was out, and an app on its
  toolchain would fail as the issue's did on 603.
- An open upper bound: SwiftPM picks the newest release the range allows,
  so an app that does not pin swift-syntax would take an untested major
  the day it ships, and a breaking one would fail its build with nothing
  Baton could release to help.
- Moving the lower bound to 603: the floor is Swift 6.2 tools, and Xcode
  26.0 builds against 602.
