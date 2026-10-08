#!/bin/sh
# Builds batonc as one static binary for the Linux host's architecture, with
# the musl target so that it runs on any distribution, and puts it where
# scripts/bundle-compiler.sh takes it: compiler/dist/linux/<arch>/batonc.
# Needs rustup; the release workflow and CI run it on an x86_64 and an
# aarch64 host each.
set -eu
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root/compiler"
arch="$(uname -m)"
case "$arch" in
  x86_64) ;;
  aarch64|arm64) arch=aarch64 ;;
  *) echo "unsupported host: $arch" >&2; exit 1 ;;
esac
target="$arch-unknown-linux-musl"
rustup target add "$target"
cargo build --release --target "$target"
out="$root/compiler/dist/linux/$arch"
mkdir -p "$out"
cp "target/$target/release/batonc" "$out/batonc"
chmod +x "$out/batonc"
# A static binary is the point: one that needs a C library is not the
# variant the bundle promises.
if ! file "$out/batonc" | grep -Eq 'static(ally|-pie) linked'; then
  echo "$out/batonc is not statically linked: $(file "$out/batonc")" >&2
  exit 1
fi
echo "static batonc for $target at $out/batonc ($(du -h "$out/batonc" | cut -f1))"
