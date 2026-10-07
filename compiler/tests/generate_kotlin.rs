//! `batonc generate` for the Kotlin target, run in a directory of its own:
//! the language a run writes, the packages its files take, and what the
//! configuration owes the target.

use std::path::{Path, PathBuf};
use std::process::{Command, Output};

/// A directory under the system's temporary one, emptied for one test.
fn workspace(name: &str) -> PathBuf {
    let directory =
        std::env::temp_dir().join(format!("batonc-kotlin-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&directory);
    std::fs::create_dir_all(&directory).expect("the workspace is created");
    directory
}

fn write(directory: &Path, path: &str, text: &str) {
    let path = directory.join(path);
    std::fs::create_dir_all(path.parent().expect("a file has a parent"))
        .expect("the directory is created");
    std::fs::write(path, text).expect("the file is written");
}

/// A `baton.json` beside the test schema's path, with `extra` entries.
fn configuration(directory: &Path, extra: &str) {
    let schema = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../spec/tests/schema.graphql")
        .to_string_lossy()
        .into_owned();
    write(
        directory,
        "baton.json",
        &format!("{{\"schema\": {schema:?}{extra}}}"),
    );
}

fn generate(directory: &Path, arguments: &[&str]) -> Output {
    Command::new(env!("CARGO_BIN_EXE_batonc"))
        .current_dir(directory)
        .arg("generate")
        .args(["--config", "baton.json"])
        .args(arguments)
        .output()
        .expect("batonc runs")
}

fn stderr(output: &Output) -> String {
    String::from_utf8_lossy(&output.stderr).into_owned()
}

const PACKAGE: &str = ", \"kotlin\": {\"package\": \"app.generated\"}";

const SCREEN: &str = "package app.screens\n\nimport baton.Query\n\n@Query($$\"\"\"\n    query HomeQuery($id: ID!) {\n      character(id: $id) { id name }\n    }\n    \"\"\")\nfun Home() {}\n";

#[test]
fn a_kotlin_host_writes_kotlin_in_its_package_and_the_shared_file_in_the_configured_one() {
    let directory = workspace("packages");
    configuration(&directory, PACKAGE);
    write(&directory, "Home.kt", SCREEN);
    let output = generate(&directory, &["--out", "out", "Home.kt"]);
    assert!(output.status.success(), "{}", stderr(&output));
    let read =
        |name: &str| std::fs::read_to_string(directory.join("out").join(name)).unwrap_or_default();
    let home = read("Home.baton.kt");
    assert!(home.contains("\npackage app.screens\n"), "{home}");
    assert!(home.contains("\nimport app.generated.Types\n"));
    assert!(home.contains("class HomeQuery(val id: String) : QueryOperation<HomeQuery.Data>"));
    let shared = read("Baton.baton.kt");
    assert!(shared.contains("\npackage app.generated\n"));
    assert!(shared.contains("object Types {"));
}

#[test]
fn language_kotlin_writes_kotlin_for_a_graphql_source() {
    let directory = workspace("graphql");
    configuration(&directory, PACKAGE);
    write(
        &directory,
        "Home.graphql",
        "query HomeQuery { character(id: 1) { id } }\n",
    );
    let output = generate(
        &directory,
        &["--language", "kotlin", "--out", "out", "Home.graphql"],
    );
    assert!(output.status.success(), "{}", stderr(&output));
    let home = std::fs::read_to_string(directory.join("out/Home.graphql.baton.kt"))
        .expect("the source writes Kotlin");
    assert!(home.contains("\npackage app.generated\n"));
    assert!(!directory.join("out/Baton.baton.swift").exists());
}

#[test]
fn a_swift_host_after_a_kotlin_one_is_an_error_at_the_second_file() {
    let directory = workspace("mixed");
    configuration(&directory, PACKAGE);
    write(&directory, "Home.kt", SCREEN);
    write(
        &directory,
        "Row.swift",
        "@Fragment(\"fragment Row_character on Character { name }\")\nvar row: Row_character\n",
    );
    let output = generate(&directory, &["--out", "out", "Home.kt", "Row.swift"]);
    assert!(!output.status.success());
    assert!(
        stderr(&output).starts_with(
            "Row.swift:1:1: error: a Swift host in a run of Kotlin: the run writes Kotlin for `Home.kt`; run `batonc` once per language"
        ),
        "{}",
        stderr(&output)
    );
    assert!(!directory.join("out").exists());
}

#[test]
fn a_kotlin_host_in_a_run_of_swift_is_an_error_at_the_file() {
    let directory = workspace("swift-only");
    configuration(&directory, PACKAGE);
    write(&directory, "Home.kt", SCREEN);
    let output = generate(
        &directory,
        &["--language", "swift", "--out", "out", "Home.kt"],
    );
    assert!(!output.status.success());
    assert!(
        stderr(&output).starts_with(
            "Home.kt:1:1: error: a Kotlin host in a run of Swift: `--language` asks for Swift"
        ),
        "{}",
        stderr(&output)
    );
}

#[test]
fn the_shared_file_without_a_package_is_an_error_at_the_configuration() {
    let directory = workspace("no-package");
    configuration(&directory, "");
    write(&directory, "Home.kt", SCREEN);
    let output = generate(&directory, &["--out", "out", "Home.kt"]);
    assert!(!output.status.success());
    assert!(
        stderr(&output).starts_with(
            "baton.json:1:1: error: the Kotlin target's shared file needs a package: name it in `baton.json` as `\"kotlin\": {\"package\": …}`"
        ),
        "{}",
        stderr(&output)
    );
}

#[test]
fn a_mapped_scalar_without_a_kotlin_entry_is_an_error_at_the_configuration() {
    let directory = workspace("scalar");
    configuration(
        &directory,
        ", \"kotlin\": {\"package\": \"app.generated\"}, \"customScalarTypes\": {\"Decimal\": \"Foundation.Decimal\"}",
    );
    write(&directory, "Home.kt", SCREEN);
    let output = generate(&directory, &["--out", "out", "Home.kt"]);
    assert!(!output.status.success());
    assert!(
        stderr(&output).contains(
            "error: `customScalarTypes` maps `Decimal` to no Kotlin type: write it under `kotlin`"
        ),
        "{}",
        stderr(&output)
    );
}

#[test]
fn a_variable_named_like_what_its_class_declares_is_an_error_at_the_name_in_the_host() {
    let directory = workspace("clash");
    configuration(&directory, PACKAGE);
    write(
        &directory,
        "Home.kt",
        "package app.screens\n\n@Query($$\"\"\"\n    query HomeQuery($type: ID!) {\n      character(id: $type) { id }\n    }\n    \"\"\")\nfun Home() {}\n",
    );
    let output = generate(&directory, &["--out", "out", "Home.kt"]);
    assert!(!output.status.success());
    assert!(
        stderr(&output).starts_with(
            "Home.kt:4:21: error: the variable `$type` clashes with the operation's `type` in the generated Kotlin; rename the variable"
        ),
        "{}",
        stderr(&output)
    );
}
