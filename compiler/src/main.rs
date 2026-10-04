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

mod config;
mod decide;
mod diagnostics;
mod directives;
mod documents;
mod emit;
mod pipeline;
mod swift;

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::process::ExitCode;

use crate::config::Config;
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
        Err(DriverError::Reported) => ExitCode::FAILURE,
        Err(failure) => {
            eprintln!("{failure}");
            ExitCode::FAILURE
        }
    }
}

/// Why a command failed.
#[derive(Debug, thiserror::Error)]
enum DriverError {
    /// The command line asked for something the command cannot do.
    #[error("batonc: {0}")]
    Usage(String),
    /// `baton.json` could not be read or parsed.
    #[error("{0}")]
    Config(String),
    #[error("batonc: cannot read {path}: {source}")]
    Read {
        path: String,
        #[source]
        source: std::io::Error,
    },
    #[error("batonc: cannot write {path}: {source}")]
    Write {
        path: String,
        #[source]
        source: std::io::Error,
    },
    #[error("batonc: {0}")]
    Json(#[from] serde_json::Error),
    /// The diagnostics have been printed.
    #[error("batonc: the documents have errors")]
    Reported,
}

/// Parsed command-line options: `--name value` pairs, repeated `--emit`, and
/// the remaining positional paths.
struct Options {
    values: BTreeMap<String, String>,
    emits: Vec<(PathBuf, PathBuf)>,
    paths: Vec<PathBuf>,
}

fn parse_options(arguments: &[String]) -> Result<Options, DriverError> {
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
                .ok_or_else(|| DriverError::Usage(format!("`--{name}` needs a value")))?;
            if name == "emit" {
                let (source, output) = value.split_once('=').ok_or_else(|| {
                    DriverError::Usage("`--emit` takes `<source>=<output>`".to_string())
                })?;
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

/// The schema SDL and its path, from `--schema`, or from the `schema` entry of
/// the `--config` file. The config also carries the lookups.
fn read_schema(options: &Options) -> Result<(String, String, Config), DriverError> {
    let config = match options.values.get("config") {
        Some(path) => Config::load(Path::new(path)).map_err(DriverError::Config)?,
        None => Config::default(),
    };
    let path =
        match (options.values.get("schema"), options.values.get("config")) {
            (Some(schema), _) => PathBuf::from(schema),
            (None, Some(config_path)) if !config.schema.is_empty() => {
                config.schema_path(Path::new(config_path))
            }
            _ => return Err(DriverError::Usage(
                "`--schema <file>` or `--config <baton.json>` with a `schema` entry is required"
                    .to_string(),
            )),
        };
    let sdl = std::fs::read_to_string(&path).map_err(|source| DriverError::Read {
        path: path.display().to_string(),
        source,
    })?;
    Ok((sdl, path.to_string_lossy().into_owned(), config))
}

fn scan(arguments: &[String]) -> Result<(), DriverError> {
    let options = parse_options(arguments)?;
    let (documents, errors) = documents::collect(&options.paths);
    for error in &errors {
        eprintln!("{error}");
    }
    println!("{}", serde_json::to_string_pretty(&documents)?);
    if errors.is_empty() {
        Ok(())
    } else {
        Err(DriverError::Reported)
    }
}

fn plan(arguments: &[String]) -> Result<(), DriverError> {
    let options = parse_options(arguments)?;
    let (sdl, schema_path, config) = read_schema(&options)?;
    let (documents, errors) = documents::collect(&options.paths);
    for error in &errors {
        eprintln!("{error}");
    }
    if !errors.is_empty() {
        return Err(DriverError::Reported);
    }
    match pipeline::compile(&sdl, &schema_path, &documents, &config) {
        Ok(compiled) => {
            println!("{}", serde_json::to_string_pretty(&compiled.plan)?);
            report_timings(&compiled.timings, documents.len());
            Ok(())
        }
        Err(diagnostics) => {
            let known = with_schema(&documents, &schema_path, &sdl);
            for diagnostic in &diagnostics {
                eprintln!("{}", diagnostics::render(diagnostic, &known));
            }
            Err(DriverError::Reported)
        }
    }
}

fn generate(arguments: &[String]) -> Result<(), DriverError> {
    let options = parse_options(arguments)?;
    let (sdl, schema_path, config) = read_schema(&options)?;
    let out_dir = options.values.get("out").map(PathBuf::from);
    let shared_path = options.values.get("shared").map(PathBuf::from);
    let (documents, errors) = documents::collect(&options.paths);
    let mut rendered: Vec<Rendered> = Vec::new();
    let mut failed = !errors.is_empty();
    for error in &errors {
        eprintln!("{error}");
    }

    let compiled = pipeline::compile(&sdl, &schema_path, &documents, &config);
    let plan = match &compiled {
        Ok(compiled) => compiled.plan.clone(),
        Err(diagnostics) => {
            failed = true;
            let known = with_schema(&documents, &schema_path, &sdl);
            for diagnostic in diagnostics {
                rendered.push(diagnostics::render(diagnostic, &known));
            }
            pipeline::Plan::default()
        }
    };
    rendered.extend(check_property_types(&documents, &plan));
    let output = emit::emit(&plan);

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
    for (source, destination) in &targets {
        let text = output
            .files
            .get(&source.to_string_lossy().into_owned())
            .cloned()
            .unwrap_or_else(|| "// Generated by batonc. No GraphQL in this file.\n".to_string());
        write_output(destination, &text)?;
    }
    if let Some(shared_path) =
        shared_path.or_else(|| out_dir.as_ref().map(|dir| dir.join("Baton.baton.swift")))
    {
        write_output(&shared_path, &output.shared)?;
    }

    for line in &rendered {
        eprintln!("{line}");
    }
    if failed || rendered.iter().any(|line| line.severity == "error") {
        Err(DriverError::Reported)
    } else {
        Ok(())
    }
}

/// The documents a diagnostic may point into: the sources and the schema.
fn with_schema(documents: &[Document], schema_path: &str, sdl: &str) -> Vec<Document> {
    let mut known = documents.to_vec();
    known.push(Document::schema(schema_path, sdl));
    known
}

fn write_output(path: &Path, text: &str) -> Result<(), DriverError> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).map_err(|source| DriverError::Write {
            path: parent.display().to_string(),
            source,
        })?;
    }
    write_if_changed(path, text)
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
            // The longest name the text contains: `TestAddNote` is inside
            // `TestAddNoteFirst`.
            Marker::Fragment => plan
                .fragments
                .iter()
                .map(|fragment| fragment.name.as_str())
                .filter(|name| document.text.contains(name))
                .max_by_key(|name| name.len()),
            _ => plan
                .operations
                .iter()
                .map(|operation| operation.name.as_str())
                .filter(|name| document.text.contains(name))
                .max_by_key(|name| name.len()),
        };
        let Some(expected) = expected else { continue };
        // Module-qualified spellings are accepted: `App.Foo` names `Foo`.
        let written = property.type_name.trim_end_matches('?');
        let names = |name: &str| written == name || written.ends_with(&format!(".{name}"));
        let matches = match embedded.marker {
            Marker::Fragment | Marker::Query => names(expected),
            Marker::Mutation | Marker::Subscription => {
                names(expected) || names(&format!("{expected}.Action"))
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

fn write_if_changed(path: &Path, text: &str) -> Result<(), DriverError> {
    if std::fs::read_to_string(path)
        .map(|existing| existing == text)
        .unwrap_or(false)
    {
        return Ok(());
    }
    std::fs::write(path, text).map_err(|source| DriverError::Write {
        path: path.display().to_string(),
        source,
    })
}

fn bench(arguments: &[String]) -> Result<(), DriverError> {
    let options = parse_options(arguments)?;
    let (sdl, schema_path, config) = read_schema(&options)?;
    let count: usize = options
        .values
        .get("fragments")
        .map(|value| {
            value
                .parse()
                .map_err(|_| DriverError::Usage("`--fragments` must be a number".to_string()))
        })
        .transpose()?
        .unwrap_or(500);
    let documents = synthetic_corpus(count);
    let mut last = None;
    for round in 0..3 {
        match pipeline::compile(&sdl, &schema_path, &documents, &config) {
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
                return Err(DriverError::Reported);
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
