//! `batonc`: finds GraphQL in Swift sources and `.graphql` files, validates it
//! against the schema with Relay's front end, and emits Baton's artifacts.
//!
//! Spike-stage command set:
//! - `scan <files…>` prints the embedded documents as JSON.
//! - `plan --schema <sdl> <files…>` prints the plan IR as JSON, timings on stderr.
//! - `generate --schema <sdl> --out <dir> [--emit <src>=<out>]… <files…>` writes
//!   stub Swift per host file and prints diagnostics in `path:line:col:` form.
//! - `bench --schema <sdl> --fragments <n>` compiles a synthetic corpus twice
//!   and prints the warm timings.

mod diagnostics;
mod documents;
mod pipeline;
mod stub;
mod swift;

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::process::ExitCode;

use crate::diagnostics::Rendered;
use crate::documents::Document;
use crate::swift::Marker;

fn main() -> ExitCode {
    let arguments: Vec<String> = std::env::args().skip(1).collect();
    let Some(command) = arguments.first() else {
        eprintln!("usage: batonc <scan|plan|generate|bench> …");
        return ExitCode::from(2);
    };
    let result = match command.as_str() {
        "scan" => scan(&arguments[1..]),
        "plan" => plan(&arguments[1..]),
        "generate" => generate(&arguments[1..]),
        "bench" => bench(&arguments[1..]),
        other => {
            eprintln!("batonc: unknown command `{other}`");
            return ExitCode::from(2);
        }
    };
    match result {
        Ok(()) => ExitCode::SUCCESS,
        Err(failure) => {
            if !failure.is_empty() {
                eprintln!("{failure}");
            }
            ExitCode::FAILURE
        }
    }
}

/// Parsed command-line options: `--name value` pairs, repeated `--emit`, and
/// the remaining positional paths.
struct Options {
    values: BTreeMap<String, String>,
    emits: Vec<(PathBuf, PathBuf)>,
    paths: Vec<PathBuf>,
}

fn parse_options(arguments: &[String]) -> Result<Options, String> {
    let mut options = Options {
        values: BTreeMap::new(),
        emits: Vec::new(),
        paths: Vec::new(),
    };
    let mut iterator = arguments.iter();
    while let Some(argument) = iterator.next() {
        if let Some(name) = argument.strip_prefix("--") {
            let value = iterator
                .next()
                .ok_or_else(|| format!("batonc: `--{name}` needs a value"))?;
            if name == "emit" {
                let (source, output) = value
                    .split_once('=')
                    .ok_or_else(|| "batonc: `--emit` takes `<source>=<output>`".to_string())?;
                options
                    .emits
                    .push((PathBuf::from(source), PathBuf::from(output)));
            } else {
                options.values.insert(name.to_string(), value.clone());
            }
        } else {
            options.paths.push(PathBuf::from(argument));
        }
    }
    Ok(options)
}

fn read_schema(options: &Options) -> Result<(String, String), String> {
    let path = options
        .values
        .get("schema")
        .ok_or_else(|| "batonc: `--schema <file>` is required".to_string())?;
    let sdl = std::fs::read_to_string(path)
        .map_err(|error| format!("batonc: cannot read schema {path}: {error}"))?;
    Ok((sdl, path.clone()))
}

fn scan(arguments: &[String]) -> Result<(), String> {
    let options = parse_options(arguments)?;
    let (documents, errors) = documents::collect(&options.paths);
    for error in &errors {
        eprintln!("{error}");
    }
    println!(
        "{}",
        serde_json::to_string_pretty(&documents).map_err(|error| error.to_string())?
    );
    if errors.is_empty() {
        Ok(())
    } else {
        Err(String::new())
    }
}

fn plan(arguments: &[String]) -> Result<(), String> {
    let options = parse_options(arguments)?;
    let (sdl, schema_path) = read_schema(&options)?;
    let (documents, errors) = documents::collect(&options.paths);
    for error in &errors {
        eprintln!("{error}");
    }
    if !errors.is_empty() {
        return Err(String::new());
    }
    match pipeline::compile(&sdl, &schema_path, &documents) {
        Ok(compiled) => {
            println!(
                "{}",
                serde_json::to_string_pretty(&compiled.plan).map_err(|error| error.to_string())?
            );
            report_timings(&compiled.timings, documents.len());
            Ok(())
        }
        Err(diagnostics) => {
            for diagnostic in &diagnostics {
                eprintln!("{}", diagnostics::render(diagnostic, &documents));
            }
            Err(String::new())
        }
    }
}

fn generate(arguments: &[String]) -> Result<(), String> {
    let options = parse_options(arguments)?;
    let (sdl, schema_path) = read_schema(&options)?;
    let out_dir = options.values.get("out").map(PathBuf::from);
    let (documents, errors) = documents::collect(&options.paths);
    let mut rendered: Vec<Rendered> = Vec::new();
    let mut failed = !errors.is_empty();
    for error in &errors {
        eprintln!("{error}");
    }

    let compiled = pipeline::compile(&sdl, &schema_path, &documents);
    let plan = match &compiled {
        Ok(compiled) => compiled.plan.clone(),
        Err(diagnostics) => {
            failed = true;
            for diagnostic in diagnostics {
                rendered.push(diagnostics::render(diagnostic, &documents));
            }
            pipeline::Plan::default()
        }
    };

    rendered.extend(check_property_types(&documents, &plan));

    // Every declared output is written, so the build system never sees a
    // missing file; a host file without documents gets a header only.
    let mut targets: Vec<(PathBuf, PathBuf)> = options.emits.clone();
    if let (true, Some(out_dir)) = (targets.is_empty(), &out_dir) {
        for path in documents
            .iter()
            .map(|document| &document.path)
            .collect::<std::collections::BTreeSet<_>>()
        {
            let stem = path
                .file_stem()
                .and_then(|stem| stem.to_str())
                .unwrap_or("Baton");
            targets.push((path.clone(), out_dir.join(format!("{stem}.baton.swift"))));
        }
    }
    for (source, output) in &targets {
        let own: Vec<&Document> = documents
            .iter()
            .filter(|document| &document.path == source)
            .collect();
        let text = stub::render(&own, &plan);
        if let Some(parent) = output.parent() {
            std::fs::create_dir_all(parent)
                .map_err(|error| format!("batonc: cannot create {}: {error}", parent.display()))?;
        }
        write_if_changed(output, &text)?;
    }

    for line in &rendered {
        eprintln!("{line}");
    }
    if failed || rendered.iter().any(|line| line.severity == "error") {
        Err(String::new())
    } else {
        Ok(())
    }
}

/// Warns when the property holding a document is not typed as that document's
/// generated type: the one Baton convention the compiler can check for free.
fn check_property_types(documents: &[Document], plan: &pipeline::Plan) -> Vec<Rendered> {
    let mut rendered = Vec::new();
    for document in documents {
        let Some(embedded) = &document.embedded else {
            continue;
        };
        let Some(property) = &embedded.property else {
            continue;
        };
        let expected: Option<&str> = match embedded.marker {
            Marker::Fragment => plan
                .fragments
                .iter()
                .map(|fragment| fragment.name.as_str())
                .find(|name| document.text.contains(name)),
            _ => plan
                .operations
                .iter()
                .map(|operation| operation.name.as_str())
                .find(|name| document.text.contains(name)),
        };
        let Some(expected) = expected else { continue };
        let written = property
            .type_name
            .trim_end_matches('?')
            .rsplit('.')
            .next()
            .unwrap_or("");
        let matches = match embedded.marker {
            Marker::Fragment | Marker::Query => written == expected,
            Marker::Mutation | Marker::Subscription => {
                written == expected || written == format!("{expected}.Action")
            }
        };
        if !matches {
            rendered.push(diagnostics::own(
                &document.path,
                document.start.line,
                document.start.column,
                "warning",
                format!(
                    "{} declares `{expected}` but the property `{}` is typed `{}`; Baton expects the property type to be `{expected}`",
                    embedded.marker, property.name, property.type_name
                ),
            ));
        }
    }
    rendered
}

fn write_if_changed(path: &Path, text: &str) -> Result<(), String> {
    if std::fs::read_to_string(path)
        .map(|existing| existing == text)
        .unwrap_or(false)
    {
        return Ok(());
    }
    std::fs::write(path, text)
        .map_err(|error| format!("batonc: cannot write {}: {error}", path.display()))
}

fn bench(arguments: &[String]) -> Result<(), String> {
    let options = parse_options(arguments)?;
    let (sdl, schema_path) = read_schema(&options)?;
    let count: usize = options
        .values
        .get("fragments")
        .map(|value| {
            value
                .parse()
                .map_err(|_| "batonc: `--fragments` must be a number".to_string())
        })
        .transpose()?
        .unwrap_or(500);
    let documents = synthetic_corpus(count);
    let mut last = None;
    for round in 0..3 {
        match pipeline::compile(&sdl, &schema_path, &documents) {
            Ok(compiled) => {
                eprintln!(
                    "round {round}: {} fragments, {} operations",
                    compiled.plan.fragments.len(),
                    compiled.plan.operations.len()
                );
                report_timings(&compiled.timings, documents.len());
                last = Some(compiled.timings);
            }
            Err(diagnostics) => {
                for diagnostic in &diagnostics {
                    eprintln!("{}", diagnostics::render(diagnostic, &documents));
                }
                return Err(String::new());
            }
        }
    }
    if let Some(timings) = last {
        println!(
            "warm total: {:.1} ms",
            timings.total().as_secs_f64() * 1000.0
        );
    }
    Ok(())
}

/// A corpus shaped like a real app: `count` fragments spread across the
/// sample schema's types, one query per twenty fragments spreading them.
fn synthetic_corpus(count: usize) -> Vec<Document> {
    let shapes = [
        (
            "Character",
            "name status species image origin { name } episode { id name }",
        ),
        ("Location", "name type dimension residents { id name }"),
        (
            "Episode",
            "name air_date episode characters { id name image }",
        ),
    ];
    let mut documents = Vec::new();
    for index in 0..count {
        let (type_name, fields) = shapes[index % shapes.len()];
        documents.push(synthetic_document(
            index,
            format!("fragment Synthetic{index}_{type_name} on {type_name} {{ id {fields} }}"),
        ));
    }
    for (query_index, chunk) in (0..count).collect::<Vec<_>>().chunks(20).enumerate() {
        let mut spreads = [String::new(), String::new(), String::new()];
        for index in chunk {
            spreads[index % 3].push_str(&format!(" ...Synthetic{index}_{}", shapes[index % 3].0));
        }
        documents.push(synthetic_document(
            count + query_index,
            format!(
                "query SyntheticScreen{query_index}($id: ID!) {{ character(id: $id) {{ id{} location {{ id{} }} episode {{ id{} }} }} }}",
                spreads[0], spreads[1], spreads[2]
            ),
        ));
    }
    documents
}

fn synthetic_document(index: usize, text: String) -> Document {
    Document {
        path: PathBuf::from(format!("Synthetic{index}.swift")),
        index: 0,
        start: swift::Position { line: 1, column: 1 },
        text,
        embedded: None,
    }
}

fn report_timings(timings: &pipeline::Timings, document_count: usize) {
    let ms = |duration: std::time::Duration| duration.as_secs_f64() * 1000.0;
    eprintln!(
        "{document_count} documents: schema {:.1} ms, parse {:.1} ms, ir {:.1} ms, validate {:.1} ms, transform {:.1} ms, lower {:.1} ms, total {:.1} ms",
        ms(timings.schema),
        ms(timings.parse),
        ms(timings.ir),
        ms(timings.validate),
        ms(timings.transform),
        ms(timings.lower),
        ms(timings.total())
    );
}
