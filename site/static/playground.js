// The playground: the compiler itself, built for wasm32-wasip1, run in
// the browser through a WASI shim over an in-memory file system. What the
// reader types is written as a `.graphql` host beside a `baton.json`, the
// same `generate` and `print` commands run as in a build, and the outputs
// are read back and shown: the Swift lens, the Kotlin lens, each
// operation's request, every lens's accessors from the report, and the
// diagnostics.

import { WASI, File, Directory, OpenFile, PreopenDirectory, ConsoleStdout } from "./wasi/index.js";
import { highlight, escape } from "./highlight.js";

const root = window.BATON_ROOT ?? "./";
const readings = document.getElementById("readings");
const editor = document.getElementById("document");
const readout = document.getElementById("readout");
const samples = document.getElementById("samples");
if (!readings || !editor) throw new Error("the playground's plate is missing");

const SAMPLES = [
  {
    name: "a header",
    text: `# A fragment beside a view, and the screen's query that spreads it.
fragment CharacterHeader_character on Character {
  name
  status
  species
  image
  origin { name }
}

query CharacterQuery($id: ID!) @cacheExpiration(seconds: 300) {
  character(id: $id) { ...CharacterHeader_character }
}
`,
  },
  {
    name: "a list",
    text: `# A row's fragment and a page of characters.
fragment CharacterRow_character on Character {
  name
  status
  species
  image
}

query CharactersQuery($page: Int) {
  characters(page: $page) {
    info { count pages next }
    results { id ...CharacterRow_character }
  }
}
`,
  },
  {
    name: "a value",
    text: `# An inline fragment compiles to a value, not a lens.
fragment CharacterValue_character on Character @inline {
  id
  name
  status
  episode { id }
}

query CharacterQuery($id: ID!) {
  character(id: $id) {
    name
    ...CharacterValue_character
  }
}
`,
  },
  {
    name: "required and aliased",
    text: `# @required moves a null to where the view wants it; @alias names the accessor.
fragment EpisodeRow_episode on Episode {
  name @required(action: THROW)
  air_date
  episode
}

query EpisodeQuery($id: ID!) {
  episode(id: $id) {
    ...EpisodeRow_episode @alias(as: "row")
    characters { id name }
  }
}
`,
  },
  {
    name: "a typo",
    text: `# A field the schema does not have.
fragment CharacterRow_character on Character {
  name
  speciez
}

query CharactersQuery($page: Int) {
  characters(page: $page) {
    results { id ...CharacterRow_character }
  }
}
`,
  },
];

const encoder = new TextEncoder();
const decoder = new TextDecoder();

let module = null;
let schema = null;

async function load() {
  readings.innerHTML = '<p class="status">Loading the compiler…</p>';
  const [compiled, sdl] = await Promise.all([
    WebAssembly.compileStreaming(fetch(`${root}playground/batonc.wasm`)),
    fetch(`${root}playground/schema.graphql`).then((response) => response.text()),
  ]);
  module = compiled;
  schema = sdl;
}

/// Runs `batonc` once over `files`, a map from name to text, in a fresh
/// in-memory directory, and returns the exit code, what it printed, and
/// every file in the directory afterwards.
async function run(args, files) {
  const entries = Object.entries(files).map(([name, text]) => [name, new File(encoder.encode(text))]);
  const directory = new PreopenDirectory(".", new Map(entries));
  let stdout = "";
  let stderr = "";
  const fds = [
    new OpenFile(new File([])),
    ConsoleStdout.lineBuffered((line) => {
      stdout += `${line}\n`;
    }),
    ConsoleStdout.lineBuffered((line) => {
      stderr += `${line}\n`;
    }),
    directory,
  ];
  const wasi = new WASI(["batonc", ...args], [], fds, { debug: false });
  const instance = await WebAssembly.instantiate(module, { wasi_snapshot_preview1: wasi.wasiImport });
  let code = 0;
  try {
    code = wasi.start(instance);
  } catch (error) {
    stderr += `${error}\n`;
    code = 1;
  }
  const outputs = {};
  const walk = (dir, prefix) => {
    for (const [name, node] of dir.contents) {
      if (node instanceof Directory) walk(node, `${prefix}${name}/`);
      else if (node instanceof File) outputs[`${prefix}${name}`] = decoder.decode(node.data);
    }
  };
  walk(directory.dir, "");
  return { code, stdout, stderr, outputs };
}

const HOST = "Playground.graphql";
const CONFIG = JSON.stringify({ schema: "schema.graphql", kotlin: { package: "app" } });

async function compile(text) {
  const files = { "schema.graphql": schema, "baton.json": CONFIG, [HOST]: text };
  const started = performance.now();
  const swift = await run(["generate", "--config", "baton.json", "--language", "swift", "--out", "out", "--report", "report.json", HOST], files);
  if (swift.code !== 0) {
    return { ok: false, diagnostics: swift.stderr, elapsed: performance.now() - started };
  }
  const kotlin = await run(["generate", "--config", "baton.json", "--language", "kotlin", "--out", "out", HOST], files);
  const report = JSON.parse(swift.outputs["report.json"] ?? "{}");
  const operations = [];
  for (const operation of report.operations ?? []) {
    const printed = await run(["print", operation.name, "--config", "baton.json", HOST], files);
    operations.push({ ...operation, printed: printed.stdout.trim() });
  }
  return {
    ok: true,
    swift: swift.outputs[`out/${HOST}.baton.swift`] ?? "",
    swiftShared: swift.outputs["out/Baton.baton.swift"] ?? "",
    kotlin: kotlin.outputs[`out/${HOST}.baton.kt`] ?? "",
    kotlinShared: kotlin.outputs["out/Baton.baton.kt"] ?? "",
    report,
    operations,
    diagnostics: swift.stderr + kotlin.stderr,
    elapsed: performance.now() - started,
  };
}

const code = (language, text) => `<div class="code" data-lang="${language === "swift" ? "Swift" : language === "kotlin" ? "Kotlin" : language === "graphql" ? "GraphQL" : "JSON"}"><pre><code>${highlight(language, text)}</code></pre></div>`;

function shape(accessor) {
  const parts = [];
  switch (accessor.read) {
    case "scalar":
      parts.push("a scalar");
      break;
    case "linked":
      parts.push(`a lens of <code>${escape(accessor.lens?.type ?? "")}</code>`);
      break;
    case "spread":
      parts.push(`the lens of <code>${escape(accessor.fragment ?? "")}</code>`);
      break;
    case "aliased":
      parts.push(`the lens of <code>${escape(accessor.fragment ?? "")}</code>, under its alias`);
      break;
    case "condition":
      parts.push(`a lens, when the record is a ${(accessor.types ?? []).map((t) => `<code>${escape(t)}</code>`).join(" or ")}`);
      break;
    default:
      parts.push(escape(accessor.read ?? ""));
  }
  if (accessor.list) parts.push(accessor.list.optionalElements ? "a list, elements nullable" : "a list");
  if (accessor.optional) parts.push("optional");
  if (accessor.caught) parts.push("a <code>Result</code>, under <code>@catch</code>");
  if (accessor.throws) parts.push("throws");
  return parts.join(", ");
}

function lensRows(lens, depth) {
  let rows = "";
  for (const accessor of lens.accessors ?? []) {
    rows += `<tr><td><code>${"&nbsp;&nbsp;".repeat(depth)}${escape(accessor.name)}</code></td><td>${accessor.key ? `<code>${escape(accessor.key)}</code>` : '<span class="muted">the parent\'s record</span>'}</td><td>${shape(accessor)}</td></tr>`;
    if (accessor.lens) rows += lensRows(accessor.lens, depth + 1);
  }
  return rows;
}

function lensTables(report) {
  let out = "";
  for (const fragment of report.fragments ?? []) {
    if (!fragment.lens) continue;
    out += `<p class="lens-title">The lens of <code>${escape(fragment.name)}</code>, a fragment on <code>${escape(fragment.type)}</code>:</p><table class="lens"><thead><tr><th>accessor</th><th>reads</th><th>as</th></tr></thead><tbody>${lensRows(fragment.lens, 0)}</tbody></table>`;
  }
  for (const operation of report.operations ?? []) {
    if (!operation.lens) continue;
    out += `<p class="lens-title">The data of <code>${escape(operation.name)}</code>, ${escape(operation.kind)}:</p><table class="lens"><thead><tr><th>accessor</th><th>reads</th><th>as</th></tr></thead><tbody>${lensRows(operation.lens, 0)}</tbody></table>`;
  }
  return out || '<p class="status">No lens: nothing compiled.</p>';
}

function requests(operations) {
  if (operations.length === 0) return '<p class="status">No operation: write a query to see what the server receives.</p>';
  return operations
    .map((operation) => {
      const variables = (operation.variables ?? []).map((v) => `<code>$${escape(v.name)}: ${escape(v.type)}</code>`).join(" ");
      const fragments = (operation.fragments ?? []).map((f) => `<code>${escape(f)}</code>`).join(" ");
      return `<dl class="operation"><dt>${escape(operation.kind)}</dt><dd><code>${escape(operation.name)}</code></dd>${variables ? `<dt>variables</dt><dd>${variables}</dd>` : ""}${fragments ? `<dt>spreads</dt><dd>${fragments}</dd>` : ""}<dt>the text</dt><dd class="wire"><code>${highlight("graphql", operation.printed)}</code></dd></dl>`;
    })
    .join("");
}

function diagnostics(text, source) {
  if (!text.trim()) return '<pre class="term diagnostic"><span class="ok">no diagnostics: every document compiles</span></pre>';
  const lines = source.split("\n");
  let out = "";
  for (const line of text.trim().split("\n")) {
    const match = line.match(/^([^:]+):(\d+):(\d+): (\w+): (.*)$/);
    if (!match) {
      out += `${escape(line)}\n`;
      continue;
    }
    const [, path, row, column, severity, message] = match;
    out += `<span class="where">${escape(path)}:${row}:${column}</span>: <span class="severity ${severity}">${severity}</span>: ${escape(message)}\n`;
    const sourceLine = lines[Number(row) - 1];
    if (sourceLine !== undefined) {
      out += `<span class="context">${String(row).padStart(5)} | ${escape(sourceLine)}</span>\n<span class="caret">${" ".repeat(8 + Number(column) - 1)}^</span>\n`;
    }
  }
  return `<pre class="term diagnostic">${out}</pre>`;
}

let selected = "swift";

function render(result, source) {
  const panels = result.ok
    ? [
        ["swift", "Swift", code("swift", result.swift)],
        ["kotlin", "Kotlin", code("kotlin", result.kotlin)],
        ["request", "The request", requests(result.operations)],
        ["lenses", "The lenses", lensTables(result.report)],
        ["shared", "The shared file", code("swift", result.swiftShared)],
        ["diagnostics", "Diagnostics", diagnostics(result.diagnostics, source)],
      ]
    : [["diagnostics", "Diagnostics", diagnostics(result.diagnostics, source)]];
  if (!panels.some(([key]) => key === selected)) selected = panels[0][0];
  let tabs = '<div class="tabs" role="tablist">';
  let bodies = "";
  for (const [key, label, html] of panels) {
    const on = key === selected;
    tabs += `<button type="button" role="tab" aria-selected="${on}" data-panel="${key}" class="lang-${key}">${label}</button>`;
    bodies += `<div class="panel" role="tabpanel" data-panel="${key}"${on ? "" : " hidden"}>${html}</div>`;
  }
  tabs += "</div>";
  readings.innerHTML = `<div class="panels">${tabs}${bodies}</div>`;
  for (const tab of readings.querySelectorAll(".tabs > button")) {
    tab.addEventListener("click", () => {
      selected = tab.dataset.panel;
      for (const other of readings.querySelectorAll(".tabs > button")) other.setAttribute("aria-selected", String(other === tab));
      for (const body of readings.querySelectorAll(".panel")) body.hidden = body.dataset.panel !== selected;
    });
  }
  window.batonWire?.(readings);
  const operations = result.report?.operations?.length ?? 0;
  const fragments = result.report?.fragments?.length ?? 0;
  readout.classList.toggle("error", !result.ok);
  readout.textContent = result.ok
    ? `compiled in ${result.elapsed.toFixed(0)} ms: ${operations} operation${operations === 1 ? "" : "s"}, ${fragments} fragment${fragments === 1 ? "" : "s"}, two languages`
    : `the documents have errors; nothing was written (${result.elapsed.toFixed(0)} ms)`;
}

let timer = null;
let running = false;
let pending = false;

async function recompile() {
  if (running) {
    pending = true;
    return;
  }
  running = true;
  try {
    const source = editor.value;
    const result = await compile(source);
    render(result, source);
  } catch (error) {
    readings.innerHTML = `<p class="status error">The compiler could not run: ${escape(String(error))}</p>`;
  } finally {
    running = false;
    if (pending) {
      pending = false;
      recompile();
    }
  }
}

function schedule() {
  window.clearTimeout(timer);
  timer = window.setTimeout(recompile, 350);
}

// The samples, and the document from the address bar when there is one.
for (const sample of SAMPLES) {
  const button = document.createElement("button");
  button.type = "button";
  button.textContent = sample.name;
  button.addEventListener("click", () => {
    editor.value = sample.text;
    for (const other of samples.querySelectorAll("button")) other.setAttribute("aria-pressed", String(other === button));
    history.replaceState(null, "", "#");
    schedule();
  });
  samples.append(button);
}
const fromHash = new URLSearchParams(location.hash.slice(1)).get("document");
editor.value = fromHash ?? SAMPLES[0].text;
samples.querySelector("button")?.setAttribute("aria-pressed", String(!fromHash));
editor.addEventListener("input", () => {
  for (const other of samples.querySelectorAll("button")) other.setAttribute("aria-pressed", "false");
  const parameters = new URLSearchParams();
  parameters.set("document", editor.value);
  history.replaceState(null, "", `#${parameters}`);
  schedule();
});
editor.addEventListener("keydown", (event) => {
  if (event.key === "Tab") {
    event.preventDefault();
    const { selectionStart, selectionEnd, value } = editor;
    editor.value = `${value.slice(0, selectionStart)}  ${value.slice(selectionEnd)}`;
    editor.selectionStart = editor.selectionEnd = selectionStart + 2;
    schedule();
  }
});

try {
  await load();
  await recompile();
} catch (error) {
  readings.innerHTML = `<p class="status error">The playground needs the compiler's WebAssembly build, which <code>site/build.sh</code> produces: ${escape(String(error))}</p>`;
}
