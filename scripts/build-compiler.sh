#!/bin/sh
# Builds batonc in release mode and assembles the local artifact bundle that
# Package.swift's binary target points at. Run after changing compiler/.
set -eu
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root/compiler"
cargo build --release
version="$(grep -m1 '^version = ' Cargo.toml | sed 's/version = "\(.*\)"/\1/')"
bundle="$root/compiler/dist/batonc.artifactbundle"
host="$(uname -m)"
case "$host" in
  arm64) triple="arm64-apple-macosx" ;;
  x86_64) triple="x86_64-apple-macosx" ;;
  *) echo "unsupported host: $host" >&2; exit 1 ;;
esac
mkdir -p "$bundle/batonc-macos-$host/bin"
cp target/release/batonc "$bundle/batonc-macos-$host/bin/batonc"
cat > "$bundle/info.json" <<JSON
{
  "schemaVersion": "1.0",
  "artifacts": {
    "batonc": {
      "version": "$version",
      "type": "executable",
      "variants": [
        { "path": "batonc-macos-$host/bin/batonc", "supportedTriples": ["$triple"] }
      ]
    }
  }
}
JSON
echo "bundle at $bundle ($(du -h target/release/batonc | cut -f1) binary)"
