//! `batonc generate` run as the build runs it, in a directory of its own.

use std::path::{Path, PathBuf};
use std::process::{Command, Output};

/// A directory under the system's temporary one, emptied for one test.
fn workspace(name: &str) -> PathBuf {
    let directory = std::env::temp_dir().join(format!("batonc-{name}-{}", std::process::id()));
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

fn schema() -> String {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../spec/tests/schema.graphql")
        .to_string_lossy()
        .into_owned()
}

fn generate(directory: &Path, arguments: &[&str]) -> Output {
    Command::new(env!("CARGO_BIN_EXE_batonc"))
        .current_dir(directory)
        .arg("generate")
        .args(["--schema", &schema()])
        .args(arguments)
        .output()
        .expect("batonc runs")
}

const QUERY: &str = "@Query(\"query HomeQuery($id: ID!) { character(id: $id) { id name } }\")\nvar home: HomeQuery\n";
const FRAGMENT: &str =
    "@Fragment(\"fragment HomeRow_character on Character { name }\")\nvar row: HomeRow_character\n";

#[test]
fn every_source_writes_an_output_named_by_its_path_a_graphql_file_among_them() {
    let directory = workspace("names");
    write(&directory, "Screens/Home.swift", QUERY);
    write(&directory, "Home.swift", FRAGMENT);
    write(
        &directory,
        "Home.graphql",
        "query HomeAgainQuery { character(id: 1) { id } }\n",
    );
    let output = generate(
        &directory,
        &[
            "--out",
            "out",
            "Screens/Home.swift",
            "Home.swift",
            "Home.graphql",
        ],
    );
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let read =
        |name: &str| std::fs::read_to_string(directory.join("out").join(name)).unwrap_or_default();
    assert!(read("Screens_Home.baton.swift").contains("struct HomeQuery"));
    assert!(read("Home.baton.swift").contains("struct HomeRow_character"));
    assert!(read("Home.graphql.baton.swift").contains("struct HomeAgainQuery"));
    assert!(read("Baton.baton.swift").contains("enum Types"));
}

#[test]
fn a_document_with_an_error_writes_nothing() {
    let directory = workspace("error");
    write(&directory, "Home.swift", QUERY);
    write(
        &directory,
        "Broken.swift",
        "@Fragment(\"fragment Broken_character on Character { nope }\")\nvar broken: Broken_character\n",
    );
    let output = generate(&directory, &["--out", "out", "Home.swift", "Broken.swift"]);
    assert!(!output.status.success());
    assert!(String::from_utf8_lossy(&output.stderr).contains("Broken.swift:1:"));
    assert!(!directory.join("out").exists(), "an output was written");
}

#[test]
fn a_file_with_graphql_and_no_output_is_an_error() {
    let directory = workspace("untargeted");
    write(&directory, "Home.swift", QUERY);
    write(&directory, "Row.swift", FRAGMENT);
    let output = generate(
        &directory,
        &[
            "--emit",
            "Home.swift=out/Home.baton.swift",
            "--shared",
            "out/Baton.baton.swift",
            "Home.swift",
            "Row.swift",
        ],
    );
    assert!(!output.status.success());
    assert!(
        String::from_utf8_lossy(&output.stderr)
            .contains("`Row.swift` holds GraphQL but no `--emit` names an output for it")
    );
}

#[test]
fn two_sources_that_would_write_one_output_are_an_error() {
    let directory = workspace("collision");
    write(&directory, "Screens/Home.swift", QUERY);
    write(&directory, "Screens_Home.swift", FRAGMENT);
    let output = generate(
        &directory,
        &["--out", "out", "Screens/Home.swift", "Screens_Home.swift"],
    );
    assert!(!output.status.success());
    assert!(String::from_utf8_lossy(&output.stderr).contains("would both write"));
}

#[test]
fn a_source_that_would_write_the_shared_file_is_an_error() {
    let directory = workspace("shared");
    write(&directory, "Baton.swift", QUERY);
    let named = generate(&directory, &["--out", "out", "Baton.swift"]);
    assert!(!named.status.success());
    let stderr = String::from_utf8_lossy(&named.stderr);
    assert!(
        stderr.contains("`Baton.swift` would write the shared `out/Baton.baton.swift`; rename it"),
        "{stderr}"
    );
    assert!(!directory.join("out").exists());

    let declared = generate(
        &directory,
        &[
            "--emit",
            "Baton.swift=out/Baton.baton.swift",
            "--shared",
            "out/Baton.baton.swift",
            "Baton.swift",
        ],
    );
    assert!(!declared.status.success());
    assert!(String::from_utf8_lossy(&declared.stderr).contains("would write the shared"));
    assert!(!directory.join("out").exists());
}

#[test]
fn an_option_the_command_does_not_take_is_an_error() {
    let directory = workspace("options");
    write(&directory, "Home.swift", QUERY);
    let output = generate(&directory, &["--schem", "x", "--out", "out", "Home.swift"]);
    assert!(!output.status.success());
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        stderr.contains("`--schem` is not an option of `generate`, which takes `--schema`"),
        "{stderr}"
    );
    assert!(!directory.join("out").exists());

    let scan = Command::new(env!("CARGO_BIN_EXE_batonc"))
        .current_dir(&directory)
        .args(["scan", "--out", "out", "Home.swift"])
        .output()
        .expect("batonc runs");
    assert!(!scan.status.success());
    assert!(String::from_utf8_lossy(&scan.stderr).contains("which takes no options"));
}

#[test]
fn the_property_check_finds_each_document_by_where_it_came_from() {
    let directory = workspace("property");
    write(
        &directory,
        "Home.swift",
        "@Query(\"query Home($id: ID!) { character(id: $id) { ...HomeDetail_character } }\")\nvar home: Home\n",
    );
    write(
        &directory,
        "Detail.swift",
        "@Fragment(\"fragment HomeDetail_character on Character { name }\")\nvar character: HomeDetail_character\n@Query(\"query HomeDetail { character(id: 1) { id } }\")\nvar detail: HomeDetail\n@Subscription(\"subscription NoteAdded { noteAdded(characterId: 1) { noteEdge { cursor } } }\")\nvar added: NoteAdded.Action\n",
    );
    let output = generate(&directory, &["--out", "out", "Home.swift", "Detail.swift"]);
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let warnings: Vec<String> = String::from_utf8_lossy(&output.stderr)
        .lines()
        .filter(|line| line.contains("warning"))
        .map(str::to_string)
        .collect();
    assert_eq!(warnings.len(), 1, "{warnings:?}");
    assert!(
        warnings[0].contains("@Subscription declares `NoteAdded` but the property `added` is typed `NoteAdded.Action`"),
        "{warnings:?}"
    );
}
