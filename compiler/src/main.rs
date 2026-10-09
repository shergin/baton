//! `batonc`: finds GraphQL in Swift sources and `.graphql` files, validates it
//! against the schema with Relay's front end, and emits Baton's artifacts.
//!
//! Spike-stage command set:
//! - `scan <files…>` prints the embedded documents as JSON.
//! - `plan --schema <sdl> <files…>` prints the plan IR as JSON, timings on stderr.
//! - `generate --schema <sdl> (--out <dir> | --emit <src>=<out>…) <files…>`
//!   writes the Swift of each host file and the shared file, or nothing when a
//!   document has an error, and prints diagnostics in `path:line:col:` form;
//!   `--report <file>` writes what the target compiled as JSON;
//!   `--persisted <file>` names where the persisted documents file goes;
//!   `--check` writes nothing and names every output that is stale.
//! - `validate --schema <sdl> <files…>` is the same compilation with no output.
//! - `print <Name> --schema <sdl> <files…>` prints one operation's text and id.
//! - `bench --schema <sdl> --fragments <n>` compiles a synthetic corpus twice
//!   and prints the warm timings.

mod config;
mod decide;
mod diagnostics;
mod directives;
mod documents;
mod emit;
mod kotlin;
mod kotlin_names;
mod names;
mod naming;
mod pipeline;
mod report;
mod swift;

use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};
use std::process::ExitCode;

use crate::config::{Config, Language};
use crate::diagnostics::Rendered;
use crate::documents::{Document, HOSTS, HostLanguage};
use crate::kotlin::KotlinHost;
use crate::naming::NameError;
use crate::swift::SwiftHost;

/// The host language a run writes, which names the outputs: every
/// source's, the shared file, and the files of an output directory the
/// compiler owns.
fn outputs(language: Language) -> &'static dyn HostLanguage {
    match language {
        Language::Swift => &SwiftHost,
        Language::Kotlin => &KotlinHost,
    }
}

/// The language a run generates: the one `--language` names, `swift` by
/// default, or the one its first host file is written in. A host file of
/// another language is an error at the file, reported here.
fn language_of(options: &Options) -> Result<Language, DriverError> {
    let requested = match options.values.get("language").map(String::as_str) {
        None => None,
        Some("swift") => Some(Language::Swift),
        Some("kotlin") => Some(Language::Kotlin),
        Some(other) => {
            return Err(DriverError::Usage(format!(
                "`--language` is `swift` or `kotlin`, not `{other}`"
            )));
        }
    };
    let mut first: Option<(&Path, Language)> = None;
    for path in &options.paths {
        let language = match path.extension().and_then(|extension| extension.to_str()) {
            Some("swift") => Language::Swift,
            Some("kt") => Language::Kotlin,
            _ => continue,
        };
        let expected = match (requested, first) {
            (Some(requested), _) => requested,
            (None, Some((_, first_language))) => first_language,
            (None, None) => {
                first = Some((path, language));
                continue;
            }
        };
        if language == expected {
            continue;
        }
        let reason = match (requested, first) {
            (Some(_), _) => format!("`--language` asks for {}", expected.name()),
            (None, Some((first_path, _))) => format!(
                "the run writes {} for `{}`; run `batonc` once per language",
                expected.name(),
                first_path.display()
            ),
            (None, None) => unreachable!("a file sets the language before another is checked"),
        };
        eprintln!(
            "{}:1:1: error: a {} host in a run of {}: {reason}",
            path.display(),
            language.name(),
            expected.name()
        );
        return Err(DriverError::Reported);
    }
    Ok(requested
        .or(first.map(|(_, language)| language))
        .unwrap_or_default())
}

fn main() -> ExitCode {
    let arguments: Vec<String> = std::env::args().skip(1).collect();
    let Some(command) = arguments.first() else {
        eprintln!("usage: batonc <scan|plan|generate|validate|print|bench> …");
        return ExitCode::from(2);
    };
    let result = match command.as_str() {
        "scan" => scan(&arguments[1..]),
        "plan" => plan(&arguments[1..]),
        "generate" => generate(&arguments[1..]),
        "validate" => validate(&arguments[1..]),
        "print" => print(&arguments[1..]),
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
    Config(#[from] crate::config::ConfigError),
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
    /// Under `--check`, outputs on disk differ from what `generate` writes.
    #[error("batonc: {0} outputs differ from what `generate` writes")]
    Stale(usize),
}

/// Parsed command-line options: `--name value` pairs, flags, repeated
/// `--emit`, and the remaining positional paths.
struct Options {
    values: BTreeMap<String, String>,
    flags: BTreeSet<String>,
    emits: Vec<(PathBuf, PathBuf)>,
    paths: Vec<PathBuf>,
}

/// The options that take no value.
const FLAGS: &[&str] = &["check"];

/// Reads a command's arguments; `allowed` names the options the command
/// takes, and any other is an error rather than a silent default.
fn parse_options(
    command: &str,
    arguments: &[String],
    allowed: &[&str],
) -> Result<Options, DriverError> {
    let mut options = Options {
        values: BTreeMap::new(),
        flags: BTreeSet::new(),
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
            if FLAGS.contains(&name) {
                options.flags.insert(name.to_string());
                continue;
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
        Some(path) => Config::load(Path::new(path))?,
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
    let options = parse_options("plan", arguments, &["schema", "config", "language"])?;
    let language = language_of(&options)?;
    let mut sources = read_schema(&options)?;
    sources.config.language = language;
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

/// One compilation of a target's documents: the schema sources, the
/// documents, the plan, and the lines the compiler itself reports after the
/// front end, the host files' checks and unused fragments.
struct Compilation {
    sources: SchemaSources,
    documents: Vec<Document>,
    plan: pipeline::Plan,
    rendered: Vec<Rendered>,
}

/// Compiles the documents `options` names against the schema it names, or
/// prints the diagnostics and reports. Relay's program is all or nothing:
/// after an error nothing is written, so a command stops on the first wave
/// of diagnostics instead of a second one from a module half written.
fn compile_documents(options: &Options) -> Result<Compilation, DriverError> {
    let language = language_of(options)?;
    let mut sources = read_schema(options)?;
    sources.config.language = language;
    let (documents, errors) = documents::collect(&options.paths);
    for error in &errors {
        eprintln!("{error}");
    }
    let compiled = pipeline::compile(
        &sources.sdl,
        &sources.path,
        &sources.extensions,
        &documents,
        &sources.config,
    );
    let plan = match compiled {
        Ok(compiled) => compiled.plan,
        Err(diagnostics) => {
            let known = with_schema(&documents, &sources.path, &sources.sdl);
            for diagnostic in &diagnostics {
                eprintln!("{}", diagnostics::render(diagnostic, &known));
            }
            return Err(DriverError::Reported);
        }
    };
    if !errors.is_empty() {
        return Err(DriverError::Reported);
    }
    let mut rendered: Vec<Rendered> = HOSTS
        .into_iter()
        .flat_map(|host| host.check(&documents, &plan))
        .collect();
    rendered.extend(unused_fragments(&documents, &plan));
    Ok(Compilation {
        sources,
        documents,
        plan,
        rendered,
    })
}

/// The code of a compilation in the language of its run, decided in the
/// target's names and printed by it, or the name errors printed and
/// reported.
fn emitted(compilation: &Compilation) -> Result<(emit::Output, decide::Program), DriverError> {
    let config = &compilation.sources.config;
    match config.language {
        Language::Swift => {
            let target = emit::Swift::new(config);
            let program = decided(compilation, target.naming())?;
            Ok((target.emit(&program), program))
        }
        Language::Kotlin => {
            let target = emit::Kotlin::new(config, kotlin_packages(&compilation.documents));
            let program = decided(compilation, target.naming())?;
            Ok((target.emit(&program), program))
        }
    }
}

/// The package each Kotlin host declares, by its path: none for a host in
/// the default package.
fn kotlin_packages(documents: &[Document]) -> BTreeMap<String, Option<String>> {
    documents
        .iter()
        .filter(|document| {
            KotlinHost
                .extensions()
                .contains(&extension_of(&document.path))
        })
        .filter_map(|document| {
            let embedded = document.embedded.as_ref()?;
            Some((
                document.path.to_string_lossy().into_owned(),
                embedded.package.clone(),
            ))
        })
        .collect()
}

fn extension_of(path: &Path) -> &str {
    path.extension()
        .and_then(|extension| extension.to_str())
        .unwrap_or("")
}

/// Fails when the Kotlin target writes code in a package `baton.json` does
/// not name: the shared file's, when it is written, and a `.graphql`
/// source's, which declares none of its own. A package named is a dotted
/// name of identifiers.
fn check_kotlin_package(compilation: &Compilation, writes_shared: bool) -> Result<(), DriverError> {
    let config = &compilation.sources.config;
    if config.language != Language::Kotlin {
        return Ok(());
    }
    let at = |message: String| {
        if config.path.as_os_str().is_empty() {
            eprintln!("batonc: {message}");
        } else {
            eprintln!("{}:1:1: error: {message}", config.path.display());
        }
        DriverError::Reported
    };
    if let Some(package) = config.kotlin_package() {
        let valid = package.split('.').all(|segment| {
            let mut characters = segment.chars();
            characters
                .next()
                .is_some_and(|first| first.is_alphabetic() || first == '_')
                && characters.all(|character| character.is_alphanumeric() || character == '_')
                && !kotlin_names::KEYWORDS.contains(&segment)
        });
        if !valid {
            return Err(at(format!(
                "`kotlin.package` is `{package}`, which is not a package's name: write dotted identifiers, such as `com.example.app`"
            )));
        }
        return Ok(());
    }
    let graphql = compilation
        .documents
        .iter()
        .find(|document| matches!(extension_of(&document.path), "graphql" | "gql"));
    let needs = match (graphql, writes_shared) {
        (Some(document), _) => format!(
            "the Kotlin code of `{}` needs a package",
            document.path.display()
        ),
        (None, true) => "the Kotlin target's shared file needs a package".to_string(),
        (None, false) => return Ok(()),
    };
    Err(at(format!(
        "{needs}: name it in `baton.json` as `\"kotlin\": {{\"package\": …}}`"
    )))
}

/// The program of a compilation decided in `naming`, or the name errors
/// printed and reported.
fn decided(
    compilation: &Compilation,
    naming: &dyn naming::Naming,
) -> Result<decide::Program, DriverError> {
    let documents = &compilation.documents;
    decide::program(&compilation.plan, naming).map_err(|errors| {
        for error in &errors {
            match error {
                NameError::Clash(clash) => eprintln!(
                    "{}",
                    diagnostics::at(&clash.origin, documents, clash.to_string())
                ),
                NameError::Duplicate(duplicate) => eprintln!("batonc: {duplicate}"),
            }
        }
        DriverError::Reported
    })
}

/// Prints the compiler's own lines and reports when one is an error.
fn finish(rendered: &[Rendered]) -> Result<(), DriverError> {
    for line in rendered {
        eprintln!("{line}");
    }
    if rendered.iter().any(|line| line.severity == "error") {
        Err(DriverError::Reported)
    } else {
        Ok(())
    }
}

fn generate(arguments: &[String]) -> Result<(), DriverError> {
    let options = parse_options(
        "generate",
        arguments,
        &[
            "schema",
            "config",
            "out",
            "shared",
            "emit",
            "report",
            "persisted",
            "check",
            "language",
        ],
    )?;
    let out_dir = options.values.get("out").map(PathBuf::from);
    let shared_path = options.values.get("shared").map(PathBuf::from);
    let compilation = compile_documents(&options)?;
    let (documents, plan) = (&compilation.documents, &compilation.plan);
    let outputs = outputs(compilation.sources.config.language);
    check_kotlin_package(&compilation, shared_path.is_some() || out_dir.is_some())?;
    let (output, program) = emitted(&compilation)?;

    let root = std::env::current_dir().unwrap_or_default();
    let mut targets: Vec<(PathBuf, PathBuf)> = options.emits.clone();
    if let (true, Some(out_dir)) = (targets.is_empty(), &out_dir) {
        for path in documents
            .iter()
            .map(|document| &document.path)
            .collect::<BTreeSet<_>>()
        {
            targets.push((path.clone(), out_dir.join(outputs.output_name(path, &root))));
        }
    }
    let shared_path = shared_path.or_else(|| {
        out_dir
            .as_ref()
            .map(|dir| dir.join(outputs.shared_output_name()))
    });
    check_targets(&targets, shared_path.as_deref(), &output)?;

    // Every declared output is planned, so the build system never sees a
    // missing file; a host file without documents gets a header only.
    let mut planned: Vec<(PathBuf, String)> = Vec::new();
    for (source, destination) in &targets {
        let text = output
            .files
            .get(&source.to_string_lossy().into_owned())
            .cloned()
            .unwrap_or_else(|| "// Generated by batonc. No GraphQL in this file.\n".to_string());
        planned.push((destination.clone(), text));
    }
    if let Some(shared_path) = &shared_path {
        planned.push((shared_path.clone(), output.shared.clone()));
    }
    // Under `persistConfig`, Relay's map from id to text, which a
    // registration step consumes: where `--persisted` says, since a build
    // system declares its outputs before it reads the configuration; else
    // in the output directory under the build, whose sandbox keeps the
    // source tree; else beside the configuration, when run by hand.
    let persisted_path = options.values.get("persisted").map(PathBuf::from);
    match (&compilation.sources.config.persist_config, persisted_path) {
        (Some(persist), persisted_path) => {
            let persist_path = persisted_path.unwrap_or_else(|| match &out_dir {
                Some(out_dir) => {
                    out_dir.join(Path::new(&persist.file).file_name().unwrap_or_default())
                }
                None => options
                    .values
                    .get("config")
                    .map(Path::new)
                    .and_then(Path::parent)
                    .map(Path::to_path_buf)
                    .unwrap_or_default()
                    .join(&persist.file),
            });
            planned.push((persist_path, persisted_documents(plan)));
        }
        (None, Some(_)) => {
            return Err(DriverError::Usage(
                "`--persisted` names where the persisted documents file is written, and the configuration has no `persistConfig`".to_string(),
            ));
        }
        (None, None) => {}
    }
    // The report: what this target compiled, for the people who register
    // operations and review contract changes.
    if let Some(report_path) = options.values.get("report") {
        planned.push((
            PathBuf::from(report_path),
            report::text(plan, &root, &program),
        ));
    }

    if options.flags.contains("check") {
        check_outputs(&planned, out_dir.as_deref(), outputs)?;
    } else {
        for (path, text) in &planned {
            write_output(path, text)?;
        }
        if let Some(out_dir) = &out_dir {
            let written: Vec<&Path> = planned.iter().map(|(path, _)| path.as_path()).collect();
            remove_stale_outputs(out_dir, &written, outputs)?;
        }
    }
    finish(&compilation.rendered)
}

/// `--check`: compares every planned output with the file at its path and
/// names each that is stale or missing, and each output in the output
/// directory that nothing writes any more; reports when any is.
fn check_outputs(
    planned: &[(PathBuf, String)],
    out_dir: Option<&Path>,
    outputs: &dyn HostLanguage,
) -> Result<(), DriverError> {
    let mut stale = 0;
    for (path, text) in planned {
        match std::fs::read_to_string(path) {
            Ok(existing) if &existing == text => {}
            Ok(_) => {
                eprintln!("{}: stale", path.display());
                stale += 1;
            }
            Err(_) => {
                eprintln!("{}: missing", path.display());
                stale += 1;
            }
        }
    }
    if let Some(out_dir) = out_dir {
        let planned_paths: BTreeSet<PathBuf> = planned
            .iter()
            .filter_map(|(path, _)| std::fs::canonicalize(path).ok())
            .collect();
        for entry in std::fs::read_dir(out_dir).into_iter().flatten().flatten() {
            let path = entry.path();
            if !outputs.is_output(&path) {
                continue;
            }
            let Ok(canonical) = std::fs::canonicalize(&path) else {
                continue;
            };
            if !planned_paths.contains(&canonical) {
                eprintln!("{}: nothing writes it any more", path.display());
                stale += 1;
            }
        }
    }
    if stale == 0 {
        Ok(())
    } else {
        Err(DriverError::Stale(stale))
    }
}

/// The same compilation as `generate` with no output: diagnostics and an
/// exit code, for an editor or a hook.
fn validate(arguments: &[String]) -> Result<(), DriverError> {
    let options = parse_options("validate", arguments, &["schema", "config", "language"])?;
    let compilation = compile_documents(&options)?;
    check_kotlin_package(&compilation, false)?;
    emitted(&compilation)?;
    finish(&compilation.rendered)
}

/// The same compilation, printing one operation's text, the very text the
/// app sends, after `# documentId: <id>` when it is persisted.
fn print(arguments: &[String]) -> Result<(), DriverError> {
    let mut options = parse_options("print", arguments, &["schema", "config", "language"])?;
    if options.paths.is_empty() {
        return Err(DriverError::Usage(
            "`print` takes the operation's name, then the files".to_string(),
        ));
    }
    let name = options.paths.remove(0).to_string_lossy().into_owned();
    let compilation = compile_documents(&options)?;
    let Some(operation) = compilation
        .plan
        .operations
        .iter()
        .find(|operation| operation.name == name)
    else {
        return Err(DriverError::Usage(format!(
            "no operation is named `{name}`"
        )));
    };
    if let Some(id) = &operation.id {
        println!("# documentId: {id}");
    }
    println!("{}", operation.text);
    Ok(())
}

/// A fragment no operation reaches, directly or through another fragment,
/// warned at its definition: nothing can read it, and the code
/// generated for it is dead.
fn unused_fragments(documents: &[Document], plan: &pipeline::Plan) -> Vec<Rendered> {
    let reach = report::reach(plan);
    let reached: BTreeSet<&str> = reach.values().flatten().map(String::as_str).collect();
    plan.fragments
        .iter()
        .filter(|fragment| !reached.contains(fragment.name.as_str()))
        .filter_map(|fragment| {
            let origin = fragment.origin.as_ref()?;
            Some(diagnostics::warning_at(
                origin,
                documents,
                format!(
                    "fragment `{}` is spread by no operation; nothing can read it",
                    fragment.name
                ),
            ))
        })
        .collect()
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
/// own, so only the outputs `outputs` names are touched.
fn remove_stale_outputs(
    out_dir: &Path,
    written: &[&Path],
    outputs: &dyn HostLanguage,
) -> Result<(), DriverError> {
    let Ok(entries) = std::fs::read_dir(out_dir) else {
        return Ok(());
    };
    let written: std::collections::BTreeSet<PathBuf> = written
        .iter()
        .filter_map(|path| std::fs::canonicalize(path).ok())
        .collect();
    for entry in entries.flatten() {
        let path = entry.path();
        if !outputs.is_output(&path) {
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
        start: documents::Position { line: 1, column: 1 },
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

#[cfg(test)]
#[path = "tests/driver_tests.rs"]
mod driver_tests;

#[cfg(test)]
#[path = "tests/unused_fragment_tests.rs"]
mod unused_fragment_tests;
