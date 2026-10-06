//! `batonc`: finds GraphQL in Swift sources and `.graphql` files, validates it
//! against the schema with Relay's front end, and emits Baton's artifacts.
//!
//! Spike-stage command set:
//! - `scan <files…>` prints the embedded documents as JSON.
//! - `plan --schema <sdl> <files…>` prints the plan IR as JSON, timings on stderr.
//! - `generate --schema <sdl> (--out <dir> | --emit <src>=<out>…) <files…>`
//!   writes the Swift of each host file and the shared file, or nothing when a
//!   document has an error, and prints diagnostics in `path:line:col:` form;
//!   `--report <file>` writes what the target compiled as JSON.
//! - `bench --schema <sdl> --fragments <n>` compiles a synthetic corpus twice
//!   and prints the warm timings.

mod config;
mod decide;
mod diagnostics;
mod directives;
mod documents;
mod emit;
mod names;
mod pipeline;
mod report;
mod swift;

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::process::ExitCode;

use crate::config::Config;
use crate::diagnostics::Rendered;
use crate::documents::Document;
use crate::names::NameError;
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
    #[error("batonc: cannot remove {path}: {source}")]
    Remove {
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

/// Reads a command's arguments; `allowed` names the options the command
/// takes, and any other is an error rather than a silent default.
fn parse_options(
    command: &str,
    arguments: &[String],
    allowed: &[&str],
) -> Result<Options, DriverError> {
    let mut options = Options {
        values: BTreeMap::new(),
        emits: Vec::new(),
        paths: Vec::new(),
    };
    let mut iterator = arguments.iter();
    while let Some(argument) = iterator.next() {
        if let Some(name) = argument.strip_prefix("--") {
            if !allowed.contains(&name) {
                let takes = if allowed.is_empty() {
                    "takes no options".to_string()
                } else {
                    let listed: Vec<String> =
                        allowed.iter().map(|name| format!("`--{name}`")).collect();
                    format!("takes {}", listed.join(", "))
                };
                return Err(DriverError::Usage(format!(
                    "`--{name}` is not an option of `{command}`, which {takes}"
                )));
            }
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
/// The schema's text and path, the texts and paths of the configuration's
/// schema extensions, and the configuration.
struct SchemaSources {
    sdl: String,
    path: String,
    extensions: Vec<(String, String)>,
    config: Config,
}

fn read_schema(options: &Options) -> Result<SchemaSources, DriverError> {
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
    let base = options
        .values
        .get("config")
        .map(Path::new)
        .and_then(Path::parent)
        .map(Path::to_path_buf)
        .unwrap_or_default();
    let mut extensions = Vec::new();
    for entry in &config.schema_extensions {
        for file in extension_files(&base.join(entry))? {
            let text = std::fs::read_to_string(&file).map_err(|source| DriverError::Read {
                path: file.display().to_string(),
                source,
            })?;
            extensions.push((text, file.to_string_lossy().into_owned()));
        }
    }
    Ok(SchemaSources {
        sdl,
        path: path.to_string_lossy().into_owned(),
        extensions,
        config,
    })
}

/// The files a `schemaExtensions` entry names: the file itself, or the
/// `.graphql` files of a directory, in name order.
fn extension_files(path: &Path) -> Result<Vec<PathBuf>, DriverError> {
    if !path.is_dir() {
        return Ok(vec![path.to_path_buf()]);
    }
    let entries = std::fs::read_dir(path).map_err(|source| DriverError::Read {
        path: path.display().to_string(),
        source,
    })?;
    let mut files: Vec<PathBuf> = entries
        .filter_map(Result::ok)
        .map(|entry| entry.path())
        .filter(|file| {
            file.extension()
                .is_some_and(|extension| extension == "graphql")
        })
        .collect();
    files.sort();
    Ok(files)
}

fn scan(arguments: &[String]) -> Result<(), DriverError> {
    let options = parse_options("scan", arguments, &[])?;
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
    let options = parse_options("plan", arguments, &["schema", "config"])?;
    let sources = read_schema(&options)?;
    let (sdl, schema_path, config) = (&sources.sdl, &sources.path, &sources.config);
    let (documents, errors) = documents::collect(&options.paths);
    for error in &errors {
        eprintln!("{error}");
    }
    if !errors.is_empty() {
        return Err(DriverError::Reported);
    }
    match pipeline::compile(sdl, schema_path, &sources.extensions, &documents, config) {
        Ok(compiled) => {
            println!("{}", serde_json::to_string_pretty(&compiled.plan)?);
            report_timings(&compiled.timings, documents.len());
            Ok(())
        }
        Err(diagnostics) => {
            let known = with_schema(&documents, schema_path, sdl);
            for diagnostic in &diagnostics {
                eprintln!("{}", diagnostics::render(diagnostic, &known));
            }
            Err(DriverError::Reported)
        }
    }
}

fn generate(arguments: &[String]) -> Result<(), DriverError> {
    let options = parse_options(
        "generate",
        arguments,
        &["schema", "config", "out", "shared", "emit", "report"],
    )?;
    let sources = read_schema(&options)?;
    let (sdl, schema_path, config) = (&sources.sdl, &sources.path, &sources.config);
    let out_dir = options.values.get("out").map(PathBuf::from);
    let shared_path = options.values.get("shared").map(PathBuf::from);
    let (documents, errors) = documents::collect(&options.paths);
    for error in &errors {
        eprintln!("{error}");
    }

    // Relay's program is all or nothing: after an error nothing is written,
    // so the build stops on the first wave of diagnostics instead of a second
    // one from a module half written.
    let compiled = pipeline::compile(sdl, schema_path, &sources.extensions, &documents, config);
    let plan = match compiled {
        Ok(compiled) => compiled.plan,
        Err(diagnostics) => {
            let known = with_schema(&documents, schema_path, sdl);
            for diagnostic in &diagnostics {
                eprintln!("{}", diagnostics::render(diagnostic, &known));
            }
            return Err(DriverError::Reported);
        }
    };
    if !errors.is_empty() {
        return Err(DriverError::Reported);
    }
    let rendered = check_property_types(&documents, &plan);
    let output = match emit::emit(&plan) {
        Ok(output) => output,
        Err(errors) => {
            for error in &errors {
                match error {
                    NameError::Clash(clash) => eprintln!(
                        "{}",
                        diagnostics::at(&clash.origin, &documents, clash.to_string())
                    ),
                    NameError::Duplicate(duplicate) => eprintln!("batonc: {duplicate}"),
                }
            }
            return Err(DriverError::Reported);
        }
    };

    let mut targets: Vec<(PathBuf, PathBuf)> = options.emits.clone();
    if let (true, Some(out_dir)) = (targets.is_empty(), &out_dir) {
        let root = std::env::current_dir().unwrap_or_default();
        for path in documents
            .iter()
            .map(|document| &document.path)
            .collect::<std::collections::BTreeSet<_>>()
        {
            targets.push((path.clone(), out_dir.join(output_name(path, &root))));
        }
    }
    let shared_path =
        shared_path.or_else(|| out_dir.as_ref().map(|dir| dir.join("Baton.baton.swift")));
    check_targets(&targets, shared_path.as_deref(), &output)?;

    // Every declared output is written, so the build system never sees a
    // missing file; a host file without documents gets a header only.
    let mut written: Vec<&Path> = Vec::new();
    for (source, destination) in &targets {
        let text = output
            .files
            .get(&source.to_string_lossy().into_owned())
            .cloned()
            .unwrap_or_else(|| "// Generated by batonc. No GraphQL in this file.\n".to_string());
        write_output(destination, &text)?;
        written.push(destination);
    }
    if let Some(shared_path) = &shared_path {
        write_output(shared_path, &output.shared)?;
        written.push(shared_path);
    }
    // Under `persistConfig`, Relay's map from id to text, which a
    // registration step consumes: beside the configuration when run by
    // hand, or in the output directory under the build, whose sandbox keeps
    // the source tree.
    let persist_path = sources
        .config
        .persist_config
        .as_ref()
        .map(|persist| match &out_dir {
            Some(out_dir) => out_dir.join(Path::new(&persist.file).file_name().unwrap_or_default()),
            None => options
                .values
                .get("config")
                .map(Path::new)
                .and_then(Path::parent)
                .map(Path::to_path_buf)
                .unwrap_or_default()
                .join(&persist.file),
        });
    if let Some(persist_path) = &persist_path {
        write_output(persist_path, &persisted_documents(&plan))?;
    }
    // The report: what this target compiled, for the people who register
    // operations and review contract changes.
    if let Some(report_path) = options.values.get("report") {
        let root = std::env::current_dir().unwrap_or_default();
        write_output(Path::new(report_path), &report::text(&plan, &root))?;
    }
    if let Some(out_dir) = &out_dir {
        remove_stale_outputs(out_dir, &written)?;
    }

    for line in &rendered {
        eprintln!("{line}");
    }
    if rendered.iter().any(|line| line.severity == "error") {
        Err(DriverError::Reported)
    } else {
        Ok(())
    }
}

/// Relay's persisted-documents file: a JSON object from each operation's id
/// to its text, the ids in order, so a review reads it and a registration
/// step consumes it.
fn persisted_documents(plan: &pipeline::Plan) -> String {
    let mut entries: Vec<(&str, &str)> = plan
        .operations
        .iter()
        .filter_map(|operation| Some((operation.id.as_deref()?, operation.text.as_str())))
        .collect();
    entries.sort();
    let mut map = serde_json::Map::new();
    for (id, text) in entries {
        map.insert(id.to_string(), serde_json::Value::String(text.to_string()));
    }
    let mut text =
        serde_json::to_string_pretty(&serde_json::Value::Object(map)).unwrap_or_default();
    text.push('\n');
    text
}

/// Removes from `out_dir` every generated file this run did not write: the
/// output of a source since renamed or removed, which a build that compiles
/// the directory would otherwise still see. The directory is the compiler's
/// own, so only its `.baton.swift` files are touched.
fn remove_stale_outputs(out_dir: &Path, written: &[&Path]) -> Result<(), DriverError> {
    let Ok(entries) = std::fs::read_dir(out_dir) else {
        return Ok(());
    };
    let written: std::collections::BTreeSet<PathBuf> = written
        .iter()
        .filter_map(|path| std::fs::canonicalize(path).ok())
        .collect();
    for entry in entries.flatten() {
        let path = entry.path();
        if !path.to_string_lossy().ends_with(".baton.swift") {
            continue;
        }
        let Ok(canonical) = std::fs::canonicalize(&path) else {
            continue;
        };
        if written.contains(&canonical) {
            continue;
        }
        std::fs::remove_file(&path).map_err(|source| DriverError::Remove {
            path: path.display().to_string(),
            source,
        })?;
    }
    Ok(())
}

/// The output a source writes: its path relative to `root`, each directory
/// separator an underscore, with `.baton.swift` in place of a `.swift`
/// extension and after any other, so `Thing.swift` and `Thing.graphql`, or
/// two files of one name in two directories, write two outputs. The build
/// plugin names its outputs by the same rule.
fn output_name(source: &Path, root: &Path) -> String {
    let relative = source.strip_prefix(root).unwrap_or(source);
    let parts: Vec<String> = relative
        .components()
        .filter_map(|component| match component {
            std::path::Component::Normal(part) => Some(part.to_string_lossy().into_owned()),
            std::path::Component::ParentDir => Some("..".to_string()),
            _ => None,
        })
        .collect();
    let joined = parts.join("_");
    let stem = joined.strip_suffix(".swift").unwrap_or(&joined);
    format!("{stem}.baton.swift")
}

/// Fails when a file holding GraphQL has no output, whose lenses would be
/// compiled and dropped, or when two sources, or a source and the shared
/// file, would write one output.
fn check_targets(
    targets: &[(PathBuf, PathBuf)],
    shared: Option<&Path>,
    output: &emit::Output,
) -> Result<(), DriverError> {
    let sources: std::collections::BTreeSet<String> = targets
        .iter()
        .map(|(source, _)| source.to_string_lossy().into_owned())
        .collect();
    if let Some(untargeted) = output
        .files
        .keys()
        .find(|source| !sources.contains(*source))
    {
        return Err(DriverError::Usage(format!(
            "`{untargeted}` holds GraphQL but no `--emit` names an output for it"
        )));
    }
    let mut writers: BTreeMap<&Path, &Path> = BTreeMap::new();
    for (source, destination) in targets {
        if shared == Some(destination.as_path()) {
            return Err(DriverError::Usage(format!(
                "`{}` would write the shared `{}`; rename it",
                source.display(),
                destination.display()
            )));
        }
        if let Some(other) = writers
            .insert(destination, source)
            .filter(|other| *other != source.as_path())
        {
            return Err(DriverError::Usage(format!(
                "`{}` and `{}` would both write `{}`; rename one",
                other.display(),
                source.display(),
                destination.display()
            )));
        }
    }
    Ok(())
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
/// The definition is found by where it came from, its file and its place
/// among the file's documents, never by searching the text for a name.
fn check_property_types(documents: &[Document], plan: &pipeline::Plan) -> Vec<Rendered> {
    let mut rendered = Vec::new();
    for document in documents {
        let Some(embedded) = &document.embedded else {
            continue;
        };
        let Some(property) = &embedded.property else {
            continue;
        };
        let path = document.path.to_string_lossy();
        let expected = match embedded.marker {
            Marker::Fragment => plan
                .fragments
                .iter()
                .find(|fragment| fragment.source == path && fragment.document == document.index)
                .map(|fragment| fragment.name.as_str()),
            marker => plan
                .operations
                .iter()
                .find(|operation| {
                    operation.source == path
                        && operation.document == document.index
                        && Some(operation.kind) == kind_of(marker)
                })
                .map(|operation| operation.name.as_str()),
        };
        let Some(expected) = expected else { continue };
        // Module-qualified spellings are accepted: `App.Foo` names `Foo`.
        let written = property.type_name.trim_end_matches('?');
        let names = |name: &str| written == name || written.ends_with(&format!(".{name}"));
        let matches = match embedded.marker {
            Marker::Mutation => names(expected) || names(&format!("{expected}.Action")),
            _ => names(expected),
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

/// The operation kind a marker declares; none for a fragment's.
fn kind_of(marker: Marker) -> Option<pipeline::OperationKind> {
    match marker {
        Marker::Query => Some(pipeline::OperationKind::Query),
        Marker::Mutation => Some(pipeline::OperationKind::Mutation),
        Marker::Subscription => Some(pipeline::OperationKind::Subscription),
        Marker::Fragment => None,
    }
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
    let options = parse_options("bench", arguments, &["schema", "config", "fragments"])?;
    let sources = read_schema(&options)?;
    let (sdl, schema_path, config) = (&sources.sdl, &sources.path, &sources.config);
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
        match pipeline::compile(sdl, schema_path, &sources.extensions, &documents, config) {
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
