# Floors at the 26 releases

Status: accepted, 2026-10-02. Serves
[The store is the UI's state](../principles/store-is-the-ui-state.md).
Reopen when an adopter needs an older release, or at the 1.0 review.

## Context

Observation, which the store is built on, needs iOS 17. Every release since
added something the runtime would otherwise have to work around: `Mutex`
and the main-actor `View` baseline in 18, `Observations` and `InlineArray`
in 26, continuous observation in 27.

## Decision

iOS 26, macOS 26 and the matching 26 releases of the other Apple platforms;
Swift 6.2 tools (Xcode 26 or later); Swift 6 language mode. The runtime
carries no availability branches below the floor; iOS 27 APIs are used
behind a check where they pay.

## Evidence

- iOS 26 and 27 together were about 91% of iPhones in late September 2026
  (TelemetryDeck), with iOS 17 and older under 2%.
- The App Store has required the iOS 26 SDK since April 2026, so every
  shipping app already builds with the tools the floor assumes.
- The owner's products do not need older releases, and backward
  compatibility was explicitly not a concern.

## Not chosen

- iOS 17, the hard floor of Observation: every newer convenience behind a
  check, for under 2% of devices.
- iOS 18: `Observations` and `InlineArray` behind checks, for under 10%.
