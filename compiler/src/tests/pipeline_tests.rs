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

    let plain = compile(&sdl, &path, &[], &[document(text)], &Config::default())
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
    let output = crate::emit::emit(&compiled.plan).expect("the plan emits");
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
    let plain_output = crate::emit::emit(&plain.plan).expect("the plan emits");
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
            "`@cacheExpiration` on a mutation has no meaning in Baton; a mutation takes `@throwOnFieldError`"
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

#[test]
fn a_persisted_id_is_the_hash_of_the_text_the_app_holds() {
    let (sdl, path) = schema();
    let compiled = compile(&sdl, &path, &[], &[document(QUERY)], &Config::default())
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
        &[],
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
        &[],
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
    let output = crate::emit::emit(&compiled.plan).expect("the plan emits");
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
    let output = crate::emit::emit(&compiled.plan).expect("the plan emits");
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
        mapped: None,
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
