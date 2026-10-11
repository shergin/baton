#!/bin/sh
# Build the site into site/dist: the compiler first, since the figures are
# compiled with it; then the generator (pages and plates); then the
# compiler again for WebAssembly, which the playground runs in the browser
# through a WASI shim. Serve with:
#   python3 -m http.server 4173 --directory site/dist
set -eu
root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
out="$root/site/dist"
cd "$root/compiler"
cargo build --release -q
cd "$root"
cargo run --release -q --manifest-path site/Cargo.toml -- --out "$out"
cd "$root/compiler"
cargo build --release -q --target wasm32-wasip1
mkdir -p "$out/playground"
cp target/wasm32-wasip1/release/batonc.wasm "$out/playground/batonc.wasm"
echo "built $out"
