//! Tests of schema input objects: the Swift struct the shared file declares
//! for each input the documents' variables name, the variables typed by it,
//! and the names it takes or refuses at the module's top level; and an input
//! the schema declares `@oneOf`, a choice of one field, as the Swift enum and
//! the Kotlin sealed interface the shared files declare for it.

use super::*;
use crate::naming::NameError;

/// What the compiler makes of `text` against the schema `sdl` under an
/// empty configuration: the Swift it writes, or its errors' messages.
fn emitted_against(sdl: &str, text: &str) -> Result<crate::emit::Output, Vec<String>> {
    let mut config: Config = serde_json::from_str("{}").expect("the configuration parses");
    config.path = PathBuf::from("baton.json");
    let compiled =
        compile(sdl, "schema.graphql", &[], &[document(text)], &config).map_err(|errors| {
            errors
                .iter()
                .map(|error| error.message().to_string())
                .collect::<Vec<_>>()
        })?;
    crate::emit::swift(&compiled.plan, &config).map_err(|errors| {
        errors
            .iter()
            .map(|error| match error {
                NameError::Clash(clash) => clash.to_string(),
                NameError::Duplicate(duplicate) => duplicate.to_string(),
            })
            .collect()
    })
}

/// The emitted Swift of `text` against `sdl`: the files of its definitions,
/// then the shared file.
fn emitted_with(sdl: &str, text: &str) -> (String, String) {
    let output = emitted_against(sdl, text).unwrap_or_else(|errors| panic!("{errors:?}"));
    (
        output.files.into_values().collect::<Vec<_>>().join("\n"),
        output.shared,
    )
}

/// A schema of a nested input, a list field and an enum field, beside a
/// non-null field and a nullable one.
const SEARCH: &str = r#"
schema { query: Query }
type Query { search(query: Search!): [Item] }
type Item { name: String }
input Range { min: Int! max: Int }
input Search { range: Range! tags: [String!] status: Status }
enum Status { OPEN CLOSED }
"#;

#[test]
fn the_shared_file_declares_a_struct_with_a_property_and_a_parameter_per_field() {
    let (sdl, _) = schema();
    let (_, shared) = emitted_with(
        &sdl,
        "query Probe($filter: FilterCharacter) { characters(filter: $filter) { info { count } } }",
    );
    let declaration = r#"/// The schema's input object `FilterCharacter`. A field left nil is absent from the request, as GraphQL distinguishes absent from null.
nonisolated public struct FilterCharacter: Baton.InputObject {
    public var name: String?
    public var status: String?
    public var species: String?
    public var type: String?
    public var gender: String?

    public init(name: String? = nil, status: String? = nil, species: String? = nil, type: String? = nil, gender: String? = nil) {
        self.name = name
        self.status = status
        self.species = species
        self.type = type
        self.gender = gender
    }

    public var variable: Baton.Variable {
        var fields: [String: Baton.Variable] = [:]
        if let name { fields["name"] = .init(name) }
        if let status { fields["status"] = .init(status) }
        if let species { fields["species"] = .init(species) }
        if let type { fields["type"] = .init(type) }
        if let gender { fields["gender"] = .init(gender) }
        return .object(fields)
    }
}
"#;
    assert!(shared.contains(declaration), "{shared}");
}

#[test]
fn a_non_null_field_is_required_and_written_unconditionally_and_a_nested_input_is_its_struct() {
    let (swift, shared) = emitted_with(
        SEARCH,
        "query Probe($query: Search!) { search(query: $query) { name } }",
    );
    let search = r#"nonisolated public struct Search: Baton.InputObject {
    public var range: Range
    public var tags: [String]?
    public var status: Status?

    public init(range: Range, tags: [String]? = nil, status: Status? = nil) {
        self.range = range
        self.tags = tags
        self.status = status
    }

    public var variable: Baton.Variable {
        var fields: [String: Baton.Variable] = [:]
        fields["range"] = .init(range)
        if let tags { fields["tags"] = .init(tags) }
        if let status { fields["status"] = .init(status) }
        return .object(fields)
    }
}
"#;
    assert!(shared.contains(search), "{shared}");
    let range = r#"nonisolated public struct Range: Baton.InputObject {
    public var min: Int
    public var max: Int?

    public init(min: Int, max: Int? = nil) {
        self.min = min
        self.max = max
    }

    public var variable: Baton.Variable {
        var fields: [String: Baton.Variable] = [:]
        fields["min"] = .init(min)
        if let max { fields["max"] = .init(max) }
        return .object(fields)
    }
}
"#;
    assert!(
        shared.contains(range),
        "an input named only by another input's field is declared: {shared}"
    );
    assert!(
        shared.contains("nonisolated public enum Status: Baton.GeneratedEnum {"),
        "an enum named only by an input's field is declared: {shared}"
    );
    assert!(swift.contains("public var query: Search\n"), "{swift}");
    assert!(swift.contains("public init(query: Search)"), "{swift}");
}

#[test]
fn an_input_named_like_a_shared_enum_or_a_standard_library_type_takes_input_after_its_name() {
    let sdl = r#"
schema { query: Query }
type Query { thing(kind: Types, result: Result): String }
input Types { name: String }
input Result { ok: Boolean }
"#;
    let (swift, shared) = emitted_with(
        sdl,
        "query Probe($kind: Types, $result: Result) { thing(kind: $kind, result: $result) }",
    );
    assert!(
        shared.contains("nonisolated public struct TypesInput: Baton.InputObject {"),
        "{shared}"
    );
    assert!(
        shared.contains("nonisolated public struct ResultInput: Baton.InputObject {"),
        "{shared}"
    );
    assert!(
        shared.contains("nonisolated enum Types {"),
        "the shared `Types` keeps its name: {shared}"
    );
    assert!(swift.contains("public var kind: TypesInput?"), "{swift}");
    assert!(swift.contains("public var result: ResultInput?"), "{swift}");
}

#[test]
fn a_field_named_variable_takes_an_underscore_and_keeps_its_name_in_the_request() {
    let sdl = r#"
schema { query: Query }
type Query { thing(by: By!): String }
input By { variable: String! }
"#;
    let (_, shared) = emitted_with(sdl, "query Probe($by: By!) { thing(by: $by) }");
    assert!(
        shared.contains("    public var variable_: String\n"),
        "{shared}"
    );
    assert!(
        shared.contains("public init(variable_: String) {"),
        "{shared}"
    );
    assert!(
        shared.contains(r#"fields["variable"] = .init(variable_)"#),
        "{shared}"
    );
    assert!(
        shared.contains("    public var variable: Baton.Variable {"),
        "the struct's own member keeps its name: {shared}"
    );
}

#[test]
fn a_fragment_named_like_an_input_is_a_clash_the_fragment_resolves_by_renaming() {
    let (sdl, _) = schema();
    let errors = emitted_against(
        &sdl,
        "query Probe($filter: FilterCharacter) { characters(filter: $filter) { ...FilterCharacter } }
         fragment FilterCharacter on Characters { info { count } }",
    )
    .err()
    .expect("a fragment named `FilterCharacter` clashes with the schema's input object");
    assert_eq!(
        errors,
        vec![
            "the fragment `FilterCharacter` clashes with the schema's input object `FilterCharacter` in the generated Swift; rename the fragment"
        ]
    );
}

#[test]
fn an_operation_named_like_an_input_is_a_clash_the_operation_resolves_by_renaming() {
    let (sdl, _) = schema();
    let errors = emitted_against(
        &sdl,
        "query FilterCharacter($filter: FilterCharacter) { characters(filter: $filter) { info { count } } }",
    )
    .err()
    .expect("an operation named `FilterCharacter` clashes with the schema's input object");
    assert_eq!(
        errors,
        vec![
            "the query `FilterCharacter` clashes with the schema's input object `FilterCharacter` in the generated Swift; rename the query"
        ]
    );
}

#[test]
fn an_input_that_names_itself_through_a_field_is_declared_once() {
    let sdl = r#"
schema { query: Query }
type Query { tree(root: Node): String }
input Node { child: Node label: String }
"#;
    let (_, shared) = emitted_with(sdl, "query Probe($root: Node) { tree(root: $root) }");
    assert_eq!(
        shared
            .matches("nonisolated public struct Node: Baton.InputObject {")
            .count(),
        1,
        "{shared}"
    );
    assert!(
        shared.contains("    private var __child: Baton.Indirect<Node?>\n"),
        "a field holding its own input is boxed: {shared}"
    );
    assert!(
        shared.contains(
            "    public var child: Node? { get { __child.value } set { __child.value = newValue } }\n"
        ),
        "{shared}"
    );
    assert!(
        shared.contains("        self.__child = .init(child)\n"),
        "{shared}"
    );
    assert!(
        shared.contains("    public var label: String?\n"),
        "a field outside the cycle is stored: {shared}"
    );
}

/// Two inputs that name each other, beside a list of the input, which an
/// array already stores apart.
const CYCLE: &str = r#"
schema { query: Query }
type Query { find(filter: Filter): String }
input Filter { name: String not: Filter all: [Filter!] by: Clause }
input Clause { filter: Filter }
"#;

#[test]
fn every_field_of_a_cycle_through_inputs_is_boxed_and_a_list_of_the_input_is_not() {
    let (_, shared) = emitted_with(
        CYCLE,
        "query Probe($filter: Filter) { find(filter: $filter) }",
    );
    let filter = shared
        .split("nonisolated public struct Filter: Baton.InputObject {")
        .nth(1)
        .and_then(|rest| rest.split("\n}\n").next())
        .unwrap_or_else(|| panic!("`Filter` is declared: {shared}"));
    let clause = shared
        .split("nonisolated public struct Clause: Baton.InputObject {")
        .nth(1)
        .and_then(|rest| rest.split("\n}\n").next())
        .unwrap_or_else(|| panic!("`Clause` is declared: {shared}"));
    assert!(
        filter.contains("    private var __not: Baton.Indirect<Filter?>\n"),
        "{filter}"
    );
    assert!(
        filter.contains("    private var __by: Baton.Indirect<Clause?>\n"),
        "{filter}"
    );
    assert!(
        filter.contains("    public var all: [Filter]?\n"),
        "a list of the input is stored: {filter}"
    );
    assert!(!filter.contains("__all"), "{filter}");
    assert!(
        filter.contains("    public var name: String?\n"),
        "{filter}"
    );
    assert!(
        clause.contains("    private var __filter: Baton.Indirect<Filter?>\n"),
        "{clause}"
    );
    assert!(
        clause.contains("        self.__filter = .init(filter)\n"),
        "{clause}"
    );
}

#[test]
fn a_module_whose_variables_name_no_input_declares_no_struct() {
    let (sdl, _) = schema();
    let (_, shared) = emitted_with(
        &sdl,
        "query Probe($id: ID!) { character(id: $id) { name } }",
    );
    assert!(!shared.contains("Baton.InputObject"), "{shared}");
}

/// What the compiler plans for `text` against the schema `sdl` under an
/// empty configuration.
fn planned(sdl: &str, text: &str) -> crate::pipeline::Plan {
    let mut config: Config = serde_json::from_str("{}").expect("the configuration parses");
    config.path = PathBuf::from("baton.json");
    compile(sdl, "schema.graphql", &[], &[document(text)], &config)
        .unwrap_or_else(|errors| panic!("{errors:?}"))
        .plan
}

/// The Kotlin shared file of `text` against `sdl`, in the package
/// `app.generated`.
fn kotlin_shared(sdl: &str, text: &str) -> String {
    let config = Config {
        language: crate::config::Language::Kotlin,
        kotlin: Some(crate::config::KotlinConfig {
            package: Some("app.generated".to_string()),
        }),
        ..Config::default()
    };
    let compiled = compile(sdl, "schema.graphql", &[], &[document(text)], &config)
        .unwrap_or_else(|errors| panic!("{errors:?}"));
    let naming = crate::kotlin_names::KotlinNaming::new(&config).into();
    let program = crate::decide::program(&compiled.plan, &naming)
        .unwrap_or_else(|errors| panic!("{errors:?}"));
    crate::emit::Kotlin::new(&config, Default::default())
        .emit(&program)
        .shared
}

/// The test schema's `@oneOf` input, by a variable of it.
const CHARACTER_BY: &str = "query Probe($by: CharacterBy!) { characterBy(by: $by) { id } }";

/// A `@oneOf` input of fields named as Swift's keywords, as the member
/// every input declares, as the input itself and as a type of Kotlin's
/// standard library, none of which holds the input.
const CHOICE: &str = r#"
schema { query: Query }
type Query { pick(choice: Choice!): String }
input Choice @oneOf { in: String variable: Int choice: Boolean list: [Int!] }
"#;

#[test]
fn a_one_of_input_is_an_enum_with_a_case_per_field_holding_the_field_made_non_null() {
    let (sdl, _) = schema();
    let (swift, shared) = emitted_with(&sdl, CHARACTER_BY);
    let declaration = r#"/// The schema's input object `CharacterBy`, of which exactly one field is given: a case per field, with the field's value.
nonisolated public indirect enum CharacterBy: Baton.InputObject {
    case id(String)
    case status(Status)
    case names([String])
    case residence(Residence)
    case fallback(CharacterBy)

    public var variable: Baton.Variable {
        switch self {
            case .id(let value): .object(["id": .init(value)])
            case .status(let value): .object(["status": .init(value)])
            case .names(let value): .object(["names": .init(value)])
            case .residence(let value): .object(["residence": .init(value)])
            case .fallback(let value): .object(["fallback": .init(value)])
        }
    }
}
"#;
    assert!(shared.contains(declaration), "{shared}");
    assert!(
        !shared.contains("struct CharacterBy"),
        "a `@oneOf` input is no struct: {shared}"
    );
    assert!(swift.contains("public var by: CharacterBy\n"), "{swift}");
    assert!(swift.contains("public init(by: CharacterBy)"), "{swift}");
}

#[test]
fn a_one_of_input_that_holds_no_input_of_its_own_is_not_indirect() {
    let (_, shared) = emitted_with(
        CHOICE,
        "query Probe($choice: Choice!) { pick(choice: $choice) }",
    );
    assert!(
        shared.contains("nonisolated public enum Choice: Baton.InputObject {\n"),
        "{shared}"
    );
    assert!(!shared.contains("indirect"), "{shared}");
}

#[test]
fn a_one_of_case_takes_the_name_a_struct_property_takes_and_keeps_its_field_name_in_the_request() {
    let (_, shared) = emitted_with(
        CHOICE,
        "query Probe($choice: Choice!) { pick(choice: $choice) }",
    );
    for line in [
        "    case `in`(String)\n",
        "    case variable_(Int)\n",
        "    case choice(Bool)\n",
        "    case list([Int])\n",
        r#"            case .`in`(let value): .object(["in": .init(value)])"#,
        r#"            case .variable_(let value): .object(["variable": .init(value)])"#,
        r#"            case .choice(let value): .object(["choice": .init(value)])"#,
    ] {
        assert!(shared.contains(line), "`{line}` in {shared}");
    }
    assert!(
        shared.contains("    public var variable: Baton.Variable {"),
        "the enum's own member keeps its name: {shared}"
    );
}

#[test]
fn a_one_of_input_is_a_sealed_interface_with_a_data_class_per_field_in_kotlin() {
    let (sdl, _) = schema();
    let shared = kotlin_shared(&sdl, CHARACTER_BY);
    let declaration = r#"/** The schema's input object `CharacterBy`, of which exactly one field is given: a class per field, with the field's value. */
sealed interface CharacterBy : InputObject {
    data class Id(val id: String) : CharacterBy { override val variable: Variable get() = Variable.Object(Variables.of("id" to Variable.of(id)).values) }
    data class Status_(val status: Status) : CharacterBy { override val variable: Variable get() = Variable.Object(Variables.of("status" to Variable.of(status)).values) }
    data class Names(val names: List<String>) : CharacterBy { override val variable: Variable get() = Variable.Object(Variables.of("names" to Variable.List(names.map { Variable.of(it) })).values) }
    data class Residence_(val residence: Residence) : CharacterBy { override val variable: Variable get() = Variable.Object(Variables.of("residence" to Variable.of(residence)).values) }
    data class Fallback(val fallback: CharacterBy) : CharacterBy { override val variable: Variable get() = Variable.Object(Variables.of("fallback" to Variable.of(fallback)).values) }
}
"#;
    assert!(shared.contains(declaration), "{shared}");
}

#[test]
fn a_kotlin_case_named_like_a_type_a_case_holds_takes_an_underscore_so_it_shadows_none() {
    let (sdl, _) = schema();
    let shared = kotlin_shared(&sdl, CHARACTER_BY);
    // `Residence` and `Status` are the values' own types: a nested class of
    // either name would make `val residence: Residence` its own case.
    assert!(
        shared.contains("data class Residence_(val residence: Residence) : CharacterBy {"),
        "{shared}"
    );
    assert!(
        shared.contains("data class Status_(val status: Status) : CharacterBy {"),
        "{shared}"
    );
    assert!(
        !shared.contains("    data class Residence("),
        "no case is named `Residence`: {shared}"
    );
}

#[test]
fn a_kotlin_case_named_like_its_interface_the_runtime_or_the_standard_library_takes_an_underscore()
{
    let shared = kotlin_shared(
        CHOICE,
        "query Probe($choice: Choice!) { pick(choice: $choice) }",
    );
    for line in [
        "    data class In(val `in`: String) : Choice { override val variable: Variable get() = Variable.Object(Variables.of(\"in\" to Variable.of(`in`)).values) }\n",
        "    data class Variable_(val variable_: Int) : Choice { override val variable: Variable get() = Variable.Object(Variables.of(\"variable\" to Variable.of(variable_)).values) }\n",
        "    data class Choice_(val choice: Boolean) : Choice {",
        "    data class List_(val list: List<Int>) : Choice {",
    ] {
        assert!(shared.contains(line), "`{line}` in {shared}");
    }
}

#[test]
fn the_plan_marks_a_one_of_input_and_leaves_the_mark_out_of_any_other() {
    let (sdl, _) = schema();
    let plan = planned(&sdl, CHARACTER_BY);
    let one_of = &plan.inputs["CharacterBy"];
    assert!(one_of.one_of);
    let names: Vec<&str> = one_of
        .fields
        .iter()
        .map(|field| field.name.as_str())
        .collect();
    assert_eq!(names, ["id", "status", "names", "residence", "fallback"]);
    let record = &plan.inputs["Residence"];
    assert!(!record.one_of);
    let json = serde_json::to_value(&plan.inputs).expect("the inputs serialize");
    assert_eq!(json["CharacterBy"]["one_of"], serde_json::json!(true));
    assert!(
        json["Residence"].get("one_of").is_none(),
        "a record carries no mark: {json}"
    );
}

#[test]
fn an_input_a_one_of_input_holds_without_one_of_of_its_own_is_still_a_struct_and_a_data_class() {
    let (sdl, _) = schema();
    let (_, swift) = emitted_with(&sdl, CHARACTER_BY);
    assert!(
        swift.contains(
            "nonisolated public struct Residence: Baton.InputObject {\n    public var dimension: String\n"
        ),
        "{swift}"
    );
    let kotlin = kotlin_shared(&sdl, CHARACTER_BY);
    assert!(
        kotlin.contains("data class Residence(val dimension: String) : InputObject {"),
        "{kotlin}"
    );
    assert!(!kotlin.contains("sealed interface Residence"), "{kotlin}");
}

/// A `@oneOf` input of two fields whose names capitalize alike.
const TWICE: &str = r#"
schema { query: Query }
type Query { pick(twice: Twice!): String }
input Twice @oneOf { id: ID Id: String }
"#;

#[test]
fn two_kotlin_cases_whose_fields_capitalize_alike_take_distinct_classes_and_swift_keeps_both_cases()
{
    let text = "query Probe($twice: Twice!) { pick(twice: $twice) }";
    let kotlin = kotlin_shared(TWICE, text);
    let first = "    data class Id(val id: String) : Twice { override val variable: Variable get() = Variable.Object(Variables.of(\"id\" to Variable.of(id)).values) }\n";
    let second = "    data class Id_(val Id: String) : Twice { override val variable: Variable get() = Variable.Object(Variables.of(\"Id\" to Variable.of(Id)).values) }\n";
    assert!(kotlin.contains(first), "{kotlin}");
    assert!(kotlin.contains(second), "{kotlin}");
    assert_eq!(
        kotlin.matches("    data class Id(").count(),
        1,
        "the two cases are two classes: {kotlin}"
    );
    let (_, swift) = emitted_with(TWICE, text);
    assert!(swift.contains("    case id(String)\n"), "{swift}");
    assert!(swift.contains("    case Id(String)\n"), "{swift}");
}
