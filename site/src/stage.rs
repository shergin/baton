//! The stage: a screen drawn over real records, so a reader can change a
//! field and watch which view re-renders. The view tree and what each
//! view reads come from the compiler's report of the figure; the rows
//! come from a dump the runtime wrote under the fixtures; which views
//! light up follows from those two alone.

use std::path::Path;

use serde_json::{Map, Value, json};

use crate::compiler::Compiled;
use crate::escape::escape;
use crate::store::Dump;

/// The stage for `operation` of a compiled figure, over `dump`, with at
/// most `rows` rows.
pub fn html(compiled: &Compiled, operation: &str, dump_path: &Path, rows: usize) -> Result<String, String> {
    let report = compiled.report.as_ref().ok_or("no report")?;
    let entry = report["operations"]
        .as_array()
        .into_iter()
        .flatten()
        .find(|entry| entry["name"].as_str() == Some(operation))
        .ok_or_else(|| format!("no operation {operation}"))?;
    let lens = entry.get("lens").ok_or("the operation has no lens")?;
    // The screen reads a root link, then a list under it, then one spread
    // per element: the shape of a list screen.
    let root_accessor = lens["accessors"]
        .as_array()
        .and_then(|accessors| accessors.first())
        .ok_or("the operation reads nothing")?;
    let root_key = root_accessor["key"].as_str().ok_or("no root key")?;
    let list_accessor = root_accessor["lens"]["accessors"]
        .as_array()
        .into_iter()
        .flatten()
        .find(|accessor| accessor["list"].is_object())
        .ok_or("the root link holds no list")?;
    let list_key = list_accessor["key"].as_str().ok_or("no list key")?;
    let spread = list_accessor["lens"]["accessors"]
        .as_array()
        .into_iter()
        .flatten()
        .find(|accessor| accessor["read"].as_str() == Some("spread"))
        .ok_or("the elements spread no fragment")?;
    let fragment_name = spread["fragment"].as_str().ok_or("no fragment")?;
    let fragment = report["fragments"]
        .as_array()
        .into_iter()
        .flatten()
        .find(|entry| entry["name"].as_str() == Some(fragment_name))
        .ok_or("the report lacks the fragment")?;
    let row_fields: Vec<String> = fragment["lens"]["accessors"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|accessor| accessor["key"].as_str().map(str::to_string))
        .collect();
    let screen_name = compiled
        .hosts
        .iter()
        .find_map(|host| host_name(&host.text, operation))
        .unwrap_or_else(|| operation.to_string());
    let row_name = compiled
        .hosts
        .iter()
        .find_map(|host| host_name(&host.text, fragment_name))
        .unwrap_or_else(|| fragment_name.to_string());

    let dump = Dump::load(dump_path);
    let root = dump.record("client:root").ok_or("the dump has no root")?;
    let root_storage = dump
        .storage_key(root, root_key)
        .ok_or_else(|| format!("the root holds no {root_key}"))?
        .to_string();
    let list_record_key = root[&root_storage]["__ref"]
        .as_str()
        .ok_or("the root field is not a link")?
        .to_string();
    let list_record = dump.record(&list_record_key).ok_or("no list record")?;
    let list_storage = dump
        .storage_key(list_record, list_key)
        .ok_or_else(|| format!("the list record holds no {list_key}"))?
        .to_string();
    let targets: Vec<String> = list_record[&list_storage]["__refs"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(Value::as_str)
        .map(str::to_string)
        .take(rows)
        .collect();

    // The records the stage shows: the root, the list and the rows.
    let mut records: Vec<(String, Map<String, Value>)> = Vec::new();
    records.push((
        "client:root".to_string(),
        pick(root, &[root_storage.as_str()]),
    ));
    let mut list_only = pick(list_record, &[list_storage.as_str()]);
    list_only.insert(
        list_storage.clone(),
        json!({"__refs": targets}),
    );
    records.push((list_record_key.clone(), list_only));
    for target in &targets {
        let record = dump.record(target).ok_or("a listed record is missing")?;
        let mut shown: Vec<&str> = row_fields.iter().map(String::as_str).collect();
        shown.push("id");
        records.push((target.clone(), pick(record, &shown)));
    }

    // The views: the screen reads the root link and the list; a row reads
    // its fragment's fields of its record.
    let mut views = vec![json!({
        "id": "screen",
        "name": screen_name,
        "reads": [["client:root", root_storage], [list_record_key, list_storage]],
    })];
    for (index, target) in targets.iter().enumerate() {
        views.push(json!({
            "id": format!("row-{index}"),
            "name": row_name,
            "record": target,
            "reads": row_fields.iter().map(|field| json!([target, field])).collect::<Vec<_>>(),
        }));
    }

    let mut out = String::from("<div class=\"stage\">");
    // The phone.
    out.push_str("<div class=\"phone\"><div class=\"phone-screen\">");
    out.push_str(&format!(
        "<div class=\"view screen-view\" data-view=\"screen\"><div class=\"view-label\">{}</div><div class=\"nav-title\">{}</div><div class=\"rows\">",
        escape(&screen_name),
        escape(&title_from(list_record_key.as_str()))
    ));
    for (index, target) in targets.iter().enumerate() {
        let record = dump.record(target).ok_or("a listed record is missing")?;
        let field = |name: &str| record.get(name).and_then(Value::as_str).unwrap_or("").to_string();
        let image = field("image");
        let subtitle: Vec<String> = row_fields
            .iter()
            .filter(|name| !matches!(name.as_str(), "name" | "image" | "id"))
            .map(|name| field(name))
            .filter(|value| !value.is_empty())
            .collect();
        out.push_str(&format!(
            "<div class=\"view row-view\" data-view=\"row-{index}\" data-record=\"{}\">{}<div class=\"row-text\"><span class=\"row-title\" data-field=\"name\">{}</span><span class=\"row-subtitle\">{}</span></div><span class=\"view-label\">{}</span></div>",
            escape(target),
            if image.is_empty() {
                String::new()
            } else {
                format!("<img class=\"avatar\" src=\"{}\" alt=\"\" loading=\"lazy\" width=\"40\" height=\"40\">", escape(&image))
            },
            escape(&field("name")),
            escape(&subtitle.join(" · ")),
            escape(&row_name)
        ));
    }
    out.push_str("</div></div></div></div>");
    // The records, each field a button.
    out.push_str("<div class=\"stage-store\"><p class=\"side-title\">The store <span class=\"hint\">click a field to change it</span></p><div class=\"records\">");
    for (key, record) in &records {
        let typename = record.get("__typename").and_then(Value::as_str).unwrap_or("");
        out.push_str(&format!(
            "<div class=\"record\" data-key=\"{}\"><div class=\"record-key\"><span class=\"key\">{}</span><span class=\"typename\">{}</span></div><table>",
            escape(key),
            escape(key),
            escape(typename)
        ));
        for (field, value) in record {
            if field == "__typename" {
                continue;
            }
            let shown = match value {
                Value::String(text) => {
                    let text: String = if text.chars().count() > 40 {
                        let mut cut: String = text.chars().take(36).collect();
                        cut.push('…');
                        cut
                    } else {
                        text.clone()
                    };
                    format!("<span class=\"string\">\"{}\"</span>", escape(&text))
                }
                Value::Object(object) if object.contains_key("__ref") => format!(
                    "<span class=\"ref\">{}</span>",
                    escape(object["__ref"].as_str().unwrap_or(""))
                ),
                Value::Object(object) if object.contains_key("__refs") => format!(
                    "<span class=\"refs\">[ {} links ]</span>",
                    object["__refs"].as_array().map_or(0, Vec::len)
                ),
                other => format!("<span class=\"scalar\">{}</span>", escape(&other.to_string())),
            };
            out.push_str(&format!(
                "<tr data-record=\"{}\" data-field=\"{}\"><th>{}</th><td><button type=\"button\" class=\"slot\" data-record=\"{}\" data-field=\"{}\" title=\"Change this field\">{}</button></td></tr>",
                escape(key),
                escape(field),
                escape(field),
                escape(key),
                escape(field),
                shown
            ));
        }
        out.push_str("</table></div>");
    }
    out.push_str("</div></div>");
    // The tally and the scenarios.
    out.push_str("<div class=\"stage-tally\"><p class=\"tally\"><span class=\"count\" id=\"tally-count\">0</span> of <span class=\"total\"></span> bodies re-ran</p><p class=\"last\" id=\"tally-last\">Nothing has changed yet.</p><div class=\"scenarios\"><button type=\"button\" class=\"scenario\" data-scenario=\"same\">A refetch answers with the same data</button><button type=\"button\" class=\"scenario\" data-scenario=\"first-name\">The first row's name changes</button><button type=\"button\" class=\"scenario\" data-scenario=\"list\">The list gains a row</button><button type=\"button\" class=\"scenario\" data-scenario=\"reset\">Reset</button></div></div>");
    let data = json!({
        "views": views,
        "root": "client:root",
        "list": [list_record_key, list_storage],
    });
    out.push_str(&format!(
        "<script type=\"application/json\" class=\"stage-data\">{}</script></div>",
        serde_json::to_string(&data).expect("stage data").replace("</", "<\\/")
    ));
    Ok(out)
}

/// The fields of a record, in its order, by name.
fn pick(record: &Map<String, Value>, fields: &[&str]) -> Map<String, Value> {
    let mut out = Map::new();
    if let Some(typename) = record.get("__typename") {
        out.insert("__typename".to_string(), typename.clone());
    }
    for (field, value) in record {
        if fields.contains(&field.as_str()) {
            out.insert(field.clone(), value.clone());
        }
    }
    out
}

/// The Swift or Kotlin name of the view that carries a document named
/// `document_name`: the `struct` or `fun` after the marker.
fn host_name(text: &str, document_name: &str) -> Option<String> {
    let at = text.find(&format!(" {document_name}"))?;
    let rest = &text[at..];
    for line in rest.lines() {
        let trimmed = line.trim();
        if let Some(name) = trimmed.strip_prefix("struct ") {
            return Some(name.split(|c: char| !c.is_alphanumeric() && c != '_').next()?.to_string());
        }
        if let Some(name) = trimmed.strip_prefix("fun ") {
            return Some(name.split(|c: char| !c.is_alphanumeric() && c != '_').next()?.to_string());
        }
    }
    None
}

/// A title for the list from its record key: `client:root:characters(page:1)`
/// is `Characters`.
fn title_from(key: &str) -> String {
    let last = key.strip_prefix("client:root:").unwrap_or(key);
    let word = last.split('(').next().unwrap_or(last);
    let mut chars = word.chars();
    match chars.next() {
        Some(first) => first.to_uppercase().collect::<String>() + chars.as_str(),
        None => String::new(),
    }
}
