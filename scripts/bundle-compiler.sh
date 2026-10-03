#!/bin/sh
# Builds batonc for both Mac architectures and packs the artifact bundle a
# release publishes, compiler/dist/release/batonc.artifactbundle.zip, which
# Package.swift names by its checksum. Prints the checksum last.
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
cat > "$bundle/info.json" <<JSON
{
  "schemaVersion": "1.0",
  "artifacts": {
    "batonc": {
      "version": "$version",
      "type": "executable",
      "variants": [
        { "path": "batonc-macos/bin/batonc", "supportedTriples": ["arm64-apple-macosx", "x86_64-apple-macosx"] }
      ]
    }
  }
}
JSON
(cd "$stage" && zip -qrX batonc.artifactbundle.zip batonc.artifactbundle)
echo "bundle at $stage/batonc.artifactbundle.zip" >&2
swift package --package-path "$root" compute-checksum "$stage/batonc.artifactbundle.zip"
