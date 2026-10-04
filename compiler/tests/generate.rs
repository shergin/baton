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
    generate_against(directory, &schema(), arguments)
}

/// `batonc generate` against the schema at `schema`.
fn generate_against(directory: &Path, schema: &str, arguments: &[&str]) -> Output {
    Command::new(env!("CARGO_BIN_EXE_batonc"))
        .current_dir(directory)
        .arg("generate")
        .args(["--schema", schema])
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

#[test]
fn a_name_the_document_chose_that_the_generated_code_needs_is_an_error_at_the_name() {
    let directory = workspace("clashes");
    write(
        &directory,
        "Probe.swift",
        r##"@Query("query Probe($variables: ID!, $resolution: ID!) { character(id: $variables) { id } node(id: $resolution) { id } }")
var probe: Probe
@Mutation("mutation Rename($id: ID!) { variable: setFavorite(id: $id, favorite: true) { character { id } } }")
var rename: Rename.Action
@Fragment(#"fragment Probe_notes on Character { notes(first: 2) @connection(key: "Probe_notes") { hasNext: totalCount connectionID: totalCount edges { node { id } } } }"#)
var notes: Probe_notes
@Fragment("fragment Types on Character { name }")
var types: Types
@Fragment("fragment Slots on Character { name }")
var slots: Slots
@Fragment("fragment Baton on Character { name }")
var baton: Baton
"##,
    );
    let output = generate(&directory, &["--out", "out", "Probe.swift"]);
    assert!(!output.status.success());
    let stderr = String::from_utf8_lossy(&output.stderr);
    let mut lines: Vec<&str> = stderr.lines().collect();
    lines.sort();
    assert_eq!(
        lines,
        [
            "Probe.swift:11:21: error: the fragment `Baton` clashes with the runtime's module `Baton` in the generated Swift; rename the fragment",
            "Probe.swift:1:21: error: the variable `$variables` clashes with the operation's `variables` in the generated Swift; rename the variable",
            "Probe.swift:1:38: error: the variable `$resolution` clashes with the operation's `resolution` in the generated Swift; rename the variable",
            "Probe.swift:3:40: error: the field `variable` clashes with the optimistic response's `variable` in the generated Swift; choose another alias",
            "Probe.swift:5:119: error: the field `connectionID` clashes with the connection's `connectionID` in the generated Swift; choose another alias",
            "Probe.swift:5:99: error: the field `hasNext` clashes with the connection's `hasNext` in the generated Swift; choose another alias",
            "Probe.swift:7:21: error: the fragment `Types` clashes with the shared enum `Types` in the generated Swift; rename the fragment",
            "Probe.swift:9:21: error: the fragment `Slots` clashes with the shared enum `Slots` in the generated Swift; rename the fragment",
        ]
    );
    assert!(!directory.join("out").exists(), "an output was written");
}

#[test]
fn a_refetch_query_named_like_a_shared_enum_is_an_error_at_its_fragment() {
    let directory = workspace("refetch-clash");
    write(
        &directory,
        "Refetch.swift",
        r##"@Fragment(#"fragment Refetch_character on Character @refetchable(queryName: "Slots") { name }"#)
var refetch: Refetch_character
"##,
    );
    let output = generate(&directory, &["--out", "out", "Refetch.swift"]);
    assert!(!output.status.success());
    assert_eq!(
        String::from_utf8_lossy(&output.stderr).trim_end(),
        "Refetch.swift:1:22: error: the refetch query `Slots` clashes with the shared enum `Slots` in the generated Swift; name it otherwise in `@refetchable(queryName:)`"
    );
}

#[test]
fn a_fragment_or_operation_named_like_what_the_generated_code_spells_from_swift_is_an_error() {
    let directory = workspace("standard-library");
    write(
        &directory,
        "Names.swift",
        r##"@Fragment("fragment Swift on Character { name }")
var swift: Swift
@Fragment("fragment String on Character { name }")
var string: String
@Query("query Hasher { character(id: 1) { id } }")
var hasher: Hasher
@Mutation("mutation Sendable($id: ID!) { setFavorite(id: $id, favorite: true) { character { id } } }")
var sendable: Sendable.Action
@Fragment("fragment Self on Character { name }")
var this: Self
@Fragment("fragment Any on Character { name }")
var any: Any
"##,
    );
    let output = generate(&directory, &["--out", "out", "Names.swift"]);
    assert!(!output.status.success());
    let stderr = String::from_utf8_lossy(&output.stderr);
    let mut lines: Vec<&str> = stderr.lines().collect();
    lines.sort();
    assert_eq!(
        lines,
        [
            "Names.swift:11:21: error: the fragment `Any` clashes with Swift's keyword `Any` in the generated Swift; rename the fragment",
            "Names.swift:1:21: error: the fragment `Swift` clashes with the standard library's module `Swift` in the generated Swift; rename the fragment",
            "Names.swift:3:21: error: the fragment `String` clashes with the standard library's `String` in the generated Swift; rename the fragment",
            "Names.swift:5:15: error: the query `Hasher` clashes with the standard library's `Hasher` in the generated Swift; rename the query",
            "Names.swift:7:21: error: the mutation `Sendable` clashes with the standard library's `Sendable` in the generated Swift; rename the mutation",
            "Names.swift:9:21: error: the fragment `Self` clashes with Swift's keyword `Self` in the generated Swift; rename the fragment",
        ]
    );
    assert!(!directory.join("out").exists(), "an output was written");
}

#[test]
fn a_field_named_like_a_shared_enum_its_lens_spells_is_an_error_at_the_name() {
    let directory = workspace("shared-enums");
    // `Types` is spelled two lenses down, where a resident's required
    // origin names its type, and the field hides it there too.
    write(
        &directory,
        "Fields.swift",
        r##"@Query("query Fields($id: ID!) { character(id: $id) { Slots: name Types: id origin { residents { origin @required(action: NONE) { name } } } } node(id: $id) { AbstractSlots: id } }")
var fields: Fields
"##,
    );
    let output = generate(&directory, &["--out", "out", "Fields.swift"]);
    assert!(!output.status.success());
    let stderr = String::from_utf8_lossy(&output.stderr);
    let mut lines: Vec<&str> = stderr.lines().collect();
    lines.sort();
    assert_eq!(
        lines,
        [
            "Fields.swift:1:160: error: the field `AbstractSlots` clashes with the shared enum `AbstractSlots` in the generated Swift; choose another alias",
            "Fields.swift:1:55: error: the field `Slots` clashes with the shared enum `Slots` in the generated Swift; choose another alias",
            "Fields.swift:1:67: error: the field `Types` clashes with the shared enum `Types` in the generated Swift; choose another alias",
        ]
    );
    assert!(!directory.join("out").exists(), "an output was written");

    // A lens that spells neither enum leaves the names to the document.
    write(
        &directory,
        "Fields.swift",
        "@Query(\"query Fields { character(id: 1) { Sites: name Types: status } }\")\nvar fields: Fields\n",
    );
    let output = generate(&directory, &["--out", "out", "Fields.swift"]);
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
}

#[test]
fn a_variable_named_like_what_its_operation_spells_is_an_error_at_the_name() {
    let directory = workspace("variables");
    // `$Sites` is free: no lens of the query binds a spread's arguments.
    write(
        &directory,
        "Variables.swift",
        r##"@Query("query Probe($Baton: ID!, $Types: ID!, $Slots: ID!, $AbstractSlots: ID!, $Sites: String!) { character(id: $Baton) { id } location(id: $Types) { id } episode(id: $Slots) { id } node(id: $AbstractSlots) { id } search(name: $Sites) { __typename } }")
var probe: Probe
@Mutation("mutation Favorite($id: ID!, $optimistic: Boolean!) { setFavorite(id: $id, favorite: $optimistic) { character { id } } }")
var favorite: Favorite.Action
"##,
    );
    let output = generate(&directory, &["--out", "out", "Variables.swift"]);
    assert!(!output.status.success());
    let stderr = String::from_utf8_lossy(&output.stderr);
    let mut lines: Vec<&str> = stderr.lines().collect();
    lines.sort();
    assert_eq!(
        lines,
        [
            "Variables.swift:1:21: error: the variable `$Baton` clashes with the runtime's module `Baton` in the generated Swift; rename the variable",
            "Variables.swift:1:34: error: the variable `$Types` clashes with the shared enum `Types` in the generated Swift; rename the variable",
            "Variables.swift:1:47: error: the variable `$Slots` clashes with the shared enum `Slots` in the generated Swift; rename the variable",
            "Variables.swift:1:60: error: the variable `$AbstractSlots` clashes with the shared enum `AbstractSlots` in the generated Swift; rename the variable",
            "Variables.swift:3:40: error: the variable `$optimistic` clashes with the action's parameter `optimistic` in the generated Swift; rename the variable",
        ]
    );
    assert!(!directory.join("out").exists(), "an output was written");
}

#[test]
fn a_selection_named_like_a_member_every_lens_has_is_an_error_asking_for_what_its_spelling_takes() {
    let directory = workspace("lens-members");
    write(
        &directory,
        "schema.graphql",
        "type Query { place(id: ID!): Place, node(id: ID!): Node }\ninterface Node { id: ID! }\ntype Place implements Node { id: ID! name: String anchor: Place recordID: ID }\n",
    );
    write(
        &directory,
        "Members.swift",
        r##"@Query(#"query Members($id: ID!) { place(id: $id) { anchor { name } recordID } node(id: $id) { anchor: id ... on Place @alias(as: "recordID") { name } } }"#)
var members: Members
@Fragment("fragment Members_place on Place { name recordID: name }")
var place: Members_place
"##,
    );
    let output = generate_against(
        &directory,
        "schema.graphql",
        &["--out", "out", "Members.swift"],
    );
    assert!(!output.status.success());
    let stderr = String::from_utf8_lossy(&output.stderr);
    let mut lines: Vec<&str> = stderr.lines().collect();
    lines.sort();
    assert_eq!(
        lines,
        [
            "Members.swift:1:131: error: the selection aliased `recordID` clashes with the `recordID` every lens has in the generated Swift; choose another alias",
            "Members.swift:1:53: error: the field `anchor` clashes with the `anchor` every lens has in the generated Swift; alias the field",
            "Members.swift:1:69: error: the field `recordID` clashes with the `recordID` every lens has in the generated Swift; alias the field",
            "Members.swift:1:96: error: the field `anchor` clashes with the `anchor` every lens has in the generated Swift; choose another alias",
            "Members.swift:3:51: error: the field `recordID` clashes with the `recordID` every lens has in the generated Swift; choose another alias",
        ]
    );
    assert!(!directory.join("out").exists(), "an output was written");
}
