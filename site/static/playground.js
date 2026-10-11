// The playground: the compiler built to WebAssembly, run on what the
// reader types. Loaded when the wasm build exists; until then the page
// says so.
const readings = document.getElementById("readings");
if (readings) {
  readings.innerHTML = '<p class="status">The playground needs the WebAssembly build of the compiler, which <code>site/build.sh</code> produces.</p>';
}
