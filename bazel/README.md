# rules_baton

Baton's compiler as a Bazel toolchain, fetched from the release's artifact
bundle, and one rule over its command, versioned with Baton.
[`docs/recipes/bazel.md`](../docs/recipes/bazel.md) is the page.
`scripts/check-bazel.sh` runs the example under `examples/rickandmorty`
over the compiler built in the checkout, as CI does.
