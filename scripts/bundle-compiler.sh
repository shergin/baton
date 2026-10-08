#!/bin/sh
# Builds batonc for both Mac architectures, takes the static Linux binaries
# scripts/build-compiler-linux.sh built on an x86_64 and an aarch64 Linux
# host, and packs the artifact bundle a release publishes,
# compiler/dist/release/batonc.artifactbundle.zip, which Package.swift
# names by its checksum. Prints the checksum last.
set -eu
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root/compiler"
for target in aarch64-apple-darwin x86_64-apple-darwin; do
  cargo build --release --target "$target"
done
version="$(grep -m1 '^version = ' Cargo.toml | sed 's/version = "\(.*\)"/\1/')"
stage="$root/compiler/dist/release"
bundle="$stage/batonc.artifactbundle"
rm -rf "$stage"
mkdir -p "$bundle/batonc-macos/bin"
lipo -create -output "$bundle/batonc-macos/bin/batonc" \
  target/aarch64-apple-darwin/release/batonc \
  target/x86_64-apple-darwin/release/batonc
for arch in x86_64 aarch64; do
  linux="$root/compiler/dist/linux/$arch/batonc"
  if [ ! -f "$linux" ]; then
    echo "no Linux binary at $linux; build it with scripts/build-compiler-linux.sh on a $arch Linux host" >&2
    exit 1
  fi
  mkdir -p "$bundle/batonc-linux-$arch/bin"
  cp "$linux" "$bundle/batonc-linux-$arch/bin/batonc"
  chmod +x "$bundle/batonc-linux-$arch/bin/batonc"
done
# The Linux binaries are static, so each is listed under the gnu triple a
# Linux host reports, which SwiftPM and the Bazel toolchain match on.
cat > "$bundle/info.json" <<JSON
{
  "schemaVersion": "1.0",
  "artifacts": {
    "batonc": {
      "version": "$version",
      "type": "executable",
      "variants": [
        { "path": "batonc-macos/bin/batonc", "supportedTriples": ["arm64-apple-macosx", "x86_64-apple-macosx"] },
        { "path": "batonc-linux-x86_64/bin/batonc", "supportedTriples": ["x86_64-unknown-linux-gnu"] },
        { "path": "batonc-linux-aarch64/bin/batonc", "supportedTriples": ["aarch64-unknown-linux-gnu"] }
      ]
    }
  }
}
JSON
(cd "$stage" && zip -qrX batonc.artifactbundle.zip batonc.artifactbundle)
echo "bundle at $stage/batonc.artifactbundle.zip" >&2
swift package --package-path "$root" compute-checksum "$stage/batonc.artifactbundle.zip"
