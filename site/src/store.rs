//! The store plates: a dump from `spec/` as records, a response beside the
//! records it became with every field linked to its slot, and a script
//! from `spec/scripts/` as the steps the runtime took and what each left.
//! The dumps are the runtime's own, written under the fixtures; nothing
//! here normalizes anything.

use std::collections::BTreeMap;
use std::path::Path;

use serde_json::{Map, Value};

use crate::escape::{escape, inline_markdown};
use crate::highlight::highlight;

/// A store dump: records by key, in the file's order, which is sorted.
pub struct Dump {
    pub records: Vec<(String, Map<String, Value>)>,
}

impl Dump {
    pub fn load(path: &Path) -> Dump {
        let text = crate::compiler::read(path);
        let value: Value = serde_json::from_str(&text)
            .unwrap_or_else(|error| panic!("{}: {error}", path.display()));
        let records = value
            .as_object()
            .expect("a dump is an object of records")
            .iter()
            .map(|(key, record)| {
                (
                    key.clone(),
                    record.as_object().cloned().unwrap_or_default(),
                )
            })
            .collect();
        Dump { records }
    }

    pub fn record(&self, key: &str) -> Option<&Map<String, Value>> {
        self.records
            .iter()
            .find(|(record_key, _)| record_key == key)
            .map(|(_, record)| record)
    }

    /// The storage key of `record` that answers the response field
    /// `field`: the field's own name, or the one with its arguments.
    pub fn storage_key<'a>(&self, record: &'a Map<String, Value>, field: &str) -> Option<&'a str> {
        if record.contains_key(field) {
            return Some(record.keys().find(|key| key.as_str() == field)?.as_str());
        }
        let prefix = format!("{field}(");
        record
            .keys()
            .find(|key| key.starts_with(&prefix))
            .map(String::as_str)
    }
}

/// How a set of records is drawn.
#[derive(Default)]
pub struct RecordsOptions<'a> {
    /// Fields to mark as notified, by record key and storage key.
    pub notified: &'a [(String, String)],
    /// Record keys to draw, in the dump's order; every record when empty.
    pub only: Option<&'a [String]>,
    /// Records the dump holds that are left out, named so the caption can
    /// say so.
    pub elide_roots: bool,
}

/// The records of a dump as cards.
pub fn records_html(dump: &Dump, options: &RecordsOptions) -> String {
    let mut out = String::from("<div class=\"records\">");
    let mut shown = 0;
    for (key, record) in &dump.records {
        if let Some(only) = options.only {
            if !only.iter().any(|wanted| wanted == key) {
                continue;
            }
        }
        if options.elide_roots && (key == "client:root:mutation" || key == "client:root:subscription") {
            let empty = record.len() <= 1;
            if empty {
                continue;
            }
        }
        shown += 1;
        out.push_str(&record_html(key, record, options));
    }
    if shown == 0 {
        out.push_str("<p class=\"empty\">No records.</p>");
    }
    out.push_str("</div>");
    out
}

fn record_html(key: &str, record: &Map<String, Value>, options: &RecordsOptions) -> String {
    let typename = record
        .get("__typename")
        .and_then(Value::as_str)
        .unwrap_or("");
    let is_root = key.starts_with("client:root");
    let mut out = format!(
        "<div class=\"record{}\" id=\"record-{}\" data-key=\"{}\"><div class=\"record-key\"><span class=\"key\">{}</span><span class=\"typename\">{}</span></div><table>",
        if is_root { " root" } else { "" },
        escape(&slugify(key)),
        escape(key),
        escape(key),
        escape(typename)
    );
    for (field, value) in record {
        if field == "__typename" {
            continue;
        }
        let notified = options
            .notified
            .iter()
            .any(|(record_key, storage_key)| record_key == key && storage_key == field);
        let classes = [
            if notified { "is-notified" } else { "" },
            if field.starts_with("__") { "client" } else { "" },
        ];
        let class = classes.iter().filter(|c| !c.is_empty()).cloned().collect::<Vec<_>>().join(" ");
        out.push_str(&format!(
            "<tr class=\"{class}\" data-record=\"{}\" data-field=\"{}\"><th>{}</th><td>{}</td></tr>",
            escape(key),
            escape(field),
            escape(field),
            value_html(value)
        ));
    }
    out.push_str("</table></div>");
    out
}

/// A stored value: a link, links, a scalar or an error list.
fn value_html(value: &Value) -> String {
    if let Some(object) = value.as_object() {
        if let Some(target) = object.get("__ref").and_then(Value::as_str) {
            return ref_html(target);
        }
        if let Some(targets) = object.get("__refs").and_then(Value::as_array) {
            if targets.is_empty() {
                return "<span class=\"refs\">[ ]</span>".to_string();
            }
            let items: Vec<String> = targets
                .iter()
                .filter_map(Value::as_str)
                .map(ref_html)
                .collect();
            return format!("<span class=\"refs\">[ {} ]</span>", items.join(", "));
        }
        if object.is_empty() {
            return "<span class=\"scalar\">{}</span>".to_string();
        }
    }
    match value {
        Value::Null => "<span class=\"null\">null</span>".to_string(),
        Value::String(text) => {
            let shown: String = if text.chars().count() > 56 {
                let mut cut: String = text.chars().take(52).collect();
                cut.push('…');
                cut
            } else {
                text.clone()
            };
            format!(
                "<span class=\"string\" title=\"{}\">\"{}\"</span>",
                escape(text),
                escape(&shown)
            )
        }
        Value::Number(number) => format!("<span class=\"number\">{number}</span>"),
        Value::Bool(flag) => format!("<span class=\"bool\">{flag}</span>"),
        other => format!("<span class=\"scalar\">{}</span>", escape(&other.to_string())),
    }
}

fn ref_html(target: &str) -> String {
    format!(
        "<a class=\"ref\" href=\"#record-{}\" data-ref=\"{}\">{}</a>",
        escape(&slugify(target)),
        escape(target),
        escape(target)
    )
}

/// A record key as an element id.
pub fn slugify(key: &str) -> String {
    key.chars()
        .map(|c| if c.is_alphanumeric() { c } else { '-' })
        .collect()
}

/// A response's JSON, pretty printed, each key and leaf carrying its path
/// so a hover can find its slot.
pub fn response_html(value: &Value) -> String {
    let mut out = String::new();
    print_value(value, "", 0, &mut out, true);
    format!("<pre class=\"term response\"><code>{out}</code></pre>")
}

fn print_value(value: &Value, path: &str, depth: usize, out: &mut String, last: bool) {
    let comma = if last { "" } else { "," };
    match value {
        Value::Object(map) => {
            if map.is_empty() {
                out.push_str(&format!("{{}}{comma}"));
                return;
            }
            out.push_str("{\n");
            let count = map.len();
            for (index, (key, child)) in map.iter().enumerate() {
                let child_path = if path.is_empty() {
                    key.clone()
                } else {
                    format!("{path}.{key}")
                };
                out.push_str(&"  ".repeat(depth + 1));
                out.push_str(&format!(
                    "<span class=\"jk\" data-path=\"{}\">\"{}\"</span>: ",
                    escape(&child_path),
                    escape(key)
                ));
                print_value(child, &child_path, depth + 1, out, index + 1 == count);
                out.push('\n');
            }
            out.push_str(&"  ".repeat(depth));
            out.push_str(&format!("}}{comma}"));
        }
        Value::Array(items) => {
            if items.is_empty() {
                out.push_str(&format!("[]{comma}"));
                return;
            }
            out.push_str("[\n");
            let count = items.len();
            for (index, child) in items.iter().enumerate() {
                let child_path = format!("{path}.{index}");
                out.push_str(&"  ".repeat(depth + 1));
                print_value(child, &child_path, depth + 1, out, index + 1 == count);
                out.push('\n');
            }
            out.push_str(&"  ".repeat(depth));
            out.push_str(&format!("]{comma}"));
        }
        leaf => {
            let class = match leaf {
                Value::String(_) => "s",
                Value::Number(_) => "n",
                Value::Bool(_) | Value::Null => "k",
                _ => "",
            };
            out.push_str(&format!(
                "<span class=\"jv {class}\" data-path=\"{}\">{}</span>{comma}",
                escape(path),
                escape(&leaf.to_string())
            ));
        }
    }
}

/// Where each path of a response landed: the record and the storage key,
/// found by walking the response and the dump together from the root
/// record. A link's path maps to the slot that holds the link.
pub fn link_map(response: &Value, dump: &Dump, root_key: &str) -> BTreeMap<String, (String, String)> {
    let mut map = BTreeMap::new();
    if let Some(data) = response.get("data") {
        if let Some(root) = dump.record(root_key) {
            walk(data, "data", root_key, root, dump, &mut map);
        }
    }
    map
}

fn walk(
    value: &Value,
    path: &str,
    record_key: &str,
    record: &Map<String, Value>,
    dump: &Dump,
    map: &mut BTreeMap<String, (String, String)>,
) {
    let Some(object) = value.as_object() else {
        return;
    };
    for (field, child) in object {
        let child_path = format!("{path}.{field}");
        let Some(storage_key) = dump.storage_key(record, field) else {
            continue;
        };
        map.insert(
            child_path.clone(),
            (record_key.to_string(), storage_key.to_string()),
        );
        let stored = &record[storage_key];
        if let Some(target) = stored.get("__ref").and_then(Value::as_str) {
            if let Some(target_record) = dump.record(target) {
                walk(child, &child_path, target, target_record, dump, map);
            }
        } else if let (Some(targets), Some(items)) = (
            stored.get("__refs").and_then(Value::as_array),
            child.as_array(),
        ) {
            for (index, (target, item)) in targets.iter().zip(items).enumerate() {
                if let Some(target) = target.as_str() {
                    if let Some(target_record) = dump.record(target) {
                        let item_path = format!("{child_path}.{index}");
                        map.insert(
                            item_path.clone(),
                            (target.to_string(), "".to_string()),
                        );
                        walk(item, &item_path, target, target_record, dump, map);
                    }
                }
            }
        }
    }
}

/// A response beside the records it became, linked both ways.
pub fn normalize_html(response_path: &Path, dump_path: &Path, root_key: &str) -> String {
    let text = crate::compiler::read(response_path);
    let response: Value = serde_json::from_str(&text)
        .unwrap_or_else(|error| panic!("{}: {error}", response_path.display()));
    let dump = Dump::load(dump_path);
    let map = link_map(&response, &dump, root_key);
    let json = serde_json::to_string(&map).expect("the link map serializes");
    format!(
        "<div class=\"normalize\"><div class=\"side\"><p class=\"side-title\">The response</p>{}</div><div class=\"side\"><p class=\"side-title\">The records</p>{}</div><script type=\"application/json\" class=\"link-map\">{}</script></div>",
        response_html(&response),
        records_html(&dump, &RecordsOptions { notified: &[], only: None, elide_roots: true }),
        json.replace("</", "<\\/")
    )
}

/// A script from `spec/scripts/`, as steps.
pub fn script_html(root: &Path, name: &str, steps_wanted: Option<&[usize]>) -> String {
    let path = root.join("spec/scripts").join(format!("{name}.json"));
    let script: Value = serde_json::from_str(&crate::compiler::read(&path))
        .unwrap_or_else(|error| panic!("{}: {error}", path.display()));
    let steps = script["steps"].as_array().expect("steps");
    let mut tabs = String::from("<div class=\"tabs steps\" role=\"tablist\">");
    let mut panels = String::new();
    let mut shown = 0;
    for (index, step) in steps.iter().enumerate() {
        if let Some(wanted) = steps_wanted {
            if !wanted.contains(&(index + 1)) {
                continue;
            }
        }
        let Some(object) = step.as_object() else {
            continue;
        };
        let Some((kind, arguments)) = object.iter().find(|(key, _)| is_step(key)) else {
            continue;
        };
        let selected = shown == 0;
        shown += 1;
        tabs.push_str(&format!(
            "<button type=\"button\" role=\"tab\" aria-selected=\"{selected}\" data-panel=\"{index}\"><span class=\"step-number\">{}</span> {}</button>",
            index + 1,
            escape(kind)
        ));
        let mut panel = format!(
            "<div class=\"panel step\" role=\"tabpanel\" data-panel=\"{index}\"{}>",
            if selected { "" } else { " hidden" }
        );
        panel.push_str(&format!(
            "<p class=\"step-says\">{}</p>",
            inline_markdown(&describe_step(kind, arguments))
        ));
        if let Some(response) = arguments.get("response").and_then(Value::as_str) {
            let response_path = root.join("spec").join(response);
            if response_path.exists() {
                let text = crate::compiler::read(&response_path);
                let pretty: Value = serde_json::from_str(&text).unwrap_or(Value::Null);
                panel.push_str(&format!(
                    "<details class=\"source\"><summary>{}</summary><div class=\"code\" data-lang=\"JSON\"><pre><code>{}</code></pre></div></details>",
                    escape(response),
                    highlight("json", &serde_json::to_string_pretty(&pretty).unwrap_or_default())
                ));
            }
        }
        let notified: Vec<(String, String)> = object
            .get("notified")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .filter_map(|entry| {
                Some((
                    entry["record"].as_str()?.to_string(),
                    entry["field"].as_str()?.to_string(),
                ))
            })
            .collect();
        if let Some(notified_list) = object.get("notified").and_then(Value::as_array) {
            if notified_list.is_empty() {
                panel.push_str("<p class=\"notified\"><span class=\"notified-title\">Notified</span> <span class=\"nothing\">nothing: no observed field changed, so no body runs</span></p>");
            } else {
                let chips: Vec<String> = notified
                    .iter()
                    .map(|(record, field)| {
                        format!(
                            "<span class=\"chip notified-chip\"><span class=\"chip-record\">{}</span>.{}</span>",
                            escape(record),
                            escape(field)
                        )
                    })
                    .collect();
                panel.push_str(&format!(
                    "<p class=\"notified\"><span class=\"notified-title\">Notified</span> {}</p>",
                    chips.join(" ")
                ));
            }
        }
        if let Some(phase) = object.get("phase") {
            panel.push_str(&format!(
                "<p class=\"facts\"><span class=\"notified-title\">Phase</span> <code>{}</code></p>",
                escape(&compact(phase))
            ));
        }
        if let Some(fetch) = object.get("fetch") {
            panel.push_str(&format!(
                "<p class=\"facts\"><span class=\"notified-title\">Fetch</span> <code>{}</code></p>",
                escape(&compact(fetch))
            ));
        }
        if let Some(stream) = object.get("stream") {
            panel.push_str(&format!(
                "<p class=\"facts\"><span class=\"notified-title\">Stream</span> <code>{}</code></p>",
                escape(&compact(stream))
            ));
        }
        if let Some(sent) = object.get("sent").and_then(Value::as_array) {
            if sent.is_empty() {
                panel.push_str("<p class=\"facts\"><span class=\"notified-title\">Sent</span> <span class=\"nothing\">nothing</span></p>");
            }
            for request in sent {
                panel.push_str(&format!(
                    "<p class=\"facts\"><span class=\"notified-title\">Sent</span> <code>{}</code></p><div class=\"code\" data-lang=\"JSON\"><pre><code>{}</code></pre></div>",
                    escape(request["operation"].as_str().unwrap_or("")),
                    highlight("json", request["body"].as_str().unwrap_or(""))
                ));
            }
        }
        if let Some(error) = object.get("error") {
            panel.push_str(&format!(
                "<p class=\"facts\"><span class=\"notified-title\">The step throws</span> <code>{}</code></p>",
                escape(&compact(error))
            ));
        }
        if let Some(answer) = object.get("answer").filter(|value| value.is_string()) {
            panel.push_str(&format!(
                "<p class=\"facts\"><span class=\"notified-title\">The check answers</span> <code>{}</code></p>",
                escape(answer.as_str().unwrap_or(""))
            ));
        }
        if let Some(held) = object.get("records_held").and_then(Value::as_array) {
            let chips: Vec<String> = held
                .iter()
                .filter_map(Value::as_str)
                .map(|key| format!("<span class=\"chip\">{}</span>", escape(key)))
                .collect();
            panel.push_str(&format!(
                "<p class=\"facts\"><span class=\"notified-title\">Records held</span> {}</p>",
                chips.join(" ")
            ));
        }
        if let Some(events) = object.get("events").and_then(Value::as_array) {
            let names: Vec<String> = events
                .iter()
                .map(|event| match event {
                    Value::String(name) => name.clone(),
                    Value::Object(map) => map
                        .iter()
                        .map(|(name, fields)| format!("{name} {}", compact(fields)))
                        .collect::<Vec<_>>()
                        .join(", "),
                    other => other.to_string(),
                })
                .map(|name| format!("<code>{}</code>", escape(&name)))
                .collect();
            panel.push_str(&format!(
                "<p class=\"facts\"><span class=\"notified-title\">Logged</span> {}</p>",
                if names.is_empty() { "<span class=\"nothing\">nothing</span>".to_string() } else { names.join(" ") }
            ));
        }
        if let Some(reads) = object.get("reads").and_then(Value::as_array) {
            panel.push_str("<table class=\"reads\"><thead><tr><th>A lens reads</th><th>and finds</th></tr></thead><tbody>");
            for read in reads {
                let who = read
                    .get("handle")
                    .and_then(Value::as_str)
                    .map(|handle| format!("{handle} · "))
                    .unwrap_or_default();
                let path = read["path"].as_str().unwrap_or("");
                let value = read.get("value").map(compact).unwrap_or_default();
                let note = read
                    .get("note")
                    .and_then(Value::as_str)
                    .map(|note| format!(" <span class=\"note\">{}</span>", escape(note)))
                    .unwrap_or_default();
                panel.push_str(&format!(
                    "<tr><td><code>{}{}</code></td><td><code>{}</code>{note}</td></tr>",
                    escape(&who),
                    escape(path),
                    escape(&value)
                ));
            }
            panel.push_str("</tbody></table>");
        }
        if let Some(records) = object.get("records").and_then(Value::as_str) {
            let dump = Dump::load(&root.join("spec").join(records));
            panel.push_str(&format!(
                "<p class=\"records-title\">The store after the step, <code>{}</code></p>{}",
                escape(records),
                records_html(
                    &dump,
                    &RecordsOptions {
                        notified: &notified,
                        only: None,
                        elide_roots: true
                    }
                )
            ));
        }
        panel.push_str("</div>");
        panels.push_str(&panel);
    }
    tabs.push_str("</div>");
    format!("<div class=\"panels script\">{tabs}{panels}</div>")
}

fn is_step(key: &str) -> bool {
    matches!(
        key,
        "commit"
            | "payload"
            | "optimistic"
            | "resolve"
            | "revert"
            | "attach"
            | "answer"
            | "refetch"
            | "retry"
            | "release"
            | "collect"
            | "advance"
            | "invalidate"
            | "revalidate"
            | "check"
            | "relaunch"
            | "event"
            | "active"
            | "end"
    )
}

/// A JSON value on one line, strings unquoted when alone.
fn compact(value: &Value) -> String {
    match value {
        Value::String(text) => text.clone(),
        other => other.to_string(),
    }
}

/// An operation with its variables, `TestNotesQuery(id: "1")`.
fn call(arguments: &Map<String, Value>) -> String {
    let operation = arguments
        .get("operation")
        .and_then(Value::as_str)
        .unwrap_or("?");
    match arguments.get("variables").and_then(Value::as_object) {
        Some(variables) if !variables.is_empty() => {
            let items: Vec<String> = variables
                .iter()
                .map(|(name, value)| format!("{name}: {value}"))
                .collect();
            format!("{operation}({})", items.join(", "))
        }
        _ => format!("{operation}()"),
    }
}

/// One sentence for a step.
fn describe_step(kind: &str, arguments: &Value) -> String {
    let empty = Map::new();
    let arguments = arguments.as_object().unwrap_or(&empty);
    let text = |key: &str| arguments.get(key).and_then(Value::as_str).unwrap_or("").to_string();
    match kind {
        "attach" => {
            let policy = arguments
                .get("policy")
                .and_then(Value::as_str)
                .unwrap_or("storeOrNetwork");
            let mut sentence = format!(
                "A view attaches a handle for `{}` under `{policy}`, named `{}`",
                call(arguments),
                text("as")
            );
            if arguments.contains_key("response") {
                sentence.push_str(&format!(
                    "; the transport answers its fetch with `{}`.",
                    text("response")
                ));
            } else if arguments.contains_key("failure") {
                sentence.push_str(&format!("; the fetch fails with a `{}` failure.", text("failure")));
            } else {
                sentence.push_str("; the fetch stays in flight.");
            }
            sentence
        }
        "commit" => format!(
            "The server answers `{}` with `{}`, and the environment commits it as a server batch.",
            call(arguments),
            text("response")
        ),
        "payload" => format!(
            "A payload, `{}`, is committed by hand for `{}`, as a preview or a test does.",
            text("response"),
            call(arguments)
        ),
        "optimistic" => format!(
            "The optimistic response `{}` for `{}` is applied as a layer named `{}`, before any server answers.",
            text("response"),
            call(arguments),
            text("as")
        ),
        "resolve" => format!(
            "The server's answer `{}` replaces the layer `{}` in one batch.",
            text("response"),
            text("layer")
        ),
        "revert" => format!(
            "The layer `{}` is reverted, as a failed mutation's is.",
            text("layer")
        ),
        "answer" => {
            if arguments.contains_key("failure") {
                format!("The fetch of `{}` fails with a `{}` failure.", text("handle"), text("failure"))
            } else {
                format!("The fetch of `{}` is answered with `{}`.", text("handle"), text("response"))
            }
        }
        "refetch" => {
            if arguments.contains_key("failure") {
                format!("`{}` refetches, and the fetch fails with a `{}` failure.", text("handle"), text("failure"))
            } else {
                format!("`{}` refetches, answered with `{}`.", text("handle"), text("response"))
            }
        }
        "retry" => format!("`{}` retries after its failure.", text("handle")),
        "release" => format!("The retention of `{}` ends.", text("handle")),
        "collect" => "A collection pass runs now.".to_string(),
        "advance" => format!(
            "The store's clock advances by {} seconds.",
            arguments.get("seconds").map(compact).unwrap_or_default()
        ),
        "invalidate" => "The environment is invalidated: everything is marked stale and the retained operations refetch.".to_string(),
        "revalidate" => "The environment revalidates: what is stale or failed refetches.".to_string(),
        "check" => format!("The availability check runs for `{}`.", call(arguments)),
        "relaunch" => "The environment ends and a second store opens over the same image, as the next launch does.".to_string(),
        "event" => {
            if arguments.get("complete").is_some() {
                format!("The subscription `{}` is completed by the server.", text("handle"))
            } else if arguments.contains_key("failure") {
                format!("The stream of `{}` fails with a `{}` failure.", text("handle"), text("failure"))
            } else {
                format!("The stream of `{}` delivers `{}`.", text("handle"), text("response"))
            }
        }
        "active" => format!(
            "The app becomes {}.",
            if arguments.get("value").and_then(Value::as_bool).unwrap_or(true) { "active" } else { "inactive" }
        ),
        "end" => "The environment ends.".to_string(),
        other => format!("`{other}`"),
    }
}
