//! Tests of schema input objects: the Swift struct the shared file declares
//! for each input the documents' variables name, the variables typed by it,
//! and the names it takes or refuses at the module's top level.

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
    crate::emit::emit(&compiled.plan, &config).map_err(|errors| {
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
