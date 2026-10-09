//! Tests of the report: what an operation and a fragment reach, the order by
//! name, the types of variables as the schema writes them, the id under
//! `persistConfig`, sources relative to the root, the printed texts, the
//! lenses as the decided program reads them, and the JSON `generate`
//! writes.

use std::path::PathBuf;

use crate::config::Config;
use crate::documents::Document;
use crate::names::SwiftNaming;
use crate::pipeline::compile;

use super::*;

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

/// The plan of `documents`, each a host path and a text, under `config`.
fn compiled_at(config: &str, documents: &[(&str, &str)]) -> Plan {
    let (sdl, path) = schema();
    let mut config: Config = serde_json::from_str(config).expect("the configuration parses");
    config.path = PathBuf::from("baton.json");
    let documents: Vec<Document> = documents
        .iter()
        .enumerate()
        .map(|(index, (path, text))| Document {
            path: PathBuf::from(path),
            index,
            start: crate::documents::Position { line: 1, column: 1 },
            text: text.to_string(),
            embedded: None,
        })
        .collect();
    compile(&sdl, &path, &[], &documents, &config)
        .unwrap_or_else(|errors| panic!("{errors:?}"))
        .plan
}

/// The plan of `texts`, all in one host file, without configuration.
fn compiled(texts: &[&str]) -> Plan {
    let documents: Vec<(&str, &str)> = texts.iter().map(|text| ("Report.swift", *text)).collect();
    compiled_at("{}", &documents)
}

/// The report of `plan` from a root nothing lies under.
fn reported(plan: &Plan) -> Report {
    report(plan, Path::new("/nowhere"))
}

/// The program decided for `plan` in Swift's names, without configuration.
fn decided(plan: &Plan) -> Program {
    crate::decide::program(plan, &SwiftNaming::default())
        .unwrap_or_else(|errors| panic!("{errors:?}"))
}

/// The report of `plan` with its lenses, from a root nothing lies under.
fn reported_with_lenses(plan: &Plan) -> Report {
    let mut report = reported(plan);
    with_lenses(&mut report, &decided(plan));
    report
}

/// The report's text as `generate` writes it for `plan`.
fn written(plan: &Plan) -> String {
    text(plan, Path::new("/nowhere"), &decided(plan))
}

/// The accessor of `lens` named `name`.
fn accessor<'a>(lens: &'a LensReport, name: &str) -> &'a AccessorReport {
    lens.accessors
        .iter()
        .find(|accessor| accessor.name == name)
        .unwrap_or_else(|| panic!("the lens of `{}` has no accessor `{name}`", lens.type_name))
}

/// The lens an accessor reads.
fn nested(accessor: &AccessorReport) -> &LensReport {
    accessor
        .lens
        .as_deref()
        .unwrap_or_else(|| panic!("`{}` reads no lens", accessor.name))
}

fn operation<'a>(report: &'a Report, name: &str) -> &'a OperationReport {
    report
        .operations
        .iter()
        .find(|operation| operation.name == name)
        .unwrap_or_else(|| panic!("the report has no operation `{name}`"))
}

fn fragment<'a>(report: &'a Report, name: &str) -> &'a FragmentReport {
    report
        .fragments
        .iter()
        .find(|fragment| fragment.name == name)
        .unwrap_or_else(|| panic!("the report has no fragment `{name}`"))
}

const CHAIN: [&str; 4] = [
    "query Chain { character(id: \"1\") { ...ChainA } }",
    "fragment ChainA on Character { name ...ChainB }",
    "fragment ChainB on Character { origin { ...ChainC } }",
    "fragment ChainC on Location { dimension }",
];

#[test]
fn an_operation_reaches_the_fragments_its_fragments_spread_and_they_name_it() {
    let report = reported(&compiled(&CHAIN));
    assert_eq!(
        operation(&report, "Chain").fragments,
        vec!["ChainA", "ChainB", "ChainC"]
    );
    for name in ["ChainA", "ChainB", "ChainC"] {
        assert_eq!(fragment(&report, name).operations, vec!["Chain"], "{name}");
    }
    let reach = reach(&compiled(&CHAIN));
    assert_eq!(
        reach["Chain"].iter().collect::<Vec<_>>(),
        vec!["ChainA", "ChainB", "ChainC"]
    );
}

#[test]
fn a_fragment_nothing_spreads_is_reached_by_no_operation() {
    let report = reported(&compiled(&[
        "query Alone { character(id: \"1\") { name } }",
        "fragment Unspread on Character { name }",
    ]));
    assert!(operation(&report, "Alone").fragments.is_empty());
    assert!(fragment(&report, "Unspread").operations.is_empty());
}

#[test]
fn a_fragment_two_operations_reach_names_both_by_name() {
    let report = reported(&compiled(&[
        "query Second { character(id: \"2\") { ...Shared } }",
        "query First { character(id: \"1\") { ...Shared } }",
        "fragment Shared on Character { name }",
    ]));
    assert_eq!(
        fragment(&report, "Shared").operations,
        vec!["First", "Second"]
    );
}

#[test]
fn operations_and_fragments_are_sorted_by_name_whatever_the_source_order() {
    let report = reported(&compiled(&[
        "fragment Zeta on Character { name }",
        "query Omega { character(id: \"1\") { ...Zeta ...Alpha } }",
        "fragment Alpha on Character { status }",
        "query Beta { character(id: \"1\") { name } }",
        "fragment Mu on Location { name }",
    ]));
    let operations: Vec<&str> = report
        .operations
        .iter()
        .map(|operation| operation.name.as_str())
        .collect();
    let fragments: Vec<&str> = report
        .fragments
        .iter()
        .map(|fragment| fragment.name.as_str())
        .collect();
    assert_eq!(operations, vec!["Beta", "Omega"]);
    assert_eq!(fragments, vec!["Alpha", "Mu", "Zeta"]);
    assert_eq!(operation(&report, "Omega").fragments, vec!["Alpha", "Zeta"]);
}

#[test]
fn variables_are_typed_as_the_schema_writes_them() {
    let plan = compiled(&[
        "query Typed($id: ID!, $page: Int, $any: [Status!], $ids: [ID!]!) { \
         character(id: $id) { name } \
         characters(page: $page) { info { count } } \
         charactersWithStatus(status: ALIVE, any: $any) { name } \
         charactersByIds(ids: $ids) { name } }",
    ]);
    let report = reported(&plan);
    let variables: Vec<(&str, &str)> = operation(&report, "Typed")
        .variables
        .iter()
        .map(|variable| (variable.name.as_str(), variable.type_.as_str()))
        .collect();
    assert_eq!(
        variables,
        vec![
            ("id", "ID!"),
            ("page", "Int"),
            ("any", "[Status!]"),
            ("ids", "[ID!]!"),
        ]
    );
    let json: serde_json::Value =
        serde_json::from_str(&written(&plan)).expect("the report is JSON");
    assert_eq!(
        json["operations"][0]["variables"][3],
        serde_json::json!({"name": "ids", "type": "[ID!]!"})
    );
}

#[test]
fn an_operation_carries_an_id_under_persist_config_and_none_without() {
    let query = [(
        "Report.swift",
        "query Persisted { character(id: \"1\") { name } }",
    )];
    let persisted = compiled_at(r#"{"persistConfig": {"file": "persisted.json"}}"#, &query);
    let expected = persisted.operations[0].id.clone();
    assert!(expected.is_some());
    let report = reported(&persisted);
    assert_eq!(operation(&report, "Persisted").id, expected);
    let json: serde_json::Value =
        serde_json::from_str(&written(&persisted)).expect("the report is JSON");
    assert_eq!(
        json["operations"][0]["id"].as_str(),
        expected.as_deref(),
        "{json}"
    );

    let plain = compiled_at("{}", &query);
    let report = reported(&plain);
    assert_eq!(operation(&report, "Persisted").id, None);
    let json: serde_json::Value =
        serde_json::from_str(&written(&plain)).expect("the report is JSON");
    assert!(json["operations"][0].get("id").is_none(), "{json}");
}

#[test]
fn a_source_under_the_root_is_relative_with_forward_slashes_and_one_outside_is_kept() {
    let plan = compiled_at(
        "{}",
        &[
            (
                "/checkout/App/Sources/Inside.swift",
                "query Inside { character(id: \"1\") { ...Outside } }",
            ),
            (
                "/elsewhere/Outside.swift",
                "fragment Outside on Character { name }",
            ),
        ],
    );
    let report = report(&plan, Path::new("/checkout"));
    assert_eq!(
        operation(&report, "Inside").source,
        "App/Sources/Inside.swift"
    );
    assert_eq!(
        fragment(&report, "Outside").source,
        "/elsewhere/Outside.swift"
    );
}

#[test]
fn a_fragment_s_text_is_its_printed_definition_and_an_operation_s_its_plan_text() {
    let plan = compiled(&CHAIN);
    let report = reported(&plan);
    for (name, type_condition) in [
        ("ChainA", "Character"),
        ("ChainB", "Character"),
        ("ChainC", "Location"),
    ] {
        let text = &fragment(&report, name).text;
        assert!(
            text.starts_with(&format!("fragment {name} on {type_condition}")),
            "{text}"
        );
        assert_eq!(fragment(&report, name).type_condition, type_condition);
    }
    let planned = plan
        .operations
        .iter()
        .find(|operation| operation.name == "Chain")
        .expect("the plan has the operation");
    assert!(!planned.text.is_empty());
    assert_eq!(operation(&report, "Chain").text, planned.text);
}

#[test]
fn the_text_is_json_with_camel_case_keys_lowercase_kinds_and_one_final_newline() {
    let plan = compiled(&[
        "query Read { character(id: \"1\") { name } }",
        "mutation Write($id: ID!) { setFavorite(id: $id, favorite: true) { character { id } } }",
        "subscription Watch($id: ID!) { noteAdded(characterId: $id) { character { id } } }",
    ]);
    let written = written(&plan);
    assert!(written.ends_with("}\n"), "{written}");
    assert!(!written.ends_with("\n\n"), "{written}");
    let json: serde_json::Value = serde_json::from_str(&written).expect("the report is JSON");
    assert_eq!(
        json["schemaDigest"].as_str(),
        Some(plan.schema_digest.as_str())
    );
    assert!(json.get("schema_digest").is_none(), "{json}");
    let kinds: Vec<(&str, &str)> = json["operations"]
        .as_array()
        .expect("the operations are a list")
        .iter()
        .map(|operation| {
            (
                operation["name"].as_str().expect("a name"),
                operation["kind"].as_str().expect("a kind"),
            )
        })
        .collect();
    assert_eq!(
        kinds,
        vec![
            ("Read", "query"),
            ("Watch", "subscription"),
            ("Write", "mutation"),
        ]
    );
}

#[test]
fn a_refetchable_fragment_is_reached_by_its_refetch_query() {
    let report = reported(&compiled(&[
        "fragment Refetched on Character @refetchable(queryName: \"RefetchedQuery\") { name }",
    ]));
    assert_eq!(
        operation(&report, "RefetchedQuery").fragments,
        vec!["Refetched"]
    );
    assert_eq!(
        fragment(&report, "Refetched").operations,
        vec!["RefetchedQuery"]
    );
}

#[test]
fn an_unspread_fragment_s_text_is_its_definition() {
    let report = reported(&compiled(&[
        "query Alone { character(id: \"1\") { name } }",
        "fragment Unspread on Character { name status }",
    ]));
    assert_eq!(
        fragment(&report, "Unspread").text,
        "fragment Unspread on Character {\n  name\n  status\n}"
    );
}

#[test]
fn a_fragment_with_argument_definitions_prints_under_its_own_name_with_its_definitions() {
    let report = reported(&compiled(&[
        "query Spreading { ...Parameterized @arguments(ids: [\"1\", \"2\"]) }",
        "fragment Parameterized on Query @argumentDefinitions(ids: {type: \"[ID!]!\"}) { \
         charactersByIds(ids: $ids) { name } }",
    ]));
    let text = &fragment(&report, "Parameterized").text;
    let first_line = text.lines().next().expect("the text has a line");
    assert!(
        first_line.starts_with("fragment Parameterized on Query "),
        "the name carries no suffix: {text}"
    );
    assert!(text.contains("@argumentDefinitions"), "{text}");
    assert_eq!(
        fragment(&report, "Parameterized").operations,
        vec!["Spreading"]
    );
}

#[test]
fn a_lens_names_each_accessor_with_the_response_key_it_reads() {
    let report = reported_with_lenses(&compiled(&[
        "query Keys { hero: character(id: \"1\") { title: name status } }",
    ]));
    let lens = operation(&report, "Keys")
        .lens
        .as_ref()
        .expect("a decided operation has a lens");
    assert_eq!(lens.type_name, "Query");
    let hero = accessor(lens, "hero");
    assert_eq!(hero.key.as_deref(), Some("hero"));
    assert_eq!(hero.read, ReadKind::Linked);
    assert!(hero.optional, "a nullable link reads absent");
    let character = nested(hero);
    assert_eq!(character.type_name, "Character");
    assert_eq!(accessor(character, "title").key.as_deref(), Some("title"));
    assert_eq!(accessor(character, "status").key.as_deref(), Some("status"));
}

#[test]
fn an_accessor_s_shape_says_what_its_directives_make_of_the_read() {
    let report = reported_with_lenses(&compiled(&["query Shapes { character(id: \"1\") { \
         name @required(action: THROW) \
         status @catch \
         type @catch(to: NULL) \
         origin @catch { name } \
         episode { name } \
         gender @include(if: true) } }"]));
    let lens = operation(&report, "Shapes").lens.as_ref().expect("a lens");
    let character = nested(accessor(lens, "character"));

    let name = accessor(character, "name");
    assert!(name.throws && !name.optional && name.caught.is_none());

    let status = accessor(character, "status");
    let caught = status.caught.as_ref().expect("`@catch` reads a result");
    assert!(
        caught.optional,
        "a nullable field's result holds an optional value"
    );
    assert!(!status.optional && !status.throws);

    let type_ = accessor(character, "type");
    assert!(
        type_.optional && type_.caught.is_none(),
        "`@catch(to: NULL)` reads optional"
    );

    let origin = accessor(character, "origin");
    assert_eq!(origin.read, ReadKind::Linked);
    assert!(origin.caught.as_ref().expect("a caught link").optional);

    let episode = accessor(character, "episode");
    let list = episode.list.as_ref().expect("a plural link is a list");
    assert!(
        !list.optional_elements,
        "a list of links drops its null elements"
    );
    assert!(!episode.optional, "the schema types `episode` non-null");

    assert!(accessor(character, "gender").optional);
}

#[test]
fn a_type_condition_reads_for_its_types_and_a_spread_names_its_fragment() {
    let report = reported_with_lenses(&compiled(&[
        "query Found { search(name: \"a\") { ... on Character { name } } \
         character(id: \"1\") { ...Person } }",
        "fragment Person on Character { status }",
    ]));
    let lens = operation(&report, "Found").lens.as_ref().expect("a lens");
    let search = accessor(lens, "search");
    assert!(search.list.is_some() && search.optional);
    let result = nested(search);
    let condition = result
        .accessors
        .iter()
        .find(|accessor| accessor.read == ReadKind::Condition)
        .expect("the type condition has an accessor");
    assert_eq!(
        condition.types.as_deref(),
        Some(&["Character".to_string()][..])
    );
    assert!(condition.optional && condition.key.is_none());
    assert_eq!(
        accessor(nested(condition), "name").key.as_deref(),
        Some("name")
    );
    let spread = nested(accessor(lens, "character"))
        .accessors
        .iter()
        .find(|accessor| accessor.read == ReadKind::Spread)
        .expect("the spread has an accessor");
    assert_eq!(spread.fragment.as_deref(), Some("Person"));
    assert!(spread.key.is_none() && !spread.optional);
    let person = fragment(&report, "Person")
        .lens
        .as_ref()
        .expect("a fragment's lens");
    assert_eq!(person.type_name, "Character");
    assert_eq!(accessor(person, "status").key.as_deref(), Some("status"));
}

#[test]
fn a_report_of_the_plan_alone_has_no_lenses_and_the_json_leaves_them_out() {
    let plan = compiled(&["query Plain { character(id: \"1\") { name } }"]);
    assert!(operation(&reported(&plan), "Plain").lens.is_none());
    let json = serde_json::to_value(reported(&plan)).expect("the report is JSON");
    assert!(json["operations"][0].get("lens").is_none(), "{json}");
    let written: serde_json::Value =
        serde_json::from_str(&written(&plan)).expect("the report is JSON");
    assert_eq!(
        written["operations"][0]["lens"]["accessors"][0]["name"],
        serde_json::json!("character")
    );
}
