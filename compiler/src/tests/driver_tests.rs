//! Tests of the driver: `--check` read as a flag by the commands that take
//! it, and `check_outputs` comparing what `generate` would write with the
//! files on disk.

use super::*;

/// The Swift host the stale-output checks compare against.
const SWIFT: Host = Host::Swift(SwiftHost);

fn arguments(texts: &[&str]) -> Vec<String> {
    texts.iter().map(|text| text.to_string()).collect()
}

#[test]
fn check_is_a_flag_that_takes_no_value() {
    let options = parse_options(
        "generate",
        &arguments(&["--check", "Screen.swift", "--out", "out"]),
        &["out", "check"],
    )
    .unwrap_or_else(|error| panic!("{error}"));
    assert!(options.flags.contains("check"));
    assert_eq!(options.paths, [PathBuf::from("Screen.swift")]);
    assert_eq!(options.values.get("out").map(String::as_str), Some("out"));
    assert!(!options.values.contains_key("check"));
}

#[test]
fn check_as_the_last_argument_needs_no_value() {
    let options = parse_options("generate", &arguments(&["--check"]), &["check"])
        .unwrap_or_else(|error| panic!("{error}"));
    assert!(options.flags.contains("check"));
    assert!(options.paths.is_empty());
}

#[test]
fn check_is_refused_by_a_command_that_does_not_take_it() {
    let refused = parse_options(
        "validate",
        &arguments(&["--check", "Screen.swift"]),
        &["schema", "config"],
    );
    let Err(DriverError::Usage(message)) = refused else {
        panic!("`--check` is refused as a usage error");
    };
    assert_eq!(
        message,
        "`--check` is not an option of `validate`, which takes `--schema`, `--config`"
    );
}

/// A directory under the system's temporary one, empty for one test and
/// removed after it.
struct Scratch(PathBuf);

impl Scratch {
    fn new(name: &str) -> Scratch {
        let path =
            std::env::temp_dir().join(format!("batonc-driver-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&path);
        std::fs::create_dir_all(&path).expect("the scratch directory is created");
        Scratch(path)
    }

    fn join(&self, name: &str) -> PathBuf {
        self.0.join(name)
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

/// The outputs `generate` would write into `out`, written to disk.
fn fresh(out: &Scratch) -> Vec<(PathBuf, String)> {
    let planned = vec![
        (out.join("Screen.baton.swift"), "// Screen\n".to_string()),
        (out.join("Baton.baton.swift"), "// Shared\n".to_string()),
    ];
    for (path, text) in &planned {
        std::fs::write(path, text).expect("the output is written");
    }
    planned
}

fn stale_count(result: Result<(), DriverError>) -> usize {
    match result {
        Ok(()) => 0,
        Err(DriverError::Stale(count)) => count,
        Err(other) => panic!("`check_outputs` fails only as stale: {other}"),
    }
}

#[test]
fn fresh_outputs_pass_the_check() {
    let out = Scratch::new("fresh");
    let planned = fresh(&out);
    assert_eq!(
        stale_count(check_outputs(&planned, Some(&out.0), &SWIFT)),
        0
    );
}

#[test]
fn an_edited_output_is_stale() {
    let out = Scratch::new("edited");
    let planned = fresh(&out);
    std::fs::write(out.join("Screen.baton.swift"), "// Screen, edited\n")
        .expect("the output is edited");
    assert_eq!(
        stale_count(check_outputs(&planned, Some(&out.0), &SWIFT)),
        1
    );
    assert_eq!(
        std::fs::read_to_string(out.join("Screen.baton.swift")).ok(),
        Some("// Screen, edited\n".to_string()),
        "the check writes nothing"
    );
}

#[test]
fn a_missing_output_is_stale() {
    let out = Scratch::new("missing");
    let planned = fresh(&out);
    std::fs::remove_file(out.join("Screen.baton.swift")).expect("the output is removed");
    assert_eq!(
        stale_count(check_outputs(&planned, Some(&out.0), &SWIFT)),
        1
    );
    assert!(
        !out.join("Screen.baton.swift").exists(),
        "the check writes nothing"
    );
}

#[test]
fn a_generated_file_nothing_writes_is_stale() {
    let out = Scratch::new("stray");
    let planned = fresh(&out);
    std::fs::write(out.join("Removed.baton.swift"), "// Removed\n").expect("the stray is written");
    assert_eq!(
        stale_count(check_outputs(&planned, Some(&out.0), &SWIFT)),
        1
    );
    assert!(
        out.join("Removed.baton.swift").exists(),
        "the check removes nothing"
    );
}

#[test]
fn a_file_of_another_extension_in_the_output_directory_is_ignored() {
    let out = Scratch::new("other");
    let planned = fresh(&out);
    std::fs::write(out.join("Notes.swift"), "// Notes\n").expect("the file is written");
    std::fs::write(out.join("Baton.report.json"), "{}\n").expect("the file is written");
    assert_eq!(
        stale_count(check_outputs(&planned, Some(&out.0), &SWIFT)),
        0
    );
}

#[test]
fn a_planned_output_outside_the_output_directory_is_compared_too() {
    let out = Scratch::new("inside");
    let elsewhere = Scratch::new("outside");
    let mut planned = fresh(&out);
    let report = elsewhere.join("Baton.report.json");
    planned.push((report.clone(), "{}\n".to_string()));
    std::fs::write(&report, "{}\n").expect("the report is written");
    assert_eq!(
        stale_count(check_outputs(&planned, Some(&out.0), &SWIFT)),
        0
    );
    std::fs::write(&report, "{ \"edited\": true }\n").expect("the report is edited");
    assert_eq!(
        stale_count(check_outputs(&planned, Some(&out.0), &SWIFT)),
        1
    );
    std::fs::remove_file(&report).expect("the report is removed");
    assert_eq!(
        stale_count(check_outputs(&planned, Some(&out.0), &SWIFT)),
        1
    );
}

#[test]
fn every_difference_is_counted() {
    let out = Scratch::new("every");
    let planned = fresh(&out);
    std::fs::write(out.join("Screen.baton.swift"), "// edited\n").expect("the output is edited");
    std::fs::remove_file(out.join("Baton.baton.swift")).expect("the output is removed");
    std::fs::write(out.join("Removed.baton.swift"), "// Removed\n").expect("the stray is written");
    assert_eq!(
        stale_count(check_outputs(&planned, Some(&out.0), &SWIFT)),
        3
    );
}

#[test]
fn a_configuration_that_spells_on_error_abort_is_refused_with_a_message_naming_halt() {
    let directory = Scratch::new("abort");
    let path = directory.join("baton.json");
    std::fs::write(&path, r#"{"onError": "ABORT"}"#).expect("the configuration is written");
    let Err(error) = Config::load(&path) else {
        panic!("`ABORT` is not an `onError` value since graphql-spec#1163 named it `HALT`");
    };
    let message = error.to_string();
    assert!(message.contains("ABORT"), "{message}");
    for word in ["PROPAGATE", "NULL", "HALT"] {
        assert!(message.contains(word), "{message}");
    }
}

// Where the schema is read from.

/// The options `plan` reads from `texts`.
fn plan_options(texts: &[&str]) -> Options {
    parse_options("plan", &arguments(texts), &["schema", "config", "language"])
        .unwrap_or_else(|error| panic!("{error}"))
}

/// The schema's files `read_schema` reads for `texts`, each as its path's
/// file name and its text, or the usage error it refuses them with.
fn schema_read(texts: &[&str]) -> Result<Vec<(String, String)>, String> {
    match read_schema(&plan_options(texts)) {
        Ok(sources) => Ok(sources
            .files
            .schema
            .iter()
            .map(|file| {
                let name = Path::new(&file.path)
                    .file_name()
                    .expect("a schema file has a name")
                    .to_string_lossy()
                    .into_owned();
                (name, file.text.clone())
            })
            .collect()),
        Err(DriverError::Usage(message)) => Err(message),
        Err(other) => panic!("the schema is refused only as a usage error: {other}"),
    }
}

/// Writes each of `files`, named relative to `directory`, with its name as
/// its text.
fn write_files(directory: &Scratch, files: &[&str]) {
    for name in files {
        let path = directory.join(name);
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent).expect("the directory is created");
        }
        std::fs::write(&path, name).expect("the file is written");
    }
}

fn read(names: &[&str]) -> Result<Vec<(String, String)>, String> {
    Ok(names
        .iter()
        .map(|name| {
            let file = Path::new(name)
                .file_name()
                .expect("a name has a file name")
                .to_string_lossy()
                .into_owned();
            (file, name.to_string())
        })
        .collect())
}

#[test]
fn schema_dir_names_a_directory_whose_graphql_files_in_name_order_are_the_schema() {
    let directory = Scratch::new("schema-dir");
    write_files(
        &directory,
        &["schema/b.graphql", "schema/a.graphql", "schema/notes.txt"],
    );
    let config = directory.join("baton.json");
    std::fs::write(&config, r#"{"schemaDir": "schema"}"#).expect("the configuration is written");
    assert_eq!(
        schema_read(&["--config", &config.to_string_lossy()]),
        read(&["schema/a.graphql", "schema/b.graphql"])
    );
}

#[test]
fn a_configuration_naming_both_schema_and_schema_dir_is_a_usage_error() {
    let directory = Scratch::new("schema-both");
    write_files(&directory, &["schema.graphql", "schema/a.graphql"]);
    let config = directory.join("baton.json");
    std::fs::write(
        &config,
        r#"{"schema": "schema.graphql", "schemaDir": "schema"}"#,
    )
    .expect("the configuration is written");
    let config = config.to_string_lossy();
    assert_eq!(
        schema_read(&["--config", &config]),
        Err(format!(
            "{config} names both `schema` and `schemaDir`: the schema is one file or one directory of files"
        ))
    );
}

#[test]
fn schema_dir_naming_a_file_is_a_usage_error() {
    let directory = Scratch::new("schema-dir-file");
    write_files(&directory, &["schema.graphql"]);
    let config = directory.join("baton.json");
    std::fs::write(&config, r#"{"schemaDir": "schema.graphql"}"#)
        .expect("the configuration is written");
    assert_eq!(
        schema_read(&["--config", &config.to_string_lossy()]),
        Err(format!(
            "`schemaDir` names {}, which is not a directory; a schema of one file is named by `schema`",
            directory.join("schema.graphql").display()
        ))
    );
}

#[test]
fn a_schema_directory_without_a_graphql_file_is_a_usage_error() {
    let directory = Scratch::new("schema-dir-empty");
    write_files(&directory, &["schema/notes.txt"]);
    let config = directory.join("baton.json");
    std::fs::write(&config, r#"{"schemaDir": "schema"}"#).expect("the configuration is written");
    let expected = Err(format!(
        "{} holds no `.graphql` file: the schema is the files of that directory",
        directory.join("schema").display()
    ));
    assert_eq!(
        schema_read(&["--config", &config.to_string_lossy()]),
        expected
    );
    assert_eq!(
        schema_read(&["--schema", &directory.join("schema").to_string_lossy()]),
        expected,
        "`--schema` naming the directory is refused alike"
    );
}

#[test]
fn a_repeated_schema_option_reads_its_files_and_directories_in_the_order_given() {
    let directory = Scratch::new("schema-repeated");
    write_files(
        &directory,
        &[
            "server.graphql",
            "feeds/b.graphql",
            "feeds/a.graphql",
            "rest.graphql",
        ],
    );
    let path = |name: &str| directory.join(name).to_string_lossy().into_owned();
    assert_eq!(
        schema_read(&[
            "--schema",
            &path("rest.graphql"),
            "--schema",
            &path("server.graphql"),
        ]),
        read(&["rest.graphql", "server.graphql"]),
        "the files are the schema in the order the options name them"
    );
    assert_eq!(
        schema_read(&[
            "--schema",
            &path("server.graphql"),
            "--schema",
            &path("feeds"),
            "--schema",
            &path("rest.graphql"),
        ]),
        read(&[
            "server.graphql",
            "feeds/a.graphql",
            "feeds/b.graphql",
            "rest.graphql"
        ]),
        "a directory gives its files in name order where it is named"
    );
}

#[test]
fn the_schema_option_takes_the_place_of_the_configuration_s_schema() {
    let directory = Scratch::new("schema-override");
    write_files(&directory, &["configured.graphql", "named.graphql"]);
    let config = directory.join("baton.json");
    std::fs::write(
        &config,
        r#"{"schema": "configured.graphql", "schemaExtensions": []}"#,
    )
    .expect("the configuration is written");
    let config = config.to_string_lossy();
    assert_eq!(
        schema_read(&["--config", &config]),
        read(&["configured.graphql"])
    );
    assert_eq!(
        schema_read(&[
            "--config",
            &config,
            "--schema",
            &directory.join("named.graphql").to_string_lossy(),
        ]),
        read(&["named.graphql"])
    );
}

#[test]
fn a_diagnostic_in_a_second_schema_file_or_an_extension_file_renders_at_its_line_and_column() {
    let directory = Scratch::new("schema-positions");
    let server = "type Query {\n  name: String\n}\n";
    let second = "# A second backend.\n\nextend input Missing {\n  rank: Int\n}\n";
    let extension = "# The app's own fields.\n\nextend type Query {\n  draft: String!\n}\n";
    std::fs::create_dir_all(directory.join("schema")).expect("the directory is created");
    std::fs::write(directory.join("schema/server.graphql"), server).expect("the schema is written");
    std::fs::write(directory.join("extension.graphql"), extension)
        .expect("the extension is written");
    let config = directory.join("baton.json");
    std::fs::write(
        &config,
        r#"{"schemaDir": "schema", "schemaExtensions": ["extension.graphql"]}"#,
    )
    .expect("the configuration is written");
    let rendered = |options: &[&str]| -> Vec<String> {
        let sources = read_schema(&plan_options(options)).unwrap_or_else(|error| panic!("{error}"));
        let diagnostics = pipeline::compile(&sources.files, &[], &sources.config)
            .err()
            .expect("the schema does not compile");
        let known = with_schema(&[], &sources.files);
        diagnostics
            .iter()
            .map(|diagnostic| diagnostics::render(diagnostic, &known).to_string())
            .collect()
    };
    let schema_directory = Scratch::new("schema-positions-schema");
    std::fs::write(schema_directory.join("a.graphql"), server).expect("the schema is written");
    std::fs::write(schema_directory.join("b.graphql"), second).expect("the schema is written");
    assert_eq!(
        rendered(&["--schema", &schema_directory.0.to_string_lossy()]),
        vec![format!(
            "{}:3:14: error: `extend input` is not built: Relay's front end has no code for it, so write what it adds in the definition it extends",
            schema_directory.join("b.graphql").display()
        )],
        "the second schema file's line and column"
    );
    assert_eq!(
        rendered(&["--config", &config.to_string_lossy()]),
        vec![format!(
            "{}:4:3: error: the client field `Query.draft` is non-null: a client field is nullable, since no server promises it",
            directory.join("extension.graphql").display()
        )],
        "the extension file's line and column"
    );
}
