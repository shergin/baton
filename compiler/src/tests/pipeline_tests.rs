//! Tests of lowering and of the configuration it checks, against the test
//! schema.

use std::path::{Path, PathBuf};

use super::*;
use crate::config::Config;
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
        start: crate::swift::Position { line: 1, column: 1 },
        text: text.to_string(),
        embedded: None,
    }
}

/// The messages compiling `text` with `config` fails with.
fn errors(config: &str, text: &str) -> Vec<String> {
    let (sdl, path) = schema();
    let mut config: Config = serde_json::from_str(config).expect("the configuration parses");
    config.path = PathBuf::from("baton.json");
    match compile(&sdl, &path, &[document(text)], &config) {
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
        &[document("query Probe { namesake(name: \"a\") { name } }")],
        &Config::default(),
    )
    .unwrap_or_else(|errors| panic!("{errors:?}"));
    let SelectionPlan::Linked {
        has_id,
        is_abstract,
        ..
    } = &compiled.plan.operations[0].normalization[0]
    else {
        panic!("namesake is a link");
    };
    assert!(*is_abstract);
    assert!(
        *has_id,
        "Character and Location, which implement Named, have ids"
    );
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
        &[
            document("query Probe { character(id: \"1\") { name } }"),
            document("mutation Rename { rename(id: \"1\", name: \"a\") { name } }"),
            document("subscription Renamed { renamed(id: \"1\") { name } }"),
        ],
        &Config::default(),
    )
    .unwrap_or_else(|errors| panic!("{errors:?}"));
    let shared = crate::emit::emit(&compiled.plan)
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
fn a_root_named_otherwise_that_an_interface_or_union_reaches_is_an_error() {
    for extension in [
        "interface Thing { id: ID }\nextend type QueryRoot implements Thing { id: ID }",
        "union Anything = QueryRoot | Character",
    ] {
        let sdl = format!("{RENAMED_ROOTS}\n{extension}\n");
        let Err(errors) = compile(
            &sdl,
            "schema.graphql",
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
    let compiled = compile(&sdl, &path, &[document(text)], &config)
        .unwrap_or_else(|errors| panic!("{errors:?}"));
    let operation = &compiled.plan.operations[0];
    assert_eq!(operation.error_behavior.as_deref(), Some("null"));
    let output = crate::emit::emit(&compiled.plan).expect("the plan emits");
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

    let plain = compile(&sdl, &path, &[document(text)], &Config::default())
        .unwrap_or_else(|errors| panic!("{errors:?}"));
    let plain_file = crate::emit::emit(&plain.plan).expect("the plan emits");
    let plain_file = plain_file
        .files
        .values()
        .next()
        .expect("the operation has a file");
    assert!(!plain_file.contains("errorBehavior"));
    assert!(plain_file.contains("public var totalCount: Int {"));
}

#[test]
fn a_persisted_id_is_the_hash_of_the_text_the_app_holds() {
    let (sdl, path) = schema();
    let compiled = compile(&sdl, &path, &[document(QUERY)], &Config::default())
        .unwrap_or_else(|errors| panic!("{errors:?}"));
    let operation = &compiled.plan.operations[0];
    assert_eq!(operation.text, operation.text.trim_end());
    assert_eq!(
        operation.id,
        format!("{:x}", md5::compute(operation.text.as_bytes()))
    );
}

#[test]
fn slots_are_nested_per_type_so_a_type_and_a_field_never_run_together() {
    let sdl = "type Query { a: A, a_b: A_b } type A { b_c: String } type A_b { c: String }";
    let compiled = compile(
        sdl,
        "schema.graphql",
        &[document("query Probe { a { b_c } a_b { c } }")],
        &Config::default(),
    )
    .unwrap_or_else(|errors| panic!("{errors:?}"));
    let shared = crate::emit::emit(&compiled.plan)
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
        &[document("query Probe { type { a } self { a } }")],
        &Config::default(),
    )
    .unwrap_or_else(|errors| panic!("{errors:?}"));
    let output = crate::emit::emit(&compiled.plan).expect("the plan emits");
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
fn a_slot_name_swift_would_misread_takes_an_underscore_and_meets_no_other() {
    let sdl = "type Query { types: Types } type Types { Type: String, Type_: String, Baton: String, name: String }";
    let compiled = compile(
        sdl,
        "schema.graphql",
        &[document("query Probe { types { Type Type_ Baton name } }")],
        &Config::default(),
    )
    .unwrap_or_else(|errors| panic!("{errors:?}"));
    let shared = crate::emit::emit(&compiled.plan)
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
