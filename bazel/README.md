# rules_baton

Baton's compiler as a Bazel toolchain, fetched from the release's artifact
bundle, and one rule over its command, versioned with Baton.
[`docs/recipes/bazel.md`](../docs/recipes/bazel.md) is the page.
A `baton_generate` lists the targets whose fragments it spreads in
`deps`, its bases, and names its Swift module in `module`, which a
Kotlin target does not set; it writes the
fragments file as the output group `fragments` and returns `BatonInfo`.
`scripts/check-bazel.sh` runs the example under `examples/rickandmorty`
over the compiler built in the checkout, as CI does, `bases/` among it.
`scripts/check-bases.sh` builds and tests two modules of one app, the
second spreading a fragment the first declares, in Swift and in Kotlin,
over the same compiler, as CI does.
