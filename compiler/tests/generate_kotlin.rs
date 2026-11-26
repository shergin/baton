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

/// A Kotlin host in `package` whose one document is `document`.
fn host(package: &str, annotation: &str, document: &str) -> String {
    format!(
        "package {package}\n\nimport baton.{annotation}\n\n@{annotation}($$\"\"\"\n    {document}\n    \"\"\")\nfun host() {{}}\n"
    )
}

/// The configuration of the base target: its shared file in `app.base`.
const BASE_PACKAGE: &str = ", \"kotlin\": {\"package\": \"app.base\"}";

/// A workspace whose base target, `Status.kt` in the package `app.shared`
/// with its shared file in `app.base`, has written its fragments file to
/// `shared/fragments.json`. The configuration is then the dependent's,
/// whose shared file is in `app.generated`.
fn kotlin_base(name: &str) -> PathBuf {
    let directory = workspace(name);
    configuration(&directory, BASE_PACKAGE);
    write(
        &directory,
        "Status.kt",
        &host(
            "app.shared",
            "Fragment",
            "fragment CharacterStatus_character on Character { status }",
        ),
    );
    let output = generate(
        &directory,
        &[
            "--out",
            "shared",
            "--fragments",
            "shared/fragments.json",
            "Status.kt",
        ],
    );
    assert!(output.status.success(), "{}", stderr(&output));
    configuration(&directory, PACKAGE);
    directory
}

/// A Kotlin host in `app.screens` whose query spreads the base's fragment.
fn row() -> String {
    host(
        "app.screens",
        "Query",
        "query RowQuery { character(id: 1) { id ...CharacterStatus_character } }",
    )
}

#[test]
fn a_kotlin_base_s_fragments_file_carries_each_fragment_s_package() {
    let directory = kotlin_base("base-package");
    let text = std::fs::read_to_string(directory.join("shared/fragments.json"))
        .expect("the fragments file is written");
    let file: serde_json::Value = serde_json::from_str(&text).expect("the file is JSON");
    assert_eq!(file["fragments"][0]["name"], "CharacterStatus_character");
    assert_eq!(file["fragments"][0]["package"], "app.shared");
}

#[test]
fn a_kotlin_head_s_module_is_the_package_of_the_target_s_shared_file() {
    let directory = kotlin_base("base-head");
    let fragments: serde_json::Value = serde_json::from_str(
        &std::fs::read_to_string(directory.join("shared/fragments.json"))
            .expect("the fragments file is written"),
    )
    .expect("the fragments file is JSON");
    assert_eq!(fragments["module"], "app.base");
    configuration(&directory, BASE_PACKAGE);
    let output = generate(
        &directory,
        &[
            "--out",
            "again",
            "--report",
            "again/report.json",
            "Status.kt",
        ],
    );
    assert!(output.status.success(), "{}", stderr(&output));
    let report: serde_json::Value = serde_json::from_str(
        &std::fs::read_to_string(directory.join("again/report.json"))
            .expect("the report is written"),
    )
    .expect("the report is JSON");
    assert_eq!(report["module"], "app.base");
}

#[test]
fn module_on_a_kotlin_run_is_a_usage_error_naming_the_configuration_s_package() {
    let directory = workspace("module-option");
    configuration(&directory, PACKAGE);
    write(&directory, "Home.kt", SCREEN);
    let output = generate(
        &directory,
        &[
            "--out",
            "out",
            "--module",
            "Screens",
            "--fragments",
            "out/fragments.json",
            "Home.kt",
        ],
    );
    assert!(!output.status.success());
    assert!(
        stderr(&output).starts_with(
            "batonc: `--module` names a Swift module; a Kotlin target's is the `kotlin.package` of its configuration"
        ),
        "{}",
        stderr(&output)
    );
    assert!(!directory.join("out").exists());
}

#[test]
fn a_kotlin_base_whose_shared_file_is_in_the_target_s_package_is_an_error_at_the_configuration() {
    let directory = kotlin_base("base-clash");
    configuration(&directory, BASE_PACKAGE);
    write(&directory, "Row.kt", &row());
    let output = generate(
        &directory,
        &[
            "--out",
            "screens",
            "--base",
            "shared/fragments.json",
            "Row.kt",
        ],
    );
    assert!(!output.status.success());
    assert!(
        stderr(&output).starts_with(
            "baton.json:1:1: error: the base `shared/fragments.json` declares its shared file in the Kotlin package `app.base`, and so does this target: an app cannot hold both, so name another `kotlin.package` for one of them"
        ),
        "{}",
        stderr(&output)
    );
    assert!(!directory.join("screens").exists());
}

#[test]
fn a_kotlin_report_s_fragment_carries_its_package() {
    let directory = kotlin_base("base-report");
    configuration(&directory, BASE_PACKAGE);
    let output = generate(
        &directory,
        &[
            "--out",
            "again",
            "--report",
            "again/report.json",
            "Status.kt",
        ],
    );
    assert!(output.status.success(), "{}", stderr(&output));
    let report: serde_json::Value = serde_json::from_str(
        &std::fs::read_to_string(directory.join("again/report.json"))
            .expect("the report is written"),
    )
    .expect("the report is JSON");
    assert_eq!(report["fragments"][0]["package"], "app.shared");
}

/// The base's lens is in `app.shared`, its host's package, and its shared
/// file in `app.base`; the dependent's shared file is in `app.generated`,
/// and one of its hosts is in `app.shared` too: two targets' hosts may
/// share a package when their shared files do not.
#[test]
fn a_file_that_names_a_base_lens_of_another_package_imports_it_and_one_in_its_package_does_not() {
    let directory = kotlin_base("base-imports");
    write(&directory, "Row.kt", &row());
    write(
        &directory,
        "Same.kt",
        &host(
            "app.shared",
            "Query",
            "query SameQuery { character(id: 1) { id ...CharacterStatus_character } }",
        ),
    );
    let output = generate(
        &directory,
        &[
            "--out",
            "screens",
            "--base",
            "shared/fragments.json",
            "Row.kt",
            "Same.kt",
        ],
    );
    assert!(output.status.success(), "{}", stderr(&output));
    let read = |name: &str| {
        std::fs::read_to_string(directory.join("screens").join(name)).unwrap_or_default()
    };
    let row = read("Row.baton.kt");
    assert!(
        row.contains("\nimport app.shared.CharacterStatus_character\n"),
        "{row}"
    );
    assert!(row.contains("CharacterStatus_character"), "{row}");
    let same = read("Same.baton.kt");
    assert!(same.contains("\npackage app.shared\n"), "{same}");
    assert!(same.contains("CharacterStatus_character"), "{same}");
    assert!(!same.contains("import app.shared."), "{same}");
    assert!(
        !row.contains("class CharacterStatus_character")
            && !same.contains("class CharacterStatus_character"),
        "the dependent declares no lens of the base's"
    );
}
