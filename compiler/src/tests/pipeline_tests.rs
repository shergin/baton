//! Tests of lowering and of the configuration it checks, against the test
//! schema.

use std::path::{Path, PathBuf};

use super::*;
use crate::config::{Config, OnError};
use crate::documents::Document;

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

fn document(text: &str) -> Document {
    Document {
        path: PathBuf::from("Pipeline.swift"),
        index: 0,
        start: crate::documents::Position { line: 1, column: 1 },
        text: text.to_string(),
        embedded: None,
    }
}

/// The messages compiling `text` with `config` fails with.
fn errors(config: &str, text: &str) -> Vec<String> {
    let (sdl, path) = schema();
    let mut config: Config = serde_json::from_str(config).expect("the configuration parses");
    config.path = PathBuf::from("baton.json");
    match compile(&sdl, &path, &[], &[document(text)], &config) {
        Ok(_) => Vec::new(),
        Err(diagnostics) => diagnostics
            .iter()
            .map(|diagnostic| diagnostic.message().to_string())
            .collect(),
    }
}

const QUERY: &str = "query Probe { character(id: \"1\") { name } }";

#[test]
fn a_lookup_is_checked_against_the_schema_when_the_configuration_loads() {
    assert!(
        errors(
            r#"{"lookups": [{"field": "Query.character", "type": "Character", "argument": "id"}]}"#,
            QUERY
        )
        .is_empty()
    );
    assert_eq!(
        errors(
            r#"{"lookups": [{"field": "Query.character", "type": "Character", "argument": "key"}]}"#,
            QUERY
        ),
        vec!["the lookup `Query.character` takes `key`, which the field has no argument of"]
    );
    assert_eq!(
        errors(
            r#"{"lookups": [{"field": "Query.persona", "type": "Character", "argument": "id"}]}"#,
            QUERY
        ),
        vec!["the lookup `Query.persona` names a field `Query` does not have"]
    );
    assert_eq!(
        errors(
            r#"{"lookups": [{"field": "Query.character", "type": "Location", "argument": "id"}]}"#,
            QUERY
        ),
        vec![
            "the lookup `Query.character` names the type `Location`, but the field returns `Character`"
        ]
    );
    assert_eq!(
        errors(
            r#"{"lookups": [{"field": "Query.node", "type": "Character", "argument": "id"}]}"#,
            QUERY
        ),
        vec![
            "`Query.node` returns `Node`, an interface or union: the lookup takes no `type`, and finds the id among its types"
        ]
    );
    assert_eq!(
        errors(
            r#"{"lookups": [{"field": "Query.character", "argument": "id"}]}"#,
            QUERY
        ),
        vec!["`Query.character` returns `Character`: name it as the lookup's `type`"]
    );
}

#[test]
fn a_configuration_with_a_key_it_does_not_know_is_an_error() {
    assert!(serde_json::from_str::<Config>(r#"{"schema": "s.graphql", "lookup": []}"#).is_err());
    assert!(
        serde_json::from_str::<Config>(
            r#"{"lookups": [{"field": "Query.node", "argument": "id", "typ": "Node"}]}"#
        )
        .is_err()
    );
}

#[test]
fn an_interface_whose_implementers_have_ids_is_keyed_by_id_though_it_declares_none() {
    let (sdl, path) = schema();
    let compiled = compile(
        &sdl,
        &path,
        &[],
        &[document("query Probe { namesake(name: \"a\") { name } }")],
        &Config::default(),
    )
    .unwrap_or_else(|errors| panic!("{errors:?}"));
    let SelectionPlan::Linked {
        keys, is_abstract, ..
    } = &compiled.plan.operations[0].normalization[0]
    else {
        panic!("namesake is a link");
    };
    assert!(*is_abstract);
    for member in ["Character", "Location"] {
        assert_eq!(
            keys.get(member),
            Some(&vec!["id".to_string()]),
            "{member}, which implements Named, is keyed by its id"
        );
    }
}

const RENAMED_ROOTS: &str = "
schema { query: QueryRoot, mutation: mutation_root, subscription: subscription_root }
type QueryRoot { character(id: ID!): Character }
type mutation_root { rename(id: ID!, name: String!): Character }
type subscription_root { renamed(id: ID!): Character }
type Character { id: ID! name: String }
";

#[test]
fn a_root_type_the_schema_names_otherwise_is_interned_by_the_store_root_name() {
    let compiled = compile(
        RENAMED_ROOTS,
        "schema.graphql",
        &[],
        &[
            document("query Probe { character(id: \"1\") { name } }"),
            document("mutation Rename { rename(id: \"1\", name: \"a\") { name } }"),
            document("subscription Renamed { renamed(id: \"1\") { name } }"),
        ],
        &Config::default(),
    )
    .unwrap_or_else(|errors| panic!("{errors:?}"));
    let shared = crate::emit::swift(&compiled.plan, &Config::default())
        .expect("the plan emits")
        .shared;
    assert!(shared.contains("static let QueryRoot = Baton.Registry.type(\"Query\")"));
    assert!(shared.contains("static let mutation_root = Baton.Registry.type(\"Mutation\")"));
    assert!(
        shared.contains("static let subscription_root = Baton.Registry.type(\"Subscription\")")
    );
    assert!(shared.contains("static let Character = Baton.Registry.type(\"Character\")"));
}

#[test]
fn a_type_named_like_a_store_root_beside_a_root_named_otherwise_is_an_error() {
    let sdl = format!("{RENAMED_ROOTS}\ntype Query {{ id: ID }}\n");
    let Err(errors) = compile(
        &sdl,
        "schema.graphql",
        &[],
        &[document("query Probe { character(id: \"1\") { name } }")],
        &Config::default(),
    ) else {
        panic!("the schema compiled");
    };
    let messages: Vec<String> = errors
        .iter()
        .map(|error| error.message().to_string())
        .collect();
    assert_eq!(
        messages,
        vec![
            "the query type is `QueryRoot` and another type is named `Query`: the store types its query root `Query`, so the two would share their fields"
        ]
    );
}

#[test]
fn defer_in_a_mutation_or_a_subscription_is_an_error() {
    assert_eq!(
        errors(
            "{}",
            "mutation Probe { rename(id: \"1\", name: \"a\") { character { id ...ProbeName @defer(label: \"later\") } } } fragment ProbeName on Character { name }"
        ),
        vec![
            "`@defer` in the mutation `Probe`: its response arrives in one part, so nothing can be deferred"
        ]
    );
    assert_eq!(
        errors(
            "{}",
            "subscription Probe { noteAdded(characterId: \"1\") { character { id ...ProbeName @defer(label: \"later\") } } } fragment ProbeName on Character { name }"
        ),
        vec![
            "`@defer` in the subscription `Probe`: its response arrives in one part, so nothing can be deferred"
        ]
    );
}

#[test]
fn stream_in_a_mutation_or_a_subscription_is_an_error() {
    let mutation = errors(
        "{}",
        "mutation Probe { rename(id: \"1\", name: \"a\") { character { id episode @stream(label: \"later\", initialCount: 1) { id } } } }",
    );
    assert_eq!(
        mutation,
        vec![
            "`@stream` in the mutation `Probe`: its response arrives in one part, so nothing can be streamed"
        ]
    );
    let subscription = errors(
        "{}",
        "subscription Probe { noteAdded(characterId: \"1\") { character { id episode @stream(label: \"later\", initialCount: 1) { id } } } }",
    );
    assert_eq!(
        subscription,
        vec![
            "`@stream` in the subscription `Probe`: its response arrives in one part, so nothing can be streamed"
        ]
    );
}

#[test]
fn stream_on_a_list_of_scalars_is_refused() {
    let messages = errors(
        "{}",
        "query Probe { tokenizer { strings @stream(label: \"later\", initialCount: 1) } }",
    );
    assert_eq!(messages.len(), 1, "{messages:?}");
    assert!(
        messages[0].contains("@stream") && messages[0].contains("scalar"),
        "{messages:?}"
    );
}

#[test]
fn stream_connection_on_a_connection_compiles() {
    assert!(
        errors(
            "{}",
            "query Probe($id: ID!) { character(id: $id) { id notes(first: 2) @stream_connection(key: \"Probe_notes\", initial_count: 1) { edges { node { id text } } } } }"
        )
        .is_empty()
    );
}

/// The one operation `text` compiles to against `sdl`.
fn operation(sdl: &str, text: &str) -> OperationPlan {
    let compiled = compile(
        sdl,
        "schema.graphql",
        &[],
        &[document(text)],
        &Config::default(),
    )
    .unwrap_or_else(|errors| panic!("the document does not compile: {errors:?}"));
    compiled.plan.operations[0].clone()
}

/// The stream label of the linked field `name` wherever it sits in
/// `selections`, or none when the field is not there.
fn stream_label<'a>(selections: &'a [SelectionPlan], name: &str) -> Option<&'a Option<String>> {
    selections.iter().find_map(|selection| match selection {
        SelectionPlan::Linked {
            name: field,
            streamed,
            selections,
            ..
        } => {
            if field == name {
                Some(streamed)
            } else {
                stream_label(selections, name)
            }
        }
        SelectionPlan::Inline { selections, .. } | SelectionPlan::Condition { selections, .. } => {
            stream_label(selections, name)
        }
        _ => None,
    })
}

#[test]
fn a_streamed_list_carries_its_label_on_the_linked_field_and_marks_the_operation_incremental() {
    let (sdl, _) = schema();
    let streamed = operation(
        &sdl,
        "query TestStreamedEpisodes($id: ID!) { character(id: $id) { id name episode @stream(label: \"episodes\", initialCount: 1) { id name } } }",
    );
    assert!(streamed.has_incremental);
    assert_eq!(
        stream_label(&streamed.normalization, "episode"),
        Some(&Some("TestStreamedEpisodes$stream$episodes".to_string()))
    );
    assert_eq!(
        stream_label(&streamed.normalization, "character"),
        Some(&None)
    );
    let whole = operation(
        &sdl,
        "query Probe($id: ID!) { character(id: $id) { id episode { id name } } }",
    );
    assert!(!whole.has_incremental);
    assert_eq!(stream_label(&whole.normalization, "episode"), Some(&None));
}

#[test]
fn the_stream_arguments_follow_the_spelling_the_schema_declares() {
    let (sdl, _) = schema();
    let relay = sdl.replace(
        "directive @stream(label: String, if: Boolean = true, initialCount: Int = 0, useCustomizedBatch: Boolean = false) on FIELD",
        "directive @stream(label: String, if: Boolean = true, initial_count: Int = 0, use_customized_batch: Boolean = false) on FIELD",
    );
    assert_ne!(
        relay, sdl,
        "the test schema declares the specification's `@stream`"
    );
    let streamed = operation(
        &relay,
        "query Probe($id: ID!) { character(id: $id) { id episode @stream(label: \"episodes\", initial_count: 1) { id } } }",
    );
    assert!(streamed.has_incremental);
    assert!(
        streamed.text.contains("initial_count:1"),
        "{}",
        streamed.text
    );
    let specification = operation(
        &sdl,
        "query Probe($id: ID!) { character(id: $id) { id episode @stream(label: \"episodes\", initialCount: 1) { id } } }",
    );
    assert!(
        specification.text.contains("initialCount:1"),
        "{}",
        specification.text
    );
}

#[test]
fn a_root_named_otherwise_that_an_interface_or_union_reaches_is_an_error() {
    for extension in [
        "interface Thing { id: ID }\nextend type QueryRoot implements Thing { id: ID }",
        "union Anything = QueryRoot | Character",
    ] {
        let sdl = format!("{RENAMED_ROOTS}\n{extension}\n");
        let Err(errors) = compile(
            &sdl,
            "schema.graphql",
            &[],
            &[document("query Probe { character(id: \"1\") { name } }")],
            &Config::default(),
        ) else {
            panic!("the schema compiled with {extension}");
        };
        assert_eq!(
            errors
                .iter()
                .map(|error| error.message().to_string())
                .collect::<Vec<_>>(),
            vec![
                "the query type `QueryRoot` implements an interface or belongs to a union: the store types its query root `Query`, which a payload's `__typename` would not name"
            ]
        );
    }
}

#[test]
fn an_error_in_a_selection_is_told_once_though_the_operation_is_lowered_twice() {
    let sdl = "type Query { person(id: ID): Person } type Person { id: ID! name: String }";
    let mut config: Config = serde_json::from_str(
        r#"{"lookups": [{"field": "Query.person", "type": "Person", "argument": "id"}]}"#,
    )
    .expect("the configuration parses");
    config.path = PathBuf::from("baton.json");
    let Err(errors) = compile(
        sdl,
        "schema.graphql",
        &[],
        &[document("query Probe { person { name } }")],
        &config,
    ) else {
        panic!("the selection passes no id");
    };
    assert_eq!(errors.len(), 1, "{errors:?}");
}

#[test]
fn on_error_null_sends_the_value_and_types_non_null_fields_by_their_semantic_nullability() {
    let (sdl, path) = schema();
    let mut config: Config =
        serde_json::from_str(r#"{"onError": "NULL"}"#).expect("the configuration parses");
    config.path = PathBuf::from("baton.json");
    let text = "query Probe { character(id: \"1\") { name notes(first: 1) @connection(key: \"Probe_notes\") { totalCount edges { node { id } } } } }";
    let compiled = compile(&sdl, &path, &[], &[document(text)], &config)
        .unwrap_or_else(|errors| panic!("{errors:?}"));
    let operation = &compiled.plan.operations[0];
    assert_eq!(operation.error_behavior, Some(OnError::Null));
    let output = crate::emit::swift(&compiled.plan, &Config::default()).expect("the plan emits");
    let file = output
        .files
        .values()
        .next()
        .expect("the operation has a file");
    assert!(file.contains("public static let errorBehavior: Baton.ErrorBehavior? = .null"));
    assert!(
        file.contains("public var totalCount: Int? {"),
        "`Int!` reads optional outside `@catch` and `@throwOnFieldError`"
    );

    let plain = compile(&sdl, &path, &[], &[document(text)], &Config::default())
        .unwrap_or_else(|errors| panic!("{errors:?}"));
    let plain_file = crate::emit::swift(&plain.plan, &Config::default()).expect("the plan emits");
    let plain_file = plain_file
        .files
        .values()
        .next()
        .expect("the operation has a file");
    assert!(!plain_file.contains("errorBehavior"));
    assert!(plain_file.contains("public var totalCount: Int {"));
}

#[test]
fn a_query_states_its_cache_expiration_in_its_plan_and_its_swift_and_not_in_the_text_it_sends() {
    let (sdl, path) = schema();
    let text = "query Probe @cacheExpiration(seconds: 30) { character(id: \"1\") { name } }";
    let compiled = compile(&sdl, &path, &[], &[document(text)], &Config::default())
        .unwrap_or_else(|errors| panic!("{errors:?}"));
    let operation = &compiled.plan.operations[0];
    assert_eq!(operation.cache_expiration, Some(30.0));
    assert!(
        !operation.text.contains("cacheExpiration"),
        "a directive the schema extension declares is not sent: {}",
        operation.text
    );
    let output = crate::emit::swift(&compiled.plan, &Config::default()).expect("the plan emits");
    let file = output
        .files
        .values()
        .next()
        .expect("the operation has a file");
    assert!(file.contains(
        "@_spi(Generated) public static let cacheExpiration: Swift.Duration? = .seconds(30)"
    ));

    let plain = compile(&sdl, &path, &[], &[document(QUERY)], &Config::default())
        .unwrap_or_else(|errors| panic!("{errors:?}"));
    assert_eq!(plain.plan.operations[0].cache_expiration, None);
    let plain_output = crate::emit::swift(&plain.plan, &Config::default()).expect("the plan emits");
    let plain_file = plain_output
        .files
        .values()
        .next()
        .expect("the operation has a file");
    assert!(!plain_file.contains("cacheExpiration"));
}

#[test]
fn a_cache_expiration_on_a_mutation_or_from_a_variable_is_an_error() {
    assert_eq!(
        errors(
            "{}",
            "mutation Probe @cacheExpiration(seconds: 30) { rename(id: \"1\", name: \"a\") { character { id } } }"
        ),
        vec![
            "`@cacheExpiration` on a mutation has no meaning in Baton; a mutation takes `@throwOnFieldError`, `@deletes`"
        ]
    );
    assert_eq!(
        errors(
            "{}",
            "query Probe($seconds: Int!) @cacheExpiration(seconds: $seconds) { character(id: \"1\") { name } }"
        ),
        vec![
            "`@cacheExpiration(seconds:)` takes a constant: how old the data may be is the document's to say, not a variable's"
        ]
    );
}

/// The tests' identity, `spec/tests/baton.json`'s: `Asset` keyed by `uuid`
/// and `Quote` by `base` and `quote`, every other type by `id`.
const SPEC_IDENTITY: &str =
    r#"{"identity": {"types": {"Asset": ["uuid"], "Quote": ["base", "quote"]}}}"#;

/// The plan compiling `text` against the test schema under the tests'
/// identity gives.
fn deleting(text: &str) -> Plan {
    let (sdl, path) = schema();
    let mut config: Config = serde_json::from_str(SPEC_IDENTITY).expect("the configuration parses");
    config.path = PathBuf::from("baton.json");
    compile(&sdl, &path, &[], &[document(text)], &config)
        .unwrap_or_else(|errors| panic!("{errors:?}"))
        .plan
}

/// The one error compiling the one-line `text` against `sdl` under
/// `config` fails with, and the text it points at: the rest of the line
/// from its column.
fn deletes_error_in(sdl: &str, config: &str, text: &str) -> (String, String) {
    let mut config: Config = serde_json::from_str(config).expect("the configuration parses");
    config.path = PathBuf::from("baton.json");
    let source = document(text);
    let Err(diagnostics) = compile(
        sdl,
        "schema.graphql",
        &[],
        std::slice::from_ref(&source),
        &config,
    ) else {
        panic!("`{text}` compiled");
    };
    assert_eq!(diagnostics.len(), 1, "{diagnostics:?}");
    let rendered = crate::diagnostics::render(&diagnostics[0], &[source]);
    assert_eq!(
        (rendered.path.as_str(), rendered.line),
        ("Pipeline.swift", 1)
    );
    let at = text[rendered.column as usize - 1..].to_string();
    (diagnostics[0].message().to_string(), at)
}

/// The one error compiling the one-line `text` against the test schema
/// under the tests' identity fails with, and the text it points at.
fn deletes_error(text: &str) -> (String, String) {
    let (sdl, _) = schema();
    deletes_error_in(&sdl, SPEC_IDENTITY, text)
}

#[test]
fn a_mutation_that_deletes_by_a_variable_carries_the_type_and_the_variable_in_its_plan() {
    let plan = deleting(
        "mutation Probe($id: ID!) @deletes(type: \"Note\", id: $id) { discardNote(id: $id) { deleted } }",
    );
    let operation = &plan.operations[0];
    assert_eq!(
        operation.deletes,
        vec![DeletePlan {
            type_name: "Note".to_string(),
            variable: "id".to_string(),
        }]
    );
    let json = serde_json::to_value(operation).expect("a plan serializes");
    assert_eq!(
        json["deletes"],
        serde_json::json!([{"type": "Note", "variable": "id"}])
    );
}

#[test]
fn a_mutation_deletes_one_record_for_each_deletes_it_states_in_their_order() {
    let plan = deleting(
        "mutation Probe($uuid: String!, $id: ID!) @deletes(type: \"Asset\", id: $uuid) @deletes(type: \"Note\", id: $id) { discardAsset(uuid: $uuid) { deleted } discardNote(id: $id) { deleted } }",
    );
    assert_eq!(
        plan.operations[0].deletes,
        vec![
            DeletePlan {
                type_name: "Asset".to_string(),
                variable: "uuid".to_string(),
            },
            DeletePlan {
                type_name: "Note".to_string(),
                variable: "id".to_string(),
            },
        ]
    );
}

#[test]
fn a_nullable_variable_of_the_key_type_is_one_deletes_may_name() {
    let operation = operation(
        DISCARDING,
        "mutation Probe($id: ID!, $also: ID) @deletes(type: \"Note\", id: $also) { discardNote(id: $id, also: $also) { deleted } }",
    );
    assert_eq!(
        operation.deletes,
        vec![DeletePlan {
            type_name: "Note".to_string(),
            variable: "also".to_string(),
        }]
    );
}

#[test]
fn a_plan_without_deletes_serializes_no_deletes() {
    let plan = deleting(
        "mutation Probe($id: ID!) { removeNote(id: $id) { removedNoteId @deleteRecord } }",
    );
    assert!(plan.operations[0].deletes.is_empty());
    let json = serde_json::to_value(&plan.operations[0]).expect("a plan serializes");
    assert!(json.get("deletes").is_none(), "{json}");
}

#[test]
fn the_text_a_server_receives_does_not_say_deletes() {
    let plan = deleting(
        "mutation Probe($id: ID!) @deletes(type: \"Note\", id: $id) { discardNote(id: $id) { deleted } }",
    );
    let sent = &plan.operations[0].text;
    assert_eq!(
        sent,
        "mutation Probe($id:ID!){discardNote(id:$id){deleted}}"
    );
    assert!(!sent.contains("deletes"), "{sent}");
}

#[test]
fn deletes_of_a_malformed_shape_is_an_error_at_the_directive() {
    let message = "`@deletes` takes `type`, the name of the record's type, and `id`, the variable the record's key is passed as";
    for directive in [
        "@deletes",
        "@deletes(type: \"Note\")",
        "@deletes(id: $id)",
        "@deletes(type: Note, id: $id)",
        "@deletes(type: \"Note\", id: \"n1\")",
        "@deletes(type: \"Note\", key: $id)",
        "@deletes(type: \"Note\", id: $id, also: $id)",
        "@deletes(type: \"Note\", type: \"Note\")",
    ] {
        let text = format!(
            "mutation Probe($id: ID!) {directive} {{ discardNote(id: $id) {{ deleted }} }}"
        );
        let (error, at) = deletes_error(&text);
        assert_eq!(error, message, "{directive}");
        assert!(at.starts_with("@deletes"), "{directive}: at `{at}`");
    }
}

#[test]
fn deletes_naming_a_variable_no_field_passes_is_an_error_at_the_variable() {
    assert_eq!(
        deletes_error(
            "mutation Probe($id: ID!, $other: ID!) @deletes(type: \"Note\", id: $other) { discardNote(id: $id) { deleted } }"
        ),
        (
            "`@deletes` names `$other`, which no field of `Probe` passes: a server refuses a variable its operation does not use".to_string(),
            "$other) { discardNote(id: $id) { deleted } }".to_string()
        )
    );
    assert_eq!(
        deletes_error(
            "mutation Probe @deletes(type: \"Note\", id: $id) { discardNote(id: \"n1\") { deleted } }"
        )
        .0,
        "`@deletes` names `$id`, which no field of `Probe` passes: a server refuses a variable its operation does not use",
        "a variable the mutation neither declares nor passes is one no field passes"
    );
}

#[test]
fn deletes_naming_a_type_the_schema_does_not_have_is_an_error_at_the_type() {
    assert_eq!(
        deletes_error(
            "mutation Probe($id: ID!) @deletes(type: \"Robot\", id: $id) { discardNote(id: $id) { deleted } }"
        ),
        (
            "`@deletes` names `Robot`, which the schema does not have".to_string(),
            "\"Robot\", id: $id) { discardNote(id: $id) { deleted } }".to_string()
        )
    );
}

#[test]
fn deletes_naming_an_interface_a_union_or_a_scalar_is_an_error_at_the_type() {
    for type_name in [
        "Node",
        "SearchResult",
        "Status",
        "FilterCharacter",
        "String",
    ] {
        let text = format!(
            "mutation Probe($id: ID!) @deletes(type: \"{type_name}\", id: $id) {{ discardNote(id: $id) {{ deleted }} }}"
        );
        let (error, at) = deletes_error(&text);
        assert_eq!(
            error,
            format!(
                "`@deletes` names `{type_name}`, which is not an object type: name the record's own type"
            )
        );
        assert!(at.starts_with(&format!("\"{type_name}\"")), "at `{at}`");
    }
}

#[test]
fn deletes_naming_a_type_with_no_key_is_an_error_at_the_type() {
    for type_name in ["Deleted", "FavoritePayload"] {
        let text = format!(
            "mutation Probe($id: ID!) @deletes(type: \"{type_name}\", id: $id) {{ discardNote(id: $id) {{ deleted }} }}"
        );
        let (error, at) = deletes_error(&text);
        assert_eq!(
            error,
            format!(
                "`@deletes` names `{type_name}`, which has no key: a record of it is keyed by its path, and no value names it"
            )
        );
        assert!(at.starts_with(&format!("\"{type_name}\"")), "at `{at}`");
    }
}

#[test]
fn deletes_naming_a_type_keyed_by_several_fields_is_an_error_at_the_type() {
    assert_eq!(
        deletes_error(
            "mutation Probe($id: ID!) @deletes(type: \"Quote\", id: $id) { discardNote(id: $id) { deleted } }"
        ),
        (
            "`Quote` is keyed by `base`, `quote`; `@deletes` names a record by one value"
                .to_string(),
            "\"Quote\", id: $id) { discardNote(id: $id) { deleted } }".to_string()
        )
    );
}

#[test]
fn deletes_naming_a_variable_of_another_type_than_the_key_is_an_error_at_the_variable() {
    assert_eq!(
        deletes_error(
            "mutation Probe($id: ID!) @deletes(type: \"Asset\", id: $id) { discardNote(id: $id) { deleted } }"
        ),
        (
            "`@deletes` names `$id` of type `ID` for `Asset`, whose key `uuid` is of type `String`"
                .to_string(),
            "$id) { discardNote(id: $id) { deleted } }".to_string()
        )
    );
    assert_eq!(
        deletes_error(
            "mutation Probe($uuid: String!) @deletes(type: \"Note\", id: $uuid) { discardAsset(uuid: $uuid) { deleted } }"
        )
        .0,
        "`@deletes` names `$uuid` of type `String` for `Note`, whose key `id` is of type `ID`"
    );
}

/// The plan compiling `texts`, each a document of one module, against the
/// test schema under the tests' identity gives.
fn deleting_across(texts: &[&str]) -> Plan {
    let (sdl, path) = schema();
    let mut config: Config = serde_json::from_str(SPEC_IDENTITY).expect("the configuration parses");
    config.path = PathBuf::from("baton.json");
    let documents: Vec<Document> = texts
        .iter()
        .enumerate()
        .map(|(index, text)| Document {
            index,
            ..document(text)
        })
        .collect();
    compile(&sdl, &path, &[], &documents, &config)
        .unwrap_or_else(|errors| panic!("{errors:?}"))
        .plan
}

/// The deletions of the one mutation in `plan`.
fn deletions(plan: &Plan) -> Vec<DeletePlan> {
    let mutations: Vec<&OperationPlan> = plan
        .operations
        .iter()
        .filter(|operation| operation.kind == OperationKind::Mutation)
        .collect();
    assert_eq!(mutations.len(), 1);
    mutations[0].deletes.clone()
}

/// The deletion the probes plan: a `Note` by `$id`.
fn note_by_id() -> Vec<DeletePlan> {
    vec![DeletePlan {
        type_name: "Note".to_string(),
        variable: "id".to_string(),
    }]
}

#[test]
fn a_mutation_that_passes_the_variable_only_inside_a_fragment_it_spreads_deletes_by_it() {
    let plan = deleting(
        "mutation Probe($id: ID!) @deletes(type: \"Note\", id: $id) { ...ProbeFields } fragment ProbeFields on Mutation { discardNote(id: $id) { deleted } }",
    );
    assert_eq!(deletions(&plan), note_by_id());
    assert_eq!(
        plan.operations[0].text,
        "mutation Probe($id:ID!){...ProbeFields}fragment ProbeFields on Mutation{discardNote(id:$id){deleted}}",
        "the server receives the variable through the fragment"
    );
}

#[test]
fn a_mutation_that_passes_the_variable_inside_a_fragment_of_another_document_deletes_by_it() {
    let plan = deleting_across(&[
        "mutation Probe($id: ID!) @deletes(type: \"Note\", id: $id) { ...ProbeFields }",
        "fragment ProbeFields on Mutation { discardNote(id: $id) { deleted } }",
    ]);
    assert_eq!(deletions(&plan), note_by_id());
    let plan = deleting_across(&[
        "fragment ProbeFields on Mutation { discardNote(id: $id) { deleted } }",
        "mutation Probe($id: ID!) @deletes(type: \"Note\", id: $id) { ...ProbeFields }",
    ]);
    assert_eq!(
        deletions(&plan),
        note_by_id(),
        "the fragment's document may come first"
    );
}

#[test]
fn a_mutation_that_passes_the_variable_two_spreads_down_deletes_by_it() {
    let plan = deleting(
        "mutation Probe($id: ID!) @deletes(type: \"Note\", id: $id) { ...ProbeOuter } fragment ProbeOuter on Mutation { ...ProbeInner } fragment ProbeInner on Mutation { discardNote(id: $id) { deleted } }",
    );
    assert_eq!(deletions(&plan), note_by_id());
}

#[test]
fn a_fragment_argument_of_the_variable_s_name_passes_it_only_when_the_spread_passes_it() {
    let fragment = "fragment ProbeFields on Mutation @argumentDefinitions(id: {type: \"ID!\"}) { discardNote(id: $id) { deleted } }";
    let plan = deleting(&format!(
        "mutation Probe($id: ID!) @deletes(type: \"Note\", id: $id) {{ ...ProbeFields @arguments(id: $id) }} {fragment}"
    ));
    assert_eq!(deletions(&plan), note_by_id());

    // Without `@arguments` the body's `$id` is the fragment's own argument,
    // which the operation's variable does not reach.
    assert_eq!(
        deletes_error(&format!(
            "mutation Probe($id: ID!) @deletes(type: \"Note\", id: $id) {{ ...ProbeFields }} {fragment}"
        )),
        (
            "`@deletes` names `$id`, which no field of `Probe` passes: a server refuses a variable its operation does not use".to_string(),
            format!("$id) {{ ...ProbeFields }} {fragment}")
        )
    );
}

#[test]
fn two_deletes_naming_the_same_type_and_variable_plan_one_deletion() {
    let plan = deleting(
        "mutation Probe($id: ID!) @deletes(type: \"Note\", id: $id) @deletes(type: \"Note\", id: $id) { discardNote(id: $id) { deleted } }",
    );
    assert_eq!(deletions(&plan), note_by_id());
}

/// A schema whose mutations pass a list of ids and an id the payload does
/// not name, for what the test schema's mutations cannot say.
const DISCARDING: &str = "
type Query { note(id: ID!): Note }
type Mutation { discardNotes(ids: [ID!]!): Deleted discardNote(id: ID!, also: ID): Deleted }
type Note { id: ID! text: String }
type Deleted { deleted: Boolean! }
";

#[test]
fn deletes_naming_a_list_variable_is_an_error_at_the_variable() {
    assert_eq!(
        deletes_error_in(
            DISCARDING,
            "{}",
            "mutation Probe($ids: [ID!]!) @deletes(type: \"Note\", id: $ids) { discardNotes(ids: $ids) { deleted } }"
        ),
        (
            "`@deletes` names `$ids`, a list; it names one record".to_string(),
            "$ids) { discardNotes(ids: $ids) { deleted } }".to_string()
        )
    );
}

/// The lowering's own check of an undeclared variable is not reached from a
/// document: a variable a field passes that the mutation does not declare
/// is refused by Relay's front end first, and one no field passes is the
/// syntax check's.
#[test]
fn deletes_naming_a_variable_the_mutation_does_not_declare_is_an_error() {
    assert_eq!(
        errors(
            SPEC_IDENTITY,
            "mutation Probe($id: ID!) @deletes(type: \"Note\", id: $undeclared) { discardNote(id: $id) { deleted @include(if: $undeclared) } }"
        ),
        vec!["Expected variable `$undeclared` to be defined on the operation 'Probe'"]
    );
}

#[test]
fn the_text_an_operation_holds_ends_at_its_last_brace() {
    let (sdl, path) = schema();
    let compiled = compile(&sdl, &path, &[], &[document(QUERY)], &Config::default())
        .unwrap_or_else(|errors| panic!("{errors:?}"));
    let operation = &compiled.plan.operations[0];
    assert_eq!(operation.text, operation.text.trim_end());
}

#[test]
fn slots_are_nested_per_type_so_a_type_and_a_field_never_run_together() {
    let sdl = "type Query { a: A, a_b: A_b } type A { b_c: String } type A_b { c: String }";
    let compiled = compile(
        sdl,
        "schema.graphql",
        &[],
        &[document("query Probe { a { b_c } a_b { c } }")],
        &Config::default(),
    )
    .unwrap_or_else(|errors| panic!("{errors:?}"));
    let shared = crate::emit::swift(&compiled.plan, &Config::default())
        .expect("the plan emits")
        .shared;
    assert!(shared.contains(
        "    nonisolated enum A {\n        static let b_c = Baton.Registry.slot(Types.A, \"b_c\")\n    }"
    ));
    assert!(shared.contains(
        "    nonisolated enum A_b {\n        static let c = Baton.Registry.slot(Types.A_b, \"c\")\n    }"
    ));
}

#[test]
fn a_linked_field_named_like_a_swift_type_gets_a_lens_of_another_name() {
    let sdl = "type Query { type: T, self: T } type T { a: String }";
    let compiled = compile(
        sdl,
        "schema.graphql",
        &[],
        &[document("query Probe { type { a } self { a } }")],
        &Config::default(),
    )
    .unwrap_or_else(|errors| panic!("{errors:?}"));
    let output = crate::emit::swift(&compiled.plan, &Config::default()).expect("the plan emits");
    let file = output
        .files
        .values()
        .next()
        .expect("the operation has a file");
    assert!(file.contains("public struct TypeLens: Baton.Lens"));
    assert!(file.contains("public struct SelfLens: Baton.Lens"));
    assert!(!file.contains("struct Type:"));
}

#[test]
fn a_type_constant_swift_would_misread_takes_an_underscore_and_meets_no_other() {
    let sdl = "type Query { a: Type, b: Type_, c: Baton } type Type { id: ID } type Type_ { id: ID } type Baton { id: ID }";
    let compiled = compile(
        sdl,
        "schema.graphql",
        &[],
        &[document("query Probe { a { id } b { id } c { id } }")],
        &Config::default(),
    )
    .unwrap_or_else(|errors| panic!("{errors:?}"));
    let output = crate::emit::swift(&compiled.plan, &Config::default()).expect("the plan emits");
    for declaration in [
        "    static let Baton_ = Baton.Registry.type(\"Baton\")\n",
        "    static let Type_ = Baton.Registry.type(\"Type\")\n",
        "    static let Type__ = Baton.Registry.type(\"Type_\")\n",
        "        static let id = Baton.Registry.slot(Types.Type__, \"id\")\n",
    ] {
        assert!(output.shared.contains(declaration), "{}", output.shared);
    }
    let file = output
        .files
        .values()
        .next()
        .expect("the operation has a file");
    assert!(
        file.contains("Baton.Selection(type: Types.Type__,"),
        "{file}"
    );
}

#[test]
fn a_slot_name_swift_would_misread_takes_an_underscore_and_meets_no_other() {
    let sdl = "type Query { types: Types } type Types { Type: String, Type_: String, Baton: String, name: String }";
    let compiled = compile(
        sdl,
        "schema.graphql",
        &[],
        &[document("query Probe { types { Type Type_ Baton name } }")],
        &Config::default(),
    )
    .unwrap_or_else(|errors| panic!("{errors:?}"));
    let shared = crate::emit::swift(&compiled.plan, &Config::default())
        .expect("the plan emits")
        .shared;
    assert!(
        shared.contains(concat!(
            "    nonisolated enum Types_ {\n",
            "        static let Baton_ = Baton.Registry.slot(Types.Types, \"Baton\")\n",
            "        static let Type_ = Baton.Registry.slot(Types.Types, \"Type\")\n",
            "        static let Type__ = Baton.Registry.slot(Types.Types, \"Type_\")\n",
            "        static let name = Baton.Registry.slot(Types.Types, \"name\")\n",
            "    }"
        )),
        "{shared}"
    );
}

/// A schema whose `Grid` has a list of lists and a one-depth list of each
/// kind, scalar and linked.
const GRID_SCHEMA: &str = "type Query { grid: Grid }
type Grid { cells: [[Int!]!]! rows: [[Row!]!] totals: [Int!]! columns: [Row!]! }
type Row { label: String }";

/// The diagnostics compiling `text` against `GRID_SCHEMA` fails with.
fn grid_diagnostics(text: &str) -> Vec<common::Diagnostic> {
    match compile(
        GRID_SCHEMA,
        "schema.graphql",
        &[],
        &[document(text)],
        &Config::default(),
    ) {
        Ok(_) => Vec::new(),
        Err(diagnostics) => diagnostics,
    }
}

fn grid_errors(text: &str) -> Vec<String> {
    grid_diagnostics(text)
        .iter()
        .map(|diagnostic| diagnostic.message().to_string())
        .collect()
}

#[test]
fn a_scalar_list_of_lists_is_refused_once_at_the_field() {
    assert_eq!(
        grid_errors("query Probe { grid { cells } }"),
        vec![
            "`cells` is a list of lists, `[[Int!]!]!`, which the runtime cannot hold; leave it out of the selection"
        ]
    );
}

#[test]
fn a_linked_list_of_lists_with_nullable_wrappers_is_refused_with_its_own_type() {
    assert_eq!(
        grid_errors("query Probe { grid { rows { label } } }"),
        vec![
            "`rows` is a list of lists, `[[Row!]!]`, which the runtime cannot hold; leave it out of the selection"
        ]
    );
}

#[test]
fn one_depth_lists_beside_a_list_of_lists_compile_when_it_is_left_out() {
    assert!(grid_errors("query Probe { grid { totals columns { label } } }").is_empty());
    assert_eq!(
        grid_errors("query Probe { grid { totals cells columns { label } } }"),
        vec![
            "`cells` is a list of lists, `[[Int!]!]!`, which the runtime cannot hold; leave it out of the selection"
        ]
    );
}

#[test]
fn the_list_of_lists_refusal_points_at_the_field_in_the_document() {
    let source = document("query Probe {\n  grid {\n    totals\n    table: cells\n  }\n}");
    let diagnostics = grid_diagnostics(&source.text);
    assert_eq!(diagnostics.len(), 1, "{diagnostics:?}");
    let rendered = crate::diagnostics::render(&diagnostics[0], &[source]);
    assert_eq!(
        (rendered.path.as_str(), rendered.line, rendered.column),
        ("Pipeline.swift", 4, 5)
    );
}

/// A schema whose `Shelf` has a scalar list of each nullability, and whose
/// root field takes a list of nullable ids and a list of lists.
const SHELF_SCHEMA: &str = "type Query { shelf(ids: [ID], cells: [[Int!]!]): Shelf }
type Shelf { loose: [String] dense: [String!] full: [String!]! holey: [String]! }";

/// The one Swift file compiling `text` against `SHELF_SCHEMA` emits.
fn shelf_swift(text: &str) -> String {
    let compiled = compile(
        SHELF_SCHEMA,
        "schema.graphql",
        &[],
        &[document(text)],
        &Config::default(),
    )
    .unwrap_or_else(|errors| panic!("{errors:?}"));
    let output = crate::emit::swift(&compiled.plan, &Config::default()).expect("the plan emits");
    output
        .files
        .into_values()
        .next()
        .expect("the operation has a file")
}

#[test]
fn a_scalar_list_reads_its_elements_optional_exactly_when_the_schema_types_them_nullable() {
    let file = shelf_swift("query Probe { shelf { loose dense full holey } }");
    for accessor in [
        "public var loose: [String?]? { anchor.nullableStrings(",
        "public var dense: [String]? { anchor.strings(",
        "public var full: [String] { anchor.requiredStrings(",
        "public var holey: [String?] { anchor.requiredNullableStrings(",
    ] {
        assert!(file.contains(accessor), "{accessor}\n{file}");
    }
}

#[test]
fn a_list_variable_of_nullable_ids_is_a_property_of_optional_strings() {
    let file = shelf_swift("query Probe($ids: [ID]) { shelf(ids: $ids) { loose } }");
    assert!(file.contains("public var ids: [String?]?"), "{file}");
}

#[test]
fn a_type_plan_keeps_every_list_and_the_nullability_of_each_level() {
    let compiled = compile(
        SHELF_SCHEMA,
        "schema.graphql",
        &[],
        &[document(
            "query Probe($cells: [[Int!]!]) { shelf(cells: $cells) { loose } }",
        )],
        &Config::default(),
    )
    .unwrap_or_else(|errors| panic!("{errors:?}"));
    let type_ = &compiled.plan.operations[0].variables[0].type_;
    let int = TypePlan::Named {
        name: "Int".to_string(),
        kind: TypeKind::Int,
        non_null: true,
        mapped: false,
    };
    let row = TypePlan::List {
        element: Box::new(int.clone()),
        non_null: true,
    };
    assert_eq!(
        *type_,
        TypePlan::List {
            element: Box::new(row),
            non_null: false,
        }
    );
    let mut depth = 0;
    let mut level = type_;
    while let Some(element) = level.element() {
        depth += 1;
        level = element;
    }
    assert_eq!(depth, 2);
    assert_eq!(type_.base(), &int);
    assert_eq!(type_.base_name(), "Int");
    assert_eq!(type_.base_kind(), TypeKind::Int);
    assert!(type_.is_list());
    assert!(!type_.non_null());
}

#[path = "identity_tests.rs"]
mod identity_tests;

#[path = "scalar_tests.rs"]
mod scalar_tests;

#[path = "enum_tests.rs"]
mod enum_tests;

#[path = "input_tests.rs"]
mod input_tests;

#[path = "extension_tests.rs"]
mod extension_tests;

#[path = "transient_tests.rs"]
mod transient_tests;

#[path = "condition_lens_tests.rs"]
mod condition_lens_tests;

#[path = "persist_tests.rs"]
mod persist_tests;

#[path = "inline_tests.rs"]
mod inline_tests;

#[test]
fn an_operation_prints_compact_with_its_fragments_following_it() {
    let (sdl, path) = schema();
    let mut config: Config = serde_json::from_str("{}").expect("the configuration parses");
    config.path = PathBuf::from("baton.json");
    let text = "query Probe($id: ID!, $first: Int) { character(id: $id) { name ...ProbeCharacter } } \
                fragment ProbeCharacter on Character { origin { name } notes(first: $first, after: \"a\") { edges { cursor } } }";
    let plan = compile(&sdl, &path, &[], &[document(text)], &config)
        .unwrap_or_else(|errors| panic!("{errors:?}"))
        .plan;
    let sent = &plan.operations[0].text;
    assert_eq!(
        sent,
        "query Probe($id:ID!,$first:Int){character(id:$id){name,...ProbeCharacter,id}}\
         fragment ProbeCharacter on Character{origin{name,id},notes(first:$first,after:\"a\"){edges{cursor}}}"
    );
    assert!(!sent.contains('\n'), "{sent}");
    assert!(!sent.contains("  "), "{sent}");
    assert!(!sent.contains(": ") && !sent.contains(", "), "{sent}");
}
