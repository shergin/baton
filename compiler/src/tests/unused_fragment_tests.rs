//! Tests of the warning for a fragment no operation reaches: one warning at
//! the name of each such fragment, none for a fragment an operation spreads
//! directly, through another fragment or as its refetch query, and none for
//! a fragment of a base, whose own target is the one to warn it.

use std::path::{Path, PathBuf};

use crate::config::Config;
use crate::documents::Document;
use crate::documents::Position;
use crate::pipeline::compile;

use super::*;
use support::one_file;

/// The test schema's text and path.
fn schema() -> (String, String) {
    let path = Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("the compiler sits one level below the repository root")
        .join("spec/tests/schema.graphql");
    (
        std::fs::read_to_string(&path).expect("the test schema is readable"),
        path.to_string_lossy().into_owned(),
    )
}

/// The documents of `texts`, each a host path, the position of its first
/// character in the host file, and its text.
fn documents(texts: &[(&str, Position, &str)]) -> Vec<Document> {
    texts
        .iter()
        .enumerate()
        .map(|(index, (path, start, text))| Document {
            path: PathBuf::from(path),
            index,
            start: *start,
            text: text.to_string(),
            embedded: None,
        })
        .collect()
}

/// The configuration the tests compile under: none, at `baton.json`.
fn config() -> Config {
    let mut config: Config = serde_json::from_str("{}").expect("the configuration parses");
    config.path = PathBuf::from("baton.json");
    config
}

/// The warnings for unused fragments among `texts`, compiled without
/// configuration.
fn warnings(texts: &[(&str, Position, &str)]) -> Vec<Rendered> {
    warnings_with_bases(texts, &[])
}

/// The warnings for unused fragments among `texts`, spreading the fragments
/// of `bases`.
fn warnings_with_bases(texts: &[(&str, Position, &str)], bases: &[base::Base]) -> Vec<Rendered> {
    let (sdl, path) = schema();
    let documents = documents(texts);
    let plan =
        crate::pipeline::compile_with_bases(&one_file(&sdl, &path), &documents, &config(), bases)
            .unwrap_or_else(|errors| panic!("{errors:?}"))
            .plan;
    unused_fragments(&documents, &plan)
}

/// The base whose fragments file a build writes for the target `texts`, in
/// the module `Shared`.
fn shared_base(texts: &[(&str, Position, &str)]) -> base::Base {
    let (sdl, path) = schema();
    let plan = compile(&one_file(&sdl, &path), &documents(texts), &config())
        .unwrap_or_else(|errors| panic!("{errors:?}"))
        .plan;
    let home = report::Home {
        module: Some("Shared".to_string()),
        ..report::Home::default()
    };
    let text = report::fragments_text(&plan, Path::new("/nowhere"), &home);
    base::Base::parse("shared.json", &text).unwrap_or_else(|error| panic!("{error}"))
}

const START: Position = Position { line: 1, column: 1 };

const QUERY: &str = "query Screen { character(id: \"1\") { id ...Row_character } }";
const ROW: &str = "fragment Row_character on Character { name }";

fn message(name: &str) -> String {
    format!(
        "fragment `{name}` is spread by no operation of this target; nothing in it reads the fragment"
    )
}

#[test]
fn an_unspread_fragment_is_warned_at_its_name_in_the_host_file() {
    // The text starts at line 7, column 9 of the host file; the name follows
    // `fragment `, nine characters in, so it stands at column 18.
    let warnings = warnings(&[
        ("Screen.swift", START, QUERY),
        ("Screen.swift", START, ROW),
        (
            "Lonely.swift",
            Position { line: 7, column: 9 },
            "fragment Lonely_character on Character {\n  name\n}",
        ),
    ]);
    assert_eq!(warnings.len(), 1, "{warnings:?}");
    let warning = &warnings[0];
    assert_eq!(warning.severity, "warning");
    assert_eq!(warning.path, "Lonely.swift");
    assert_eq!((warning.line, warning.column), (7, 18));
    assert_eq!(warning.message, message("Lonely_character"));
    assert!(warning.notes.is_empty());
}

#[test]
fn an_unspread_fragment_below_the_first_line_is_warned_at_its_line_and_column() {
    // The fragment's definition starts the third line of the text, so its
    // name stands at column 10 of the host file's third line.
    let warnings = warnings(&[(
        "Screen.graphql",
        START,
        "query Screen { character(id: \"1\") { id } }\n\nfragment Lonely_character on Character { name }\n",
    )]);
    assert_eq!(warnings.len(), 1, "{warnings:?}");
    assert_eq!(warnings[0].path, "Screen.graphql");
    assert_eq!((warnings[0].line, warnings[0].column), (3, 10));
}

#[test]
fn a_fragment_an_operation_spreads_is_not_warned() {
    let warnings = warnings(&[("Screen.swift", START, QUERY), ("Screen.swift", START, ROW)]);
    assert!(warnings.is_empty(), "{warnings:?}");
}

#[test]
fn a_fragment_spread_only_by_an_unspread_fragment_is_warned_with_it() {
    let warnings = warnings(&[
        ("Screen.swift", START, QUERY),
        ("Screen.swift", START, ROW),
        (
            "Chain.swift",
            START,
            "fragment Outer_character on Character { ...Inner_character }",
        ),
        (
            "Chain.swift",
            START,
            "fragment Inner_character on Character { name }",
        ),
    ]);
    let mut messages: Vec<&str> = warnings
        .iter()
        .map(|warning| warning.message.as_str())
        .collect();
    messages.sort();
    assert_eq!(
        messages,
        [message("Inner_character"), message("Outer_character")]
    );
    assert!(warnings.iter().all(|warning| warning.severity == "warning"));
}

#[test]
fn a_fragment_spread_through_another_fragment_is_not_warned() {
    let warnings = warnings(&[
        (
            "Chain.swift",
            START,
            "query Chain { character(id: \"1\") { id ...Outer_character } }",
        ),
        (
            "Chain.swift",
            START,
            "fragment Outer_character on Character { ...Inner_character }",
        ),
        (
            "Chain.swift",
            START,
            "fragment Inner_character on Character { name }",
        ),
    ]);
    assert!(warnings.is_empty(), "{warnings:?}");
}

#[test]
fn a_refetchable_fragment_nothing_else_spreads_is_reached_by_its_refetch_query() {
    let warnings = warnings(&[(
        "Refetch.swift",
        START,
        "fragment Refetch_character on Character @refetchable(queryName: \"RefetchCharacterQuery\") { name }",
    )]);
    assert!(warnings.is_empty(), "{warnings:?}");
}

#[test]
fn a_base_fragment_the_target_reaches_only_through_an_unspread_fragment_is_not_warned() {
    let shared = shared_base(&[(
        "Shared.graphql",
        START,
        "fragment Status_character on Character { status }",
    )]);
    let warnings = warnings_with_bases(
        &[
            ("Screen.swift", START, QUERY),
            ("Screen.swift", START, ROW),
            (
                "Chain.swift",
                START,
                "fragment Outer_character on Character { ...Status_character }",
            ),
        ],
        &[shared],
    );
    let messages: Vec<&str> = warnings
        .iter()
        .map(|warning| warning.message.as_str())
        .collect();
    assert_eq!(messages, [message("Outer_character")]);
}

#[test]
fn a_base_fragment_an_operation_reaches_through_a_fragment_is_not_warned() {
    let shared = shared_base(&[(
        "Shared.graphql",
        START,
        "fragment Status_character on Character { status }",
    )]);
    let warnings = warnings_with_bases(
        &[
            ("Screen.swift", START, QUERY),
            (
                "Screen.swift",
                START,
                "fragment Row_character on Character { name ...Status_character }",
            ),
        ],
        &[shared],
    );
    assert!(warnings.is_empty(), "{warnings:?}");
}

#[path = "support.rs"]
#[allow(
    clippy::duplicate_mod,
    reason = "no test module is the whole crate's, so each that needs the helpers includes them"
)]
mod support;
