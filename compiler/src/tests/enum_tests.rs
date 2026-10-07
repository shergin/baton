//! Tests of schema enums: the Swift enum the shared file declares for each
//! enum the documents read or pass, the accessors and variables of its
//! type, and the names it takes or refuses at the module's top level.

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

/// The emitted Swift of `text` against the test schema: the files of its
/// definitions, then the shared file.
fn emitted(text: &str) -> (String, String) {
    let (sdl, _) = schema();
    let output = emitted_against(&sdl, text).unwrap_or_else(|errors| panic!("{errors:?}"));
    (
        output.files.into_values().collect::<Vec<_>>().join("\n"),
        output.shared,
    )
}

/// A schema of two enums named like what the generated code spells: a
/// shared enum of the module and a standard library type.
const NAMESAKES: &str = r#"
schema { query: Query }
type Query { kinds: [Types] result: Result! }
enum Types { PLAIN }
enum Result { OK FAILED }
"#;

#[test]
fn the_shared_file_declares_an_enum_with_a_case_per_value_and_one_for_a_value_the_build_does_not_know()
 {
    let (_, shared) = emitted("mutation Probe { setLists { statuses } }");
    let declaration = r#"/// The schema's enum `Status`. A value this build does not know reads as `unknown`, with its text.
nonisolated public enum Status: Baton.GeneratedEnum {
    case ALIVE
    case DEAD
    case UNKNOWN
    case unknown(String)

    public init(enumText: String) {
        self = switch enumText {
            case "ALIVE": .ALIVE
            case "DEAD": .DEAD
            case "UNKNOWN": .UNKNOWN
            default: .unknown(enumText)
        }
    }

    public var scalarText: String {
        switch self {
            case .ALIVE: "ALIVE"
            case .DEAD: "DEAD"
            case .UNKNOWN: "UNKNOWN"
            case .unknown(let text): text
        }
    }
}
"#;
    assert!(shared.contains(declaration), "{shared}");
}

#[test]
fn an_enum_no_document_reads_or_passes_is_not_declared() {
    let (_, shared) = emitted(QUERY);
    assert!(!shared.contains("GeneratedEnum"), "{shared}");
}

#[test]
fn a_list_of_an_enum_reads_through_its_enum_reader_and_its_builder_takes_the_enum() {
    let (swift, _) = emitted("mutation Probe { setLists { statuses } }");
    assert!(
        swift.contains(
            "public var statuses: [Status?]? { anchor.nullableEnumValues(Slots.ListsPayload.statuses) }"
        ),
        "{swift}"
    );
    assert!(
        swift.contains("public init(statuses: [Status?]? = nil)"),
        "{swift}"
    );
    assert!(
        swift.contains(r#"if let statuses { fields["statuses"] = .init(statuses) }"#),
        "{swift}"
    );
    assert!(
        swift.contains(r#".scalar("statuses", key: .fixed(Slots.ListsPayload.statuses), kind: .string, list: true)"#),
        "the plan keeps the enum's text: {swift}"
    );
}

#[test]
fn a_variable_of_an_enum_and_a_list_of_them_are_typed_as_the_enum() {
    let (swift, _) = emitted(
        "query Probe($status: Status!, $any: [Status!]) { charactersWithStatus(status: $status, any: $any) { name } }",
    );
    assert!(swift.contains("    public var status: Status\n"), "{swift}");
    assert!(
        swift.contains("    public var `any`: [Status]?\n"),
        "{swift}"
    );
    assert!(
        swift.contains("public init(status: Status, `any`: [Status]? = nil)"),
        "{swift}"
    );
    assert!(
        swift.contains(r#""status": Baton.Variable(self.status)"#),
        "{swift}"
    );
}

#[test]
fn a_non_null_enum_keeps_its_nullability_since_its_conversion_cannot_fail() {
    let output = emitted_against(NAMESAKES, "query Probe { result }")
        .unwrap_or_else(|errors| panic!("{errors:?}"));
    let swift: String = output.files.into_values().collect();
    assert!(
        swift.contains("public var result: ResultEnum { anchor.requiredEnumValue("),
        "{swift}"
    );
}

#[test]
fn an_enum_named_like_a_shared_enum_or_a_standard_library_type_takes_enum_after_its_name() {
    let output = emitted_against(NAMESAKES, "query Probe { kinds result }")
        .unwrap_or_else(|errors| panic!("{errors:?}"));
    assert!(
        output
            .shared
            .contains("nonisolated public enum TypesEnum: Baton.GeneratedEnum {"),
        "{}",
        output.shared
    );
    assert!(
        output
            .shared
            .contains("nonisolated public enum ResultEnum: Baton.GeneratedEnum {"),
        "{}",
        output.shared
    );
    assert!(
        output.shared.contains("nonisolated enum Types {"),
        "the shared `Types` keeps its name: {}",
        output.shared
    );
    let swift: String = output.files.into_values().collect();
    assert!(
        swift.contains("public var kinds: [TypesEnum?]? { anchor.nullableEnumValues("),
        "{swift}"
    );
}

#[test]
fn a_fragment_named_like_a_schema_enum_is_a_clash_the_fragment_resolves_by_renaming() {
    let (sdl, _) = schema();
    let errors = emitted_against(
        &sdl,
        "mutation Probe { setLists { ...Status } } fragment Status on ListsPayload { statuses }",
    )
    .err()
    .expect("a fragment named `Status` clashes with the schema's enum");
    assert_eq!(
        errors,
        vec![
            "the fragment `Status` clashes with the schema's enum `Status` in the generated Swift; rename the fragment"
        ]
    );
}

#[test]
fn an_operation_named_like_a_schema_enum_is_a_clash_the_operation_resolves_by_renaming() {
    let (sdl, _) = schema();
    let errors = emitted_against(&sdl, "mutation Status { setLists { statuses } }")
        .err()
        .expect("an operation named `Status` clashes with the schema's enum");
    assert_eq!(
        errors,
        vec![
            "the mutation `Status` clashes with the schema's enum `Status` in the generated Swift; rename the mutation"
        ]
    );
}

/// A schema whose enums are named like what generated code nests or
/// spells: a linked field `status` whose lens and builder would be named
/// `Status`, the operation's `Data`, and the module `Foundation`.
const HIDING: &str = r#"
schema { query: Query mutation: Mutation }
type Query { thing(kind: Data, f: Foundation): Thing }
type Mutation { setThing: Thing }
type Thing { id: ID! kind: Kind origin: Origin status: StatusInfo state: Status }
type Origin { name: String kind: Kind }
type StatusInfo { name: String }
enum Data { A }
enum Foundation { B }
enum Kind { K }
enum Status { S }
"#;

/// The Swift written for `text` against `HIDING`: the files of its
/// definitions, then the shared file.
fn emitted_hiding(text: &str) -> (String, String) {
    let output = emitted_against(HIDING, text).unwrap_or_else(|errors| panic!("{errors:?}"));
    (
        output.files.into_values().collect::<Vec<_>>().join("\n"),
        output.shared,
    )
}

#[test]
fn a_nested_lens_named_like_an_enum_takes_lens_after_its_name_so_the_enum_stays_visible() {
    let (swift, _) = emitted_hiding("query Probe { thing { status { name } state } }");
    assert!(
        swift.contains("nonisolated public struct StatusLens: Baton.Lens {"),
        "{swift}"
    );
    assert!(
        swift.contains(
            "public var status: StatusLens? { anchor.linked(Slots.Thing.status).map(StatusLens.init(anchor:)) }"
        ),
        "{swift}"
    );
    assert!(
        swift.contains("public var state: Status? { anchor.enumValue(Slots.Thing.state) }"),
        "{swift}"
    );
    assert!(
        !swift.contains("struct Status:"),
        "no nested type hides the enum: {swift}"
    );
}

#[test]
fn a_nested_builder_named_like_an_enum_takes_response_after_its_name_so_the_enum_stays_visible() {
    let (swift, _) = emitted_hiding("mutation Probe { setThing { status { name } state } }");
    assert!(
        swift.contains("nonisolated public struct StatusResponse: Sendable {"),
        "{swift}"
    );
    assert!(
        swift.contains("public var status: StatusResponse?"),
        "{swift}"
    );
    assert!(swift.contains("public var state: Status?\n"), "{swift}");
    assert!(
        !swift.contains("struct Status:"),
        "no nested type hides the enum: {swift}"
    );
}

#[test]
fn an_enum_named_data_or_foundation_takes_enum_after_its_name() {
    let (swift, shared) = emitted_hiding(
        "query Probe($kind: Data, $f: Foundation) { thing(kind: $kind, f: $f) { kind origin { name kind } status { name } state } }",
    );
    assert!(
        shared.contains("nonisolated public enum DataEnum: Baton.GeneratedEnum {"),
        "{shared}"
    );
    assert!(
        shared.contains("nonisolated public enum FoundationEnum: Baton.GeneratedEnum {"),
        "{shared}"
    );
    assert!(
        !shared.contains("enum Data:") && !shared.contains("enum Foundation:"),
        "{shared}"
    );
    // The operation's variables name the enums, not its `Data` lens or the
    // module.
    assert!(
        swift.contains("    public var kind: DataEnum?\n"),
        "{swift}"
    );
    assert!(
        swift.contains("    public var f: FoundationEnum?\n"),
        "{swift}"
    );
    assert!(
        swift.contains("public init(kind: DataEnum? = nil, f: FoundationEnum? = nil)"),
        "{swift}"
    );
    assert!(
        swift.contains("nonisolated public struct Data: Baton.Lens {"),
        "{swift}"
    );
    // The nested lens `Origin` reads the enum `Kind`, which nothing hides.
    assert!(
        swift.contains("public var kind: Kind? { anchor.enumValue(Slots.Origin.kind) }"),
        "{swift}"
    );
    assert!(
        swift.contains("nonisolated public struct Origin: Baton.Lens {"),
        "{swift}"
    );
    assert!(
        swift.contains("public var state: Status? { anchor.enumValue(Slots.Thing.state) }"),
        "{swift}"
    );
    assert!(
        swift.contains("nonisolated public struct StatusLens: Baton.Lens {"),
        "{swift}"
    );
}
