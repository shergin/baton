#!/bin/sh
# Runs the Bazel example over the compiler built in this checkout, as CI
# does: the generation target builds in the sandbox, its output is copied
# into Generated/, the check test passes over it and fails once one file is
# edited. Needs bazelisk (or bazel) and a built compiler, the one
# BATON_COMPILER names or compiler/target/release/batonc.
set -eu
root="$(cd "$(dirname "$0")/.." && pwd)"
compiler="${BATON_COMPILER:-$root/compiler/target/release/batonc}"
if [ ! -x "$compiler" ]; then
  echo "no compiler at $compiler; run cargo build --release in compiler/, or name one in BATON_COMPILER" >&2
  exit 1
fi
bazel="$(command -v bazelisk || command -v bazel)" || { echo "bazelisk or bazel is needed" >&2; exit 1; }
cd "$root/bazel/examples/rickandmorty"
run() { "$bazel" "$@" "--repo_env=BATON_COMPILER=$compiler"; }
run build //:screens
rm -rf Generated
mkdir Generated
cp bazel-bin/screens/*.baton.swift Generated/
# Bazel's outputs are read-only; a committed file is not.
chmod u+w Generated/*
run test //:screens_check
printf '// An edit.\n' >> Generated/Baton.baton.swift
if run test //:screens_check; then
  echo "the check test passed over a stale output" >&2
  exit 1
fi
rm -rf Generated
echo "the Bazel example builds, and the check test tells fresh output from stale"
