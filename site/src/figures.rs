//! The figures: directories under `site/figures/`, each a `baton.json` and
//! the host files beside it, compiled by `batonc` when a page first asks
//! for one. A page asks with a `{{directive}}` line, and every plate the
//! registry renders is program output: the host as the author wrote it,
//! the code the compiler generated from it, an operation's text, a lens's
//! accessors, a diagnostic, or a store the runtime dumped under the
//! fixtures.

use std::cell::{Cell, RefCell};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use serde_json::Value;

use crate::compiler::{Compiled, Compiler, Language, read};
use crate::escape::{escape, inline_markdown};
use crate::highlight::{graphql, highlight, label};
use crate::markdown::Context;
use crate::store::{self, Dump, RecordsOptions};

/// Every figure, compiled on first use.
pub struct Registry {
    compiler: Compiler,
    figures: PathBuf,
    root: PathBuf,
    compiled: RefCell<BTreeMap<(String, Language), Compiled>>,
    rendered: Cell<usize>,
}

impl Registry {
    pub fn new(root: &Path, work: &Path) -> Registry {
        Registry {
            compiler: Compiler::locate(root, work),
            figures: root.join("site/figures"),
            root: root.to_path_buf(),
            compiled: RefCell::new(BTreeMap::new()),
            rendered: Cell::new(0),
        }
    }

    /// How many plates were rendered so far.
    pub fn rendered(&self) -> usize {
        self.rendered.get()
    }

    /// The compiler, for the gallery's own runs.
    pub fn compiler(&self) -> &Compiler {
        &self.compiler
    }

    /// Every figure's name, in directory order.
    pub fn names(&self) -> Vec<String> {
        let mut names: Vec<String> = std::fs::read_dir(&self.figures)
            .expect("site/figures")
            .filter_map(|entry| entry.ok())
            .filter(|entry| entry.path().is_dir())
            .map(|entry| entry.file_name().to_string_lossy().to_string())
            .collect();
        names.sort();
        names
    }

    fn directory(&self, name: &str) -> Result<PathBuf, String> {
        let dir = self.figures.join(name);
        if dir.is_dir() {
            Ok(dir)
        } else {
            Err(format!("no figure named {name}"))
        }
    }

    /// The languages a figure has hosts for.
    fn languages(&self, name: &str) -> Result<Vec<Language>, String> {
        Ok(Compiler::languages(&self.directory(name)?))
    }

    /// The figure compiled in one language, from the cache or now.
    fn compiled(&self, name: &str, language: Language) -> Result<Compiled, String> {
        let key = (name.to_string(), language);
        if let Some(compiled) = self.compiled.borrow().get(&key) {
            return Ok(compiled.clone());
        }
        let dir = self.directory(name)?;
        let compiled = self.compiler.compile(name, &dir, language);
        self.compiled.borrow_mut().insert(key, compiled.clone());
        Ok(compiled)
    }

    /// A figure in every language it has, each compiled without error
    /// unless `allow_errors`.
    fn all(&self, name: &str, allow_errors: bool) -> Result<Vec<Compiled>, String> {
        let mut runs = Vec::new();
        for language in self.languages(name)? {
            let compiled = self.compiled(name, language)?;
            if !compiled.ok && !allow_errors {
                return Err(format!(
                    "the figure {name} does not compile in {}:\n{}",
                    language.flag(),
                    compiled.diagnostics
                ));
            }
            runs.push(compiled);
        }
        Ok(runs)
    }

    /// Expands one `{{kind arguments | caption}}` directive.
    pub fn directive(
        &self,
        kind: &str,
        arguments: &[&str],
        caption: Option<&str>,
        context: &Context,
        plates: &Cell<usize>,
        scripts: &mut Vec<String>,
    ) -> Result<String, String> {
        let next = || {
            plates.set(plates.get() + 1);
            plates.get()
        };
        let first = || {
            arguments
                .first()
                .copied()
                .ok_or_else(|| format!("{kind} needs a figure name"))
        };
        let option = |key: &str| -> Option<String> {
            arguments.iter().find_map(|argument| {
                argument
                    .strip_prefix(&format!("{key}="))
                    .map(str::to_string)
            })
        };
        let caption = caption.unwrap_or("");
        self.rendered.set(self.rendered.get() + 1);
        match kind {
            // The host files of a figure, SwiftUI beside Compose.
            "host" => {
                let name = first()?;
                let runs = self.all(name, true)?;
                let file = arguments.get(1).filter(|word| !word.contains('=')).copied();
                let inner = language_tabs(&runs, |compiled| {
                    let hosts: Vec<&crate::compiler::File> = compiled
                        .hosts
                        .iter()
                        .filter(|host| file.is_none_or(|file| named(&host.name, file)))
                        .collect();
                    if hosts.is_empty() {
                        return None;
                    }
                    Some(
                        hosts
                            .iter()
                            .map(|host| file_block(&host.name, &host.text))
                            .collect::<Vec<_>>()
                            .join(""),
                    )
                });
                Ok(plate(next(), &inner, caption, "host-plate"))
            }
            // What the compiler generated from the figure's documents.
            "generated" => {
                let name = first()?;
                let runs = self.all(name, false)?;
                let file = arguments.get(1).filter(|word| !word.contains('=')).copied();
                let shared = arguments.contains(&"shared");
                let inner = language_tabs(&runs, |compiled| {
                    let outputs: Vec<&crate::compiler::File> = compiled
                        .outputs
                        .iter()
                        .filter(|output| {
                            let is_shared = output.name.starts_with("Baton.baton.");
                            match file {
                                Some(file) => named(&output.name, file),
                                None => is_shared == shared,
                            }
                        })
                        .collect();
                    if outputs.is_empty() {
                        return None;
                    }
                    Some(
                        outputs
                            .iter()
                            .map(|output| file_block(&output.name, &output.text))
                            .collect::<Vec<_>>()
                            .join(""),
                    )
                });
                Ok(plate(next(), &inner, caption, "generated-plate"))
            }
            // An operation's text, as the compiler prints it: the request.
            "operation" => {
                let name = first()?;
                let operation = arguments
                    .get(1)
                    .ok_or("operation needs an operation name")?;
                let runs = self.all(name, false)?;
                let compiled = runs.first().ok_or("no language")?;
                let text = compiled
                    .operations
                    .get(*operation)
                    .ok_or_else(|| format!("{name} has no operation {operation}"))?;
                let report = compiled.report.as_ref().ok_or("no report")?;
                let entry = report["operations"]
                    .as_array()
                    .into_iter()
                    .flatten()
                    .find(|entry| entry["name"].as_str() == Some(operation))
                    .ok_or("the report lacks the operation")?;
                Ok(plate(
                    next(),
                    &operation_html(entry, text),
                    caption,
                    "operation-plate",
                ))
            }
            // A lens: the accessors a fragment or an operation root reads.
            "lens" => {
                let name = first()?;
                let which = arguments
                    .get(1)
                    .ok_or("lens needs a fragment or operation name")?;
                let runs = self.all(name, false)?;
                let compiled = runs.first().ok_or("no language")?;
                let report = compiled.report.as_ref().ok_or("no report")?;
                let (lens, kind_word) = find_lens(report, which)
                    .ok_or_else(|| format!("{name} has no lens for {which}"))?;
                let mut inner = format!(
                    "<p class=\"lens-title\">The lens of <code>{}</code>, {kind_word}, reads a record of type <code>{}</code>:</p>",
                    escape(which),
                    escape(lens["type"].as_str().unwrap_or(""))
                );
                inner.push_str(&lens_html(lens, 0));
                Ok(plate(next(), &inner, caption, "lens-plate"))
            }
            // The diagnostics of a figure with an error in it, pointing
            // into the host.
            "diagnostics" => {
                let name = first()?;
                let runs = self.all(name, true)?;
                let compiled = runs.first().ok_or("no language")?;
                Ok(plate(
                    next(),
                    &diagnostics_html(compiled),
                    caption,
                    "diagnostics-plate",
                ))
            }
            // A repository file as code.
            "source" => {
                let path = first()?;
                let full = self.root.join(path);
                let text = read(&full);
                let text = match option("lines") {
                    Some(range) => slice_lines(&text, &range),
                    None => text,
                };
                let language = path.rsplit('.').next().unwrap_or("");
                let language = match language {
                    "kt" => "kotlin",
                    "graphql" | "gql" => "graphql",
                    other => other,
                };
                let inner = file_block_named(path, &text, language);
                Ok(plate(next(), &inner, caption, "source-plate"))
            }
            // A JSON file from the repository, pretty printed.
            "json" => {
                let path = first()?;
                let text = read(&self.root.join(path));
                let value: Value =
                    serde_json::from_str(&text).map_err(|error| format!("{path}: {error}"))?;
                let pretty = serde_json::to_string_pretty(&value).unwrap_or(text);
                Ok(plate(
                    next(),
                    &file_block_named(path, &pretty, "json"),
                    caption,
                    "json-plate",
                ))
            }
            // A case of the specification's manifest: what a lens must read
            // at each path after the response, and the leaf an optimistic
            // response overrides.
            "case" => {
                let name = first()?;
                let manifest: Value =
                    serde_json::from_str(&read(&self.root.join("spec/manifest.json")))
                        .map_err(|error| format!("spec/manifest.json: {error}"))?;
                let case = manifest["cases"]
                    .as_array()
                    .into_iter()
                    .flatten()
                    .find(|case| case["name"].as_str() == Some(name))
                    .ok_or_else(|| format!("no case named {name}"))?;
                Ok(plate(next(), &case_html(case), caption, "case-plate"))
            }
            // A dump from `spec/` as records.
            "records" => {
                let path = first()?;
                let dump = Dump::load(&self.root.join(path));
                let notified: Vec<(String, String)> = option("notified")
                    .map(|list| {
                        list.split(',')
                            .filter_map(|item| {
                                let (record, field) = item.rsplit_once('.')?;
                                Some((record.to_string(), field.to_string()))
                            })
                            .collect()
                    })
                    .unwrap_or_default();
                let only: Option<Vec<String>> =
                    option("only").map(|list| list.split(',').map(str::to_string).collect());
                let inner = store::records_html(
                    &dump,
                    &RecordsOptions {
                        notified: &notified,
                        only: only.as_deref(),
                        elide_roots: !arguments.contains(&"roots"),
                    },
                );
                Ok(plate(next(), &inner, caption, "records-plate"))
            }
            // A response beside the records it became.
            "normalize" => {
                let base = first()?;
                let root_key = option("root").unwrap_or_else(|| "client:root".to_string());
                let response = self.root.join(format!("{base}.json"));
                let dump = self.root.join(format!("{base}.store.json"));
                let inner = store::normalize_html(&response, &dump, &root_key);
                Ok(plate(next(), &inner, caption, "normalize-plate"))
            }
            // A script from `spec/scripts/`, step by step.
            "script" => {
                let name = first()?;
                let steps: Option<Vec<usize>> = option("steps").map(|list| {
                    list.split(',')
                        .filter_map(|item| item.parse().ok())
                        .collect()
                });
                let inner = store::script_html(&self.root, name, steps.as_deref());
                Ok(plate(next(), &inner, caption, "script-plate"))
            }
            // The interactive screen over real records.
            "stage" => {
                let name = first()?;
                let runs = self.all(name, false)?;
                let compiled = runs
                    .iter()
                    .find(|run| run.language == Language::Swift)
                    .or(runs.first())
                    .ok_or("no language")?;
                let operation = arguments.get(1).ok_or("stage needs an operation name")?;
                let dump = arguments.get(2).ok_or("stage needs a dump")?;
                let rows: usize = option("rows").and_then(|n| n.parse().ok()).unwrap_or(8);
                scripts.push("stage.js".to_string());
                let inner = crate::stage::html(compiled, operation, &self.root.join(dump), rows)?;
                Ok(plate(next(), &inner, caption, "stage-plate"))
            }
            // A benchmark chart drawn by the benchmark package.
            "chart" => {
                let name = first()?;
                let dark = format!("benchmarks/charts/{name}.svg");
                let light = format!("benchmarks/charts/{name}-light.svg");
                for path in [&dark, &light] {
                    if !self.root.join(path).exists() {
                        return Err(format!("no chart at {path}"));
                    }
                }
                let to = context.site.out.join("assets/charts");
                std::fs::create_dir_all(&to).expect("charts directory");
                for (path, file) in [
                    (&dark, format!("{name}.svg")),
                    (&light, format!("{name}-light.svg")),
                ] {
                    std::fs::copy(self.root.join(path), to.join(file)).expect("copy a chart");
                }
                let href = context.href(&format!("/assets/charts/{name}"));
                let inner = format!(
                    "<picture class=\"chart\"><source media=\"(prefers-color-scheme: dark)\" srcset=\"{href}.svg\"><img alt=\"{}\" src=\"{href}-light.svg\"></picture>",
                    escape(caption)
                );
                Ok(plate(next(), &inner, caption, "chart-plate"))
            }
            // The releases, named for bread, from the changelog.
            "releases" => Ok(plate(
                next(),
                &releases_html(&self.root),
                caption,
                "releases-plate",
            )),
            // The playground, driven by the wasm build.
            "playground" => {
                scripts.push("playground.js".to_string());
                Ok(playground_html(next()))
            }
            other => Err(format!("unknown directive {other}")),
        }
    }
}

/// Whether a file is the one a directive names: by its whole name, or by
/// its stem, so `IssueRow` names `IssueRow.swift` and `IssueRow.kt`.
fn named(name: &str, wanted: &str) -> bool {
    name == wanted
        || name.strip_suffix(".swift") == Some(wanted)
        || name.strip_suffix(".kt") == Some(wanted)
        || name.strip_suffix(".graphql") == Some(wanted)
        || name.strip_suffix(".baton.swift") == Some(wanted)
        || name.strip_suffix(".baton.kt") == Some(wanted)
        || name
            .rsplit('/')
            .next()
            .is_some_and(|base| base != name && named(base, wanted))
}

/// The first `a-b` lines of a text.
fn slice_lines(text: &str, range: &str) -> String {
    let (from, to) = range.split_once('-').unwrap_or((range, range));
    let from: usize = from.parse().unwrap_or(1);
    let to: usize = to.parse().unwrap_or(usize::MAX);
    text.lines()
        .enumerate()
        .filter(|(index, _)| index + 1 >= from && *index < to)
        .map(|(_, line)| line)
        .collect::<Vec<_>>()
        .join("\n")
}

/// A code block with its file name over it.
pub fn file_block(name: &str, text: &str) -> String {
    let language = match name.rsplit('.').next().unwrap_or("") {
        "swift" => "swift",
        "kt" => "kotlin",
        "graphql" | "gql" => "graphql",
        "json" => "json",
        other => other,
    };
    file_block_named(name, text, language)
}

pub fn file_block_named(name: &str, text: &str, language: &str) -> String {
    format!(
        "<div class=\"file\"><p class=\"file-name\">{}</p><div class=\"code\" data-lang=\"{}\"><pre><code>{}</code></pre></div></div>",
        escape(name),
        label(language),
        highlight(language, text.trim_end())
    )
}

/// SwiftUI beside Compose: one panel per language a figure has, or the
/// one language's content alone.
fn language_tabs(runs: &[Compiled], render: impl Fn(&Compiled) -> Option<String>) -> String {
    let panels: Vec<(Language, String)> = runs
        .iter()
        .filter_map(|compiled| render(compiled).map(|html| (compiled.language, html)))
        .collect();
    if panels.len() == 1 {
        return panels[0].1.clone();
    }
    let mut tabs = String::from(
        "<div class=\"panels\" data-group=\"language\"><div class=\"tabs\" role=\"tablist\">",
    );
    let mut bodies = String::new();
    for (index, (language, html)) in panels.iter().enumerate() {
        let selected = index == 0;
        tabs.push_str(&format!(
            "<button type=\"button\" role=\"tab\" aria-selected=\"{selected}\" data-panel=\"{}\" class=\"lang-{}\">{}</button>",
            language.key(),
            language.key(),
            language.label()
        ));
        bodies.push_str(&format!(
            "<div class=\"panel\" role=\"tabpanel\" data-panel=\"{}\"{}>{html}</div>",
            language.key(),
            if selected { "" } else { " hidden" }
        ));
    }
    tabs.push_str("</div>");
    format!("{tabs}{bodies}</div>")
}

/// An operation as the request it becomes: its variables, its text on one
/// line as the compiler prints it, and its id under `persistConfig`.
fn operation_html(entry: &Value, printed: &str) -> String {
    let name = entry["name"].as_str().unwrap_or("");
    let kind = entry["kind"].as_str().unwrap_or("");
    let variables: Vec<String> = entry["variables"]
        .as_array()
        .into_iter()
        .flatten()
        .map(|variable| {
            format!(
                "<code>${}: {}</code>",
                escape(variable["name"].as_str().unwrap_or("")),
                escape(variable["type"].as_str().unwrap_or(""))
            )
        })
        .collect();
    let fragments: Vec<String> = entry["fragments"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(Value::as_str)
        .map(|fragment| format!("<code>{}</code>", escape(fragment)))
        .collect();
    let mut out = format!(
        "<dl class=\"operation\"><dt>{kind}</dt><dd><code>{}</code></dd>",
        escape(name)
    );
    if !variables.is_empty() {
        out.push_str(&format!(
            "<dt>variables</dt><dd>{}</dd>",
            variables.join(" ")
        ));
    }
    if !fragments.is_empty() {
        out.push_str(&format!("<dt>spreads</dt><dd>{}</dd>", fragments.join(" ")));
    }
    let (id, text) = match printed.strip_prefix("# documentId: ") {
        Some(rest) => {
            let (id, text) = rest.split_once('\n').unwrap_or((rest, ""));
            (Some(id.trim()), text.trim())
        }
        None => (None, printed.trim()),
    };
    if let Some(id) = id {
        out.push_str(&format!("<dt>sent as</dt><dd><code>{}</code>, the text's hash; the text stays on the server</dd>", escape(id)));
    }
    out.push_str(&format!(
        "<dt>the text</dt><dd class=\"wire\"><code>{}</code></dd></dl>",
        graphql(text)
    ));
    out
}

/// The lens report of a fragment or an operation, by name.
fn find_lens<'a>(report: &'a Value, which: &str) -> Option<(&'a Value, &'static str)> {
    if let Some(fragment) = report["fragments"]
        .as_array()
        .into_iter()
        .flatten()
        .find(|entry| entry["name"].as_str() == Some(which))
    {
        return fragment.get("lens").map(|lens| (lens, "a fragment"));
    }
    report["operations"]
        .as_array()
        .into_iter()
        .flatten()
        .find(|entry| entry["name"].as_str() == Some(which))
        .and_then(|entry| entry.get("lens"))
        .map(|lens| (lens, "an operation's data"))
}

/// A lens's accessors as a table, nested lenses indented under theirs.
fn lens_html(lens: &Value, depth: usize) -> String {
    let mut out = String::new();
    if depth == 0 {
        out.push_str("<table class=\"lens\"><thead><tr><th>accessor</th><th>reads</th><th>as</th></tr></thead><tbody>");
    }
    for accessor in lens["accessors"].as_array().into_iter().flatten() {
        let name = accessor["name"].as_str().unwrap_or("");
        let key = accessor["key"].as_str();
        let read = accessor["read"].as_str().unwrap_or("");
        let mut shape = Vec::new();
        match read {
            "scalar" => shape.push("a scalar".to_string()),
            "linked" => shape.push(format!(
                "a lens of <code>{}</code>",
                escape(accessor["lens"]["type"].as_str().unwrap_or(""))
            )),
            "spread" => shape.push(format!(
                "the lens of <code>{}</code>",
                escape(accessor["fragment"].as_str().unwrap_or(""))
            )),
            "aliased" => shape.push(format!(
                "the lens of <code>{}</code>, under its alias",
                escape(accessor["fragment"].as_str().unwrap_or(""))
            )),
            "condition" => shape.push(format!(
                "a lens, when the record is a {}",
                accessor["types"]
                    .as_array()
                    .into_iter()
                    .flatten()
                    .filter_map(Value::as_str)
                    .map(|t| format!("<code>{}</code>", escape(t)))
                    .collect::<Vec<_>>()
                    .join(" or ")
            )),
            other => shape.push(other.to_string()),
        }
        if accessor["list"].is_object() {
            let optional_elements = accessor["list"]["optionalElements"]
                .as_bool()
                .unwrap_or(false);
            shape.push(if optional_elements {
                "a list, elements nullable".to_string()
            } else {
                "a list".to_string()
            });
        }
        if accessor["optional"].as_bool().unwrap_or(false) {
            shape.push("optional".to_string());
        }
        if accessor["caught"].is_object() {
            shape.push("a <code>Result</code>, under <code>@catch</code>".to_string());
        }
        if accessor["throws"].as_bool().unwrap_or(false) {
            shape.push("throws".to_string());
        }
        out.push_str(&format!(
            "<tr class=\"depth-{depth}\"><td><code>{}{}</code></td><td>{}</td><td>{}</td></tr>",
            "&nbsp;&nbsp;".repeat(depth),
            escape(name),
            key.map(|key| format!("<code>{}</code>", escape(key)))
                .unwrap_or_else(|| "<span class=\"muted\">the parent's record</span>".to_string()),
            shape.join(", ")
        ));
        if let Some(nested) = accessor.get("lens") {
            out.push_str(&lens_html(nested, depth + 1));
        }
    }
    if depth == 0 {
        out.push_str("</tbody></table>");
    }
    out
}

/// The diagnostics of a run, each pointing into the host file with the
/// line it names and a caret under the column.
fn diagnostics_html(compiled: &Compiled) -> String {
    let mut out = String::from("<div class=\"diagnostics\">");
    for host in &compiled.hosts {
        out.push_str(&file_block(&host.name, &host.text));
    }
    out.push_str("<pre class=\"term diagnostic\">");
    if compiled.diagnostics.is_empty() {
        out.push_str("<span class=\"ok\">no diagnostics: every document compiles</span>");
    }
    for line in compiled.diagnostics.lines() {
        let mut parts = line.splitn(4, ':');
        let (path, row, column, rest) = (
            parts.next().unwrap_or(""),
            parts.next().unwrap_or(""),
            parts.next().unwrap_or(""),
            parts.next().unwrap_or(""),
        );
        let (severity, message) = rest.trim().split_once(':').unwrap_or(("", rest));
        out.push_str(&format!(
            "<span class=\"where\">{}:{}:{}</span>: <span class=\"severity {}\">{}</span>:{}\n",
            escape(path),
            escape(row),
            escape(column),
            escape(severity.trim()),
            escape(severity.trim()),
            escape(message)
        ));
        let host = compiled.hosts.iter().find(|host| host.name == path);
        let position = (row.parse::<usize>(), column.parse::<usize>());
        if let (Some(host), (Ok(row), Ok(column))) = (host, position)
            && let Some(source) = host.text.lines().nth(row.saturating_sub(1))
        {
            out.push_str(&format!(
                "<span class=\"context\">{:>5} | {}</span>\n<span class=\"caret\">{}{}</span>\n",
                row,
                escape(source),
                " ".repeat(8 + column.saturating_sub(1)),
                "^"
            ));
        }
    }
    out.push_str("</pre></div>");
    out
}

/// A manifest case: the operation, its variables, and the reads a lens
/// must answer.
fn case_html(case: &Value) -> String {
    let variables = case["variables"]
        .as_object()
        .map(|variables| {
            variables
                .iter()
                .map(|(name, value)| format!("{name}: {value}"))
                .collect::<Vec<_>>()
                .join(", ")
        })
        .unwrap_or_default();
    let mut out = format!(
        "<p class=\"lens-title\">After the response to <code>{}({})</code> is committed, the lens the compiler generated must read:</p><table class=\"reads\"><thead><tr><th>path</th><th>value</th></tr></thead><tbody>",
        escape(case["operation"].as_str().unwrap_or("")),
        escape(&variables)
    );
    for read in case["reads"].as_array().into_iter().flatten() {
        let note = read
            .get("note")
            .and_then(Value::as_str)
            .map(|note| format!(" <span class=\"note\">{}</span>", escape(note)))
            .unwrap_or_default();
        out.push_str(&format!(
            "<tr><td><code>{}</code></td><td><code>{}</code>{note}</td></tr>",
            escape(read["path"].as_str().unwrap_or("")),
            escape(&read.get("value").map(Value::to_string).unwrap_or_default())
        ));
    }
    out.push_str("</tbody></table>");
    if let Some(override_) = case.get("override") {
        let paths: Vec<String> = override_["paths"]
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(Value::as_str)
            .map(|path| format!("<code>{}</code>", escape(path)))
            .collect();
        out.push_str(&format!(
            "<p class=\"lens-title\">and, under an optimistic response that overrides {}, read <code>{}</code> there until the layer is replaced or reverted.</p>",
            paths.join(", "),
            escape(&override_["value"].to_string())
        ));
    }
    out
}

/// The releases, each a bread, from the changelog's headings.
fn releases_html(root: &Path) -> String {
    let changelog = read(&root.join("CHANGELOG.md"));
    let mut out = String::from("<ol class=\"shelf\">");
    for line in changelog.lines() {
        let Some(heading) = line.strip_prefix("## ") else {
            continue;
        };
        let Some((version, rest)) = heading.split_once(" (") else {
            continue;
        };
        let Some((name, date)) = rest.split_once(")") else {
            continue;
        };
        let date = date.trim_start_matches([' ', '—', '-']).trim();
        out.push_str(&format!(
            "<li><span class=\"loaf\" aria-hidden=\"true\"></span><span class=\"bread\">{}</span><span class=\"version\">{}</span><span class=\"date\">{}</span></li>",
            escape(name),
            escape(version),
            escape(date)
        ));
    }
    out.push_str("</ol>");
    out
}

/// A numbered plate: the rendered reading and its caption.
pub fn plate(number: usize, inner: &str, caption: &str, class: &str) -> String {
    let mut out = format!("<figure class=\"plate {class}\">\n{inner}\n");
    if !caption.is_empty() {
        out.push_str(&format!(
            "<figcaption><span class=\"plate-number\">Plate {number}.</span> {}</figcaption>\n",
            inline_markdown(caption)
        ));
    }
    out.push_str("</figure>\n");
    out
}

fn playground_html(number: usize) -> String {
    format!(
        "<figure class=\"plate playground-plate\" id=\"playground\">\n\
         <div class=\"playground\">\n\
         <div class=\"editor\">\n\
         <div class=\"samples\" id=\"samples\"></div>\n\
         <textarea id=\"document\" spellcheck=\"false\" aria-label=\"The documents\" rows=\"18\"></textarea>\n\
         <p class=\"readout\" id=\"readout\"></p>\n\
         </div>\n\
         <div class=\"readings\" id=\"readings\"><p class=\"status\">Loading the compiler…</p></div>\n\
         </div>\n\
         <figcaption><span class=\"plate-number\">Plate {number}.</span> The documents on the left are compiled by `batonc` built to WebAssembly, against the Rick and Morty schema; every tab on the right is what the compiler wrote for them, remade as you type.</figcaption>\n\
         </figure>\n"
    )
}
