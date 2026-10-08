//! `batonc validate`, `print` and `generate --check` run as a person or a
//! hook runs them, from the repository's root over the sample app.

use std::path::{Path, PathBuf};
use std::process::{Command, Output};

/// The repository's root, where the commands run.
fn root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("the compiler sits one level below the repository root")
        .to_path_buf()
}

const CONFIG: &str = "examples/RickAndMorty/baton.json";

/// The sample app's sources, relative to the root.
const SOURCES: [&str; 4] = [
    "examples/RickAndMorty/CharacterScreen.swift",
    "examples/RickAndMorty/CharactersScreen.swift",
    "examples/RickAndMorty/EpisodeAndLocationScreens.swift",
    "examples/RickAndMorty/RickAndMortyApp.swift",
];

fn batonc(arguments: &[&str]) -> Output {
    Command::new(env!("CARGO_BIN_EXE_batonc"))
        .current_dir(root())
        .args(arguments)
        .output()
        .expect("batonc runs")
}

/// `command`, then the arguments before the sources, then the sources.
fn over_sources(command: &str, before: &[&str]) -> Output {
    over_sources_with(CONFIG, command, before)
}

/// `over_sources` under the configuration at `config`.
fn over_sources_with(config: &str, command: &str, before: &[&str]) -> Output {
    let mut arguments = vec![command];
    arguments.extend_from_slice(before);
    arguments.extend_from_slice(&["--config", config]);
    arguments.extend_from_slice(&SOURCES);
    batonc(&arguments)
}

/// The sample's configuration with `persistConfig` naming `persisted.json`,
/// written into `directory`; returns its path.
fn persisting_config(directory: &Scratch) -> String {
    let schema = root().join("spec/rickandmorty/schema.graphql");
    let config = serde_json::json!({
        "schema": schema.to_string_lossy(),
        "lookups": [
            { "field": "Query.character", "type": "Character", "argument": "id" },
            { "field": "Query.location", "type": "Location", "argument": "id" },
            { "field": "Query.episode", "type": "Episode", "argument": "id" }
        ],
        "persistConfig": { "file": "persisted.json" }
    });
    let path = directory.join("baton.json");
    std::fs::write(&path, config.to_string()).expect("the configuration is written");
    path.to_string_lossy().into_owned()
}

/// The names of the files directly under `directory`.
fn names(directory: &Path) -> Vec<String> {
    let mut names: Vec<String> = std::fs::read_dir(directory)
        .map(|entries| {
            entries
                .flatten()
                .map(|entry| entry.file_name().to_string_lossy().into_owned())
                .collect()
        })
        .unwrap_or_default();
    names.sort();
    names
}

fn stdout(output: &Output) -> String {
    String::from_utf8_lossy(&output.stdout).into_owned()
}

fn stderr(output: &Output) -> String {
    String::from_utf8_lossy(&output.stderr).into_owned()
}

/// A directory under the system's temporary one, empty for one test and
/// removed after it.
struct Scratch(PathBuf);

impl Scratch {
    fn new(name: &str) -> Scratch {
        let path = std::env::temp_dir().join(format!("batonc-cli-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&path);
        std::fs::create_dir_all(&path).expect("the scratch directory is created");
        Scratch(path)
    }

    fn join(&self, name: &str) -> PathBuf {
        self.0.join(name)
    }

    fn text(&self) -> String {
        self.0.to_string_lossy().into_owned()
    }

    /// The names and contents of the directory's files, in name order.
    fn contents(&self) -> Vec<(String, String)> {
        let mut contents: Vec<(String, String)> = std::fs::read_dir(&self.0)
            .expect("the scratch directory is readable")
            .flatten()
            .map(|entry| {
                (
                    entry.file_name().to_string_lossy().into_owned(),
                    std::fs::read_to_string(entry.path()).unwrap_or_default(),
                )
            })
            .collect();
        contents.sort();
        contents
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

#[test]
fn validate_over_the_sample_app_succeeds_and_says_nothing() {
    let output = over_sources("validate", &[]);
    assert!(output.status.success(), "{}", stderr(&output));
    assert_eq!(stderr(&output), "");
    assert_eq!(stdout(&output), "");
}

#[test]
fn print_writes_the_text_of_the_operation_it_names() {
    let output = over_sources("print", &["CharacterHeaderQuery"]);
    assert!(output.status.success(), "{}", stderr(&output));
    assert!(
        stdout(&output).starts_with("query CharacterHeaderQuery"),
        "{}",
        stdout(&output)
    );
    assert!(stdout(&output).contains("fragment CharacterHeader_character on Character"));
}

#[test]
fn print_of_an_unknown_name_is_a_usage_error() {
    let output = over_sources("print", &["Nope"]);
    assert_eq!(output.status.code(), Some(1));
    assert!(
        stderr(&output).contains("no operation is named `Nope`"),
        "{}",
        stderr(&output)
    );
    assert_eq!(stdout(&output), "");
}

#[test]
fn print_without_a_name_is_a_usage_error() {
    let output = batonc(&["print", "--config", CONFIG]);
    assert_eq!(output.status.code(), Some(1));
    assert_eq!(
        stderr(&output).trim_end(),
        "batonc: `print` takes the operation's name, then the files"
    );
}

#[test]
fn check_passes_after_generate_and_writes_nothing() {
    let out = Scratch::new("check-fresh");
    let report = out.join("Baton.report.json").to_string_lossy().into_owned();
    let generated = over_sources("generate", &["--out", &out.text(), "--report", &report]);
    assert!(generated.status.success(), "{}", stderr(&generated));
    let written = out.contents();
    assert!(written.iter().any(|(name, _)| name == "Baton.baton.swift"));
    assert!(written.iter().any(|(name, _)| name == "Baton.report.json"));

    let checked = over_sources(
        "generate",
        &["--out", &out.text(), "--report", &report, "--check"],
    );
    assert!(checked.status.success(), "{}", stderr(&checked));
    assert_eq!(stderr(&checked), "");
    assert_eq!(out.contents(), written, "the check writes nothing");
}

#[test]
fn check_names_each_output_that_differs_and_writes_nothing() {
    let out = Scratch::new("check-stale");
    let report = out.join("Baton.report.json").to_string_lossy().into_owned();
    let generated = over_sources("generate", &["--out", &out.text(), "--report", &report]);
    assert!(generated.status.success(), "{}", stderr(&generated));

    let shared = out.join("Baton.baton.swift");
    let mut edited = std::fs::read_to_string(&shared).expect("the shared file is written");
    edited.push_str("// An edit.\n");
    std::fs::write(&shared, &edited).expect("the shared file is edited");
    std::fs::remove_file(&report).expect("the report is removed");
    let stray = out.join("Stray.baton.swift");
    std::fs::write(&stray, "// Stray.\n").expect("the stray file is written");
    let before = out.contents();

    let checked = over_sources(
        "generate",
        &["--out", &out.text(), "--report", &report, "--check"],
    );
    assert_eq!(checked.status.code(), Some(1), "{}", stderr(&checked));
    let errors = stderr(&checked);
    assert!(
        errors.contains(&format!("{}: stale", shared.display())),
        "{errors}"
    );
    assert!(errors.contains(&format!("{report}: missing")), "{errors}");
    assert!(
        errors.contains(&format!("{}: nothing writes it any more", stray.display())),
        "{errors}"
    );
    assert!(
        errors.contains("batonc: 3 outputs differ from what `generate` writes"),
        "{errors}"
    );
    assert_eq!(errors.lines().count(), 4, "{errors}");
    assert_eq!(out.contents(), before, "the check writes nothing");
    assert_eq!(std::fs::read_to_string(&shared).ok(), Some(edited));
}

#[test]
fn validate_warns_at_the_name_of_a_fragment_no_operation_spreads_and_succeeds() {
    let directory = Scratch::new("unused");
    let document = directory.join("Unused.graphql");
    std::fs::write(
        &document,
        "query Spread { character(id: 1) { id ...Spread_character } }\n\
         fragment Spread_character on Character { name }\n\
         \n\
         fragment Unused_character on Character { name }\n",
    )
    .expect("the document is written");
    let path = document.to_string_lossy().into_owned();
    let output = batonc(&[
        "validate",
        "--schema",
        "spec/rickandmorty/schema.graphql",
        &path,
    ]);
    assert!(output.status.success(), "{}", stderr(&output));
    let errors = stderr(&output);
    let warnings: Vec<&str> = errors
        .lines()
        .filter(|line| line.contains("warning:"))
        .collect();
    assert_eq!(
        warnings,
        [format!(
            "{path}:4:10: warning: fragment `Unused_character` is spread by no operation; nothing can read it"
        )],
        "{errors}"
    );
}

#[test]
fn generate_writes_the_persisted_documents_where_persisted_names_and_not_under_out() {
    let directory = Scratch::new("persisted-named");
    let config = persisting_config(&directory);
    let out = directory.join("out");
    let out_text = out.to_string_lossy().into_owned();
    let persisted = directory.join("docs/persisted-documents.json");
    let persisted_text = persisted.to_string_lossy().into_owned();

    let generated = over_sources_with(
        &config,
        "generate",
        &["--out", &out_text, "--persisted", &persisted_text],
    );
    assert!(generated.status.success(), "{}", stderr(&generated));
    assert!(!names(&out).contains(&"persisted.json".to_string()));
    assert!(names(&out).contains(&"Baton.baton.swift".to_string()));
    assert!(!directory.join("persisted.json").exists());

    let text = std::fs::read_to_string(&persisted).expect("the persisted file is written");
    let documents: serde_json::Map<String, serde_json::Value> =
        serde_json::from_str(&text).expect("the persisted file is a JSON object");
    assert!(!documents.is_empty());
    for (id, operation) in &documents {
        let operation = operation
            .as_str()
            .expect("each value is the operation's text");
        let name = operation
            .split_whitespace()
            .nth(1)
            .and_then(|word| word.split(['(', '{']).next())
            .expect("the text names its operation");
        let printed = over_sources_with(&config, "print", &[name]);
        assert!(printed.status.success(), "{}", stderr(&printed));
        assert_eq!(
            stdout(&printed).lines().next(),
            Some(format!("# documentId: {id}").as_str()),
            "{name}"
        );
    }
}

#[test]
fn generate_without_persisted_writes_the_persisted_documents_under_out() {
    let directory = Scratch::new("persisted-out");
    let config = persisting_config(&directory);
    let out = directory.join("out");
    let out_text = out.to_string_lossy().into_owned();

    let generated = over_sources_with(&config, "generate", &["--out", &out_text]);
    assert!(generated.status.success(), "{}", stderr(&generated));
    let text = std::fs::read_to_string(out.join("persisted.json"))
        .expect("the persisted file is written under `--out`");
    let documents: serde_json::Map<String, serde_json::Value> =
        serde_json::from_str(&text).expect("the persisted file is a JSON object");
    assert!(!documents.is_empty());
    assert!(!directory.join("persisted.json").exists());
}

#[test]
fn persisted_without_persist_config_is_a_usage_error_and_writes_nothing() {
    let directory = Scratch::new("persisted-unconfigured");
    let out = directory.join("out");
    let out_text = out.to_string_lossy().into_owned();
    let persisted = directory.join("persisted-documents.json");
    let persisted_text = persisted.to_string_lossy().into_owned();

    let output = over_sources(
        "generate",
        &["--out", &out_text, "--persisted", &persisted_text],
    );
    assert_eq!(output.status.code(), Some(1), "{}", stderr(&output));
    assert_eq!(
        stderr(&output).trim_end(),
        "batonc: `--persisted` names where the persisted documents file is written, and the configuration has no `persistConfig`"
    );
    assert!(directory.contents().is_empty(), "nothing is written");
}

#[test]
fn check_with_persisted_passes_after_generate_and_names_the_persisted_file_when_missing() {
    let directory = Scratch::new("persisted-check");
    let config = persisting_config(&directory);
    let out = directory.join("out");
    let out_text = out.to_string_lossy().into_owned();
    let persisted = directory.join("docs/persisted-documents.json");
    let persisted_text = persisted.to_string_lossy().into_owned();
    let arguments = ["--out", &out_text, "--persisted", &persisted_text];

    let generated = over_sources_with(&config, "generate", &arguments);
    assert!(generated.status.success(), "{}", stderr(&generated));

    let checked = over_sources_with(
        &config,
        "generate",
        &[&arguments[..], &["--check"]].concat(),
    );
    assert!(checked.status.success(), "{}", stderr(&checked));
    assert_eq!(stderr(&checked), "");

    std::fs::remove_file(&persisted).expect("the persisted file is removed");
    let checked = over_sources_with(
        &config,
        "generate",
        &[&arguments[..], &["--check"]].concat(),
    );
    assert_eq!(checked.status.code(), Some(1), "{}", stderr(&checked));
    let errors = stderr(&checked);
    assert!(
        errors.contains(&format!("{persisted_text}: missing")),
        "{errors}"
    );
    assert!(
        errors.contains("batonc: 1 outputs differ from what `generate` writes"),
        "{errors}"
    );
    assert_eq!(errors.lines().count(), 2, "{errors}");
    assert!(!persisted.exists(), "the check writes nothing");
}
