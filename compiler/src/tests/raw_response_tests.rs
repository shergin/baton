//! Tests of Relay's `@raw_response_type`: a query or a subscription that
//! asks for its raw response nests the builder a mutation nests for its
//! optimistic response, named `RawResponse`, in either language; a mutation
//! that asks has what it had; the server is never sent the directive; and
//! the builder's names meet the document's as the optimistic response's do.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use crate::config::{Config, KotlinConfig, Language};
use crate::documents::Document;
use crate::kotlin_names::KotlinNaming;
use crate::names::SwiftNaming;
use crate::naming::{LanguageNaming, NameError};
use crate::pipeline::{self, Plan, SchemaFile, SchemaSources};

/// The test schema, one file.
fn test_schema() -> SchemaSources {
    let path = Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("the compiler sits one level below the repository root")
        .join("spec/tests/schema.graphql");
    let text = std::fs::read_to_string(&path).expect("the test schema is readable");
    SchemaSources {
        schema: vec![SchemaFile::new(text, path.to_string_lossy())],
        extensions: Vec::new(),
    }
}

/// A schema of root fields named like the builders, each of a type of one
/// field.
fn namesake_schema() -> SchemaSources {
    let text = "type Query {\n  rawResponse: Item\n  RawResponse: Item\n}\n\ntype Mutation {\n  optimisticResponse: Item\n  OptimisticResponse: Item\n}\n\ntype Subscription {\n  rawResponse: Item\n}\n\ntype Item {\n  id: ID\n}\n";
    SchemaSources {
        schema: vec![SchemaFile::new(text, "namesakes.graphql")],
        extensions: Vec::new(),
    }
}

fn swift_config() -> Config {
    Config {
        path: PathBuf::from("baton.json"),
        ..Config::default()
    }
}

fn kotlin_config() -> Config {
    Config {
        path: PathBuf::from("baton.json"),
        language: Language::Kotlin,
        kotlin: Some(KotlinConfig {
            package: Some("app.generated".to_string()),
        }),
        ..Config::default()
    }
}

/// The plan of `text` against `sources` under `config`.
fn compiled(sources: &SchemaSources, text: &str, config: &Config) -> Plan {
    let document = Document {
        path: PathBuf::from("Probe.graphql"),
        index: 0,
        start: crate::documents::Position { line: 1, column: 1 },
        text: text.to_string(),
        embedded: None,
    };
    pipeline::compile(sources, &[document], config)
        .unwrap_or_else(|errors| panic!("`{text}` does not compile: {errors:?}"))
        .plan
}

/// The Swift `text` is written as, the operation's file alone.
fn swift_of(sources: &SchemaSources, text: &str) -> String {
    let config = swift_config();
    let output = crate::emit::swift(&compiled(sources, text, &config), &config)
        .unwrap_or_else(|errors| panic!("`{text}` declares names twice: {errors:?}"));
    output.files.into_values().collect()
}

/// The Kotlin `text` is written as, the operation's file alone.
fn kotlin_of(sources: &SchemaSources, text: &str) -> String {
    let config = kotlin_config();
    let output =
        crate::emit::kotlin::kotlin(&compiled(sources, text, &config), &config, BTreeMap::new())
            .unwrap_or_else(|errors| panic!("`{text}` declares names twice: {errors:?}"));
    output.files.into_values().collect()
}

/// The names `text` would declare twice in `naming`'s generated code.
fn clashes(sources: &SchemaSources, text: &str, naming: &LanguageNaming) -> Vec<String> {
    match crate::decide::program(&compiled(sources, text, &swift_config()), naming) {
        Ok(_) => Vec::new(),
        Err(errors) => errors
            .iter()
            .map(|error| match error {
                NameError::Clash(clash) => clash.to_string(),
                NameError::Duplicate(duplicate) => duplicate.to_string(),
            })
            .collect(),
    }
}

fn namings() -> [(&'static str, LanguageNaming); 2] {
    [
        ("Swift", SwiftNaming::default().into()),
        ("Kotlin", KotlinNaming::default().into()),
    ]
}

/// What the Swift doc comment of a raw-response builder says.
const RAW_SUMMARY: &str = "A response to the operation, written by hand: what `commitPayload` takes, or a transport of the app's own yields; absent fields leave the store untouched.";

/// What the doc comment of an optimistic-response builder says.
const OPTIMISTIC_SUMMARY: &str = "A partial response to show before the server answers; absent fields leave the store untouched.";

const QUERY: &str = "query Probe($id: ID!) @raw_response_type { character(id: $id) { id name origin { id name } } }";
const SUBSCRIPTION: &str = "subscription Probe($id: ID!) @raw_response_type { noteAdded(characterId: $id) { noteEdge { cursor node { id text } } } }";
const MUTATION: &str = "mutation Probe($id: ID!) @raw_response_type { rename(id: $id, name: \"a\") { character { id name } } }";

/// `text` without its `@raw_response_type`.
fn plain(text: &str) -> String {
    text.replace(" @raw_response_type", "")
}

#[test]
fn a_query_or_a_subscription_with_raw_response_type_nests_a_raw_response_in_swift_and_in_kotlin() {
    let schema = test_schema();
    for text in [QUERY, SUBSCRIPTION] {
        let swift = swift_of(&schema, text);
        assert!(
            swift.contains("    nonisolated public struct RawResponse: Sendable {"),
            "{swift}"
        );
        assert!(
            swift.contains(&format!("    /// {RAW_SUMMARY}\n")),
            "{swift}"
        );
        assert!(
            swift.contains("        public var payload: Baton.Payload { .init(data: variable) }"),
            "{swift}"
        );
        assert!(!swift.contains(OPTIMISTIC_SUMMARY), "{swift}");
        assert!(
            !swift.contains("typealias Action"),
            "only a mutation has an action: {swift}"
        );

        let kotlin = kotlin_of(&schema, text);
        assert!(
            kotlin.contains(&format!("/** {RAW_SUMMARY} */")),
            "{kotlin}"
        );
        assert!(kotlin.contains("class RawResponse("), "{kotlin}");
        assert!(
            kotlin.contains("val payload: Payload get() = Payload(data = variable)"),
            "{kotlin}"
        );
        assert!(!kotlin.contains("OptimisticResponse"), "{kotlin}");
    }
}

#[test]
fn a_query_or_a_subscription_without_raw_response_type_nests_no_builder() {
    let schema = test_schema();
    for text in [QUERY, SUBSCRIPTION] {
        let text = plain(text);
        let swift = swift_of(&schema, &text);
        assert!(!swift.contains("RawResponse"), "{swift}");
        assert!(!swift.contains("payload"), "{swift}");
        let kotlin = kotlin_of(&schema, &text);
        assert!(!kotlin.contains("RawResponse"), "{kotlin}");
        assert!(!kotlin.contains("payload"), "{kotlin}");
    }
}

#[test]
fn a_mutation_with_raw_response_type_emits_exactly_what_it_emits_without_it() {
    let schema = test_schema();
    let swift = swift_of(&schema, MUTATION);
    assert_eq!(swift, swift_of(&schema, &plain(MUTATION)));
    assert!(swift.contains("public typealias Action"), "{swift}");
    assert!(
        swift.contains("    nonisolated public struct OptimisticResponse: Sendable {"),
        "{swift}"
    );
    assert!(!swift.contains("RawResponse"), "{swift}");
    let kotlin = kotlin_of(&schema, MUTATION);
    assert_eq!(kotlin, kotlin_of(&schema, &plain(MUTATION)));
    assert!(!kotlin.contains("RawResponse"), "{kotlin}");
}

#[test]
fn the_text_sent_and_its_persisted_id_leave_raw_response_type_out() {
    let schema = test_schema();
    let mut config: Config =
        serde_json::from_str(r#"{"persistConfig": {"file": "persisted.json"}}"#)
            .expect("the configuration parses");
    config.path = PathBuf::from("baton.json");
    for text in [QUERY, SUBSCRIPTION, MUTATION] {
        let asked = compiled(&schema, text, &swift_config());
        let sent = &asked.operations[0].text;
        assert!(!sent.contains("raw_response_type"), "{sent}");
        assert_eq!(
            sent,
            &compiled(&schema, &plain(text), &swift_config()).operations[0].text
        );
        let persisted = compiled(&schema, text, &config);
        assert!(persisted.operations[0].id.is_some());
        assert_eq!(
            persisted.operations[0].id,
            compiled(&schema, &plain(text), &config).operations[0].id,
            "{text}"
        );
    }
}

#[test]
fn the_plan_says_raw_response_only_of_an_operation_that_asks_for_it() {
    let schema = test_schema();
    for text in [QUERY, SUBSCRIPTION, MUTATION] {
        let asked = serde_json::to_value(&compiled(&schema, text, &swift_config()).operations[0])
            .expect("the plan serializes");
        assert_eq!(asked["raw_response"], true, "{text}");
        let plain =
            serde_json::to_value(&compiled(&schema, &plain(text), &swift_config()).operations[0])
                .expect("the plan serializes");
        assert!(plain.get("raw_response").is_none(), "{text}: {plain}");
    }
}

/// The messages of a clash with the optimistic response, as the same clash
/// with the raw response reads.
fn as_raw(messages: Vec<String>) -> Vec<String> {
    messages
        .into_iter()
        .map(|message| {
            message
                .replace(
                    "the mutation's `OptimisticResponse`",
                    "the operation's `RawResponse`",
                )
                .replace("the optimistic response's", "the raw response's")
                .replace("OptimisticResponse", "RawResponse")
        })
        .collect()
}

#[test]
fn a_name_clashes_with_the_raw_response_where_it_clashes_with_the_optimistic_response() {
    let schema = test_schema();
    // Each pair is the clash with the raw response and the same clash with
    // the optimistic response: a variable and a spread fragment named like
    // the builder, and a response field named like the root builder's
    // `payload` or any builder's `variable`.
    let pairs = [
        (
            "query Probe($RawResponse: ID!) @raw_response_type { character(id: $RawResponse) { id } }",
            "mutation Probe($OptimisticResponse: ID!) { setFavorite(id: $OptimisticResponse, favorite: true) { character { id } } }",
        ),
        (
            "subscription Probe($RawResponse: ID!) @raw_response_type { noteAdded(characterId: $RawResponse) { noteEdge { cursor } } }",
            "mutation Probe($OptimisticResponse: ID!) { setFavorite(id: $OptimisticResponse, favorite: true) { character { id } } }",
        ),
        (
            "fragment RawResponse on Character { id } query Probe @raw_response_type { character(id: \"1\") { ...RawResponse } }",
            "fragment OptimisticResponse on Character { id } mutation Probe { setFavorite(id: \"1\", favorite: true) { character { ...OptimisticResponse } } }",
        ),
        (
            "query Probe @raw_response_type { payload: character(id: \"1\") { id } }",
            "mutation Probe { payload: setFavorite(id: \"1\", favorite: true) { character { id } } }",
        ),
        (
            "query Probe @raw_response_type { character(id: \"1\") { variable: name } }",
            "mutation Probe { setFavorite(id: \"1\", favorite: true) { character { variable: name } } }",
        ),
    ];
    for (language, naming) in namings() {
        for (raw, optimistic) in pairs {
            let refused = clashes(&schema, raw, &naming);
            assert!(!refused.is_empty(), "{language}: `{raw}` is refused");
            assert_eq!(
                refused,
                as_raw(clashes(&schema, optimistic, &naming)),
                "{language}: `{raw}`"
            );
            // Without the directive a query has no builder, and the name is
            // what the optimistic response's is in a query: a name only the
            // language's own rules may keep.
            let unasked = plain(raw);
            assert_eq!(
                clashes(&schema, &unasked, &naming),
                as_raw(clashes(
                    &schema,
                    &unasked.replace("RawResponse", "OptimisticResponse"),
                    &naming
                )),
                "{language}: `{unasked}`"
            );
        }
    }
}

#[test]
fn a_variable_named_like_the_raw_response_is_an_error_that_names_it() {
    let schema = test_schema();
    let text =
        "query Probe($RawResponse: ID!) @raw_response_type { character(id: $RawResponse) { id } }";
    for (language, naming) in namings() {
        assert_eq!(
            clashes(&schema, text, &naming),
            [format!(
                "the variable `$RawResponse` clashes with the operation's `RawResponse` in the generated {language}; rename the variable"
            )]
        );
    }
}

/// The builder `swift` declares last, from its doc comment to its end.
fn swift_builder(swift: &str) -> String {
    let start = swift
        .rfind(&format!(
            "    /// {RAW_SUMMARY}\n    nonisolated public struct RawResponse"
        ))
        .or_else(|| {
            swift.rfind(&format!(
                "    /// {OPTIMISTIC_SUMMARY}\n    nonisolated public struct OptimisticResponse"
            ))
        })
        .unwrap_or_else(|| panic!("no builder in:\n{swift}"));
    // The builder ends where the operation value that nests it does.
    let end = swift[start..]
        .find("\n}\n")
        .map_or(swift.len(), |end| start + end + 3);
    swift[start..end].to_string()
}

#[test]
fn a_root_field_named_like_the_raw_response_nests_what_one_named_like_the_optimistic_response_does()
{
    let schema = namesake_schema();
    for (raw, optimistic) in [
        (
            "query Probe @raw_response_type { rawResponse { id } }",
            "mutation Probe { optimisticResponse { id } }",
        ),
        (
            "query Probe @raw_response_type { RawResponse { id } }",
            "mutation Probe { OptimisticResponse { id } }",
        ),
        (
            "subscription Probe @raw_response_type { rawResponse { id } }",
            "mutation Probe { optimisticResponse { id } }",
        ),
    ] {
        for (language, naming) in namings() {
            assert_eq!(
                clashes(&schema, raw, &naming),
                as_raw(clashes(&schema, optimistic, &naming)),
                "{language}: `{raw}`"
            );
        }
        let written = swift_builder(&swift_of(&schema, raw));
        let expected = swift_builder(&swift_of(&schema, optimistic))
            .replace(OPTIMISTIC_SUMMARY, RAW_SUMMARY)
            .replace("OptimisticResponse", "RawResponse")
            .replace("optimisticResponse", "rawResponse");
        assert_eq!(written, expected, "`{raw}`");
    }
}
