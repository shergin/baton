//! Tests of mapped scalars: the diagnostics of a `customScalarTypes` entry
//! the schema cannot honour, and the accessors, checks and variables the
//! emitter writes for a scalar read as the Swift type it is mapped to.

use super::*;

/// The configuration mapping the test schema's three custom scalars.
const MAPPED: &str = r#"{
    "identity": {"types": {"Asset": ["uuid"], "Quote": ["base", "quote"]}},
    "customScalarTypes": {
        "Decimal": "Foundation.Decimal",
        "DateTime": "Foundation.Date",
        "Url": "Foundation.URL"
    }
}"#;

/// The messages compiling `QUERY` fails with under the given mappings.
fn mapping_errors(mappings: &str) -> Vec<String> {
    errors(&format!(r#"{{"customScalarTypes": {mappings}}}"#), QUERY)
}

/// The emitted Swift of `text` under the test mappings, the file of its
/// definitions.
fn emitted_mapped(text: &str) -> String {
    let (sdl, path) = schema();
    let mut config: Config = serde_json::from_str(MAPPED).expect("the configuration parses");
    config.path = PathBuf::from("baton.json");
    let compiled = compile(&sdl, &path, &[], &[document(text)], &config)
        .unwrap_or_else(|errors| panic!("{errors:?}"));
    let output = crate::emit::emit(&compiled.plan).expect("the plan emits");
    output.files.into_values().collect::<Vec<_>>().join("\n")
}

/// The lines of `swift` that declare the accessor `name`.
fn accessor<'a>(swift: &'a str, name: &str) -> Vec<&'a str> {
    let declaration = format!("public var {name}:");
    swift
        .lines()
        .filter(|line| line.contains(&declaration))
        .collect()
}

/// The body of the static function `name` in the lens `lens`, up to its
/// closing brace.
fn function_body(swift: &str, lens: &str, name: &str) -> String {
    let start = swift
        .find(&format!("public struct {lens}:"))
        .unwrap_or_else(|| panic!("no lens {lens} in:\n{swift}"));
    let rest = &swift[start..];
    let function = rest
        .find(&format!("static func {name}("))
        .unwrap_or_else(|| panic!("no {name} in {lens}:\n{rest}"));
    let body = &rest[function..];
    let end = body.find("\n    }").expect("the function closes");
    body[..end].to_string()
}

#[test]
fn a_mapping_of_a_name_the_schema_does_not_declare_is_an_error_pointing_at_the_configuration() {
    let (sdl, path) = schema();
    let mut config: Config =
        serde_json::from_str(r#"{"customScalarTypes": {"Money": "Foundation.Decimal"}}"#)
            .expect("the configuration parses");
    config.path = PathBuf::from("baton.json");
    let diagnostics = compile(&sdl, &path, &[], &[document(QUERY)], &config)
        .err()
        .expect("an undeclared scalar does not compile");
    let messages: Vec<String> = diagnostics
        .iter()
        .map(|diagnostic| diagnostic.message().to_string())
        .collect();
    assert_eq!(
        messages,
        vec!["`customScalarTypes` maps `Money`, which the schema does not declare"]
    );
    assert_eq!(
        diagnostics[0].location().source_location(),
        SourceLocationKey::standalone("baton.json"),
        "the diagnostic points at the configuration file"
    );
}

#[test]
fn a_mapping_of_a_type_that_is_not_a_scalar_is_an_error() {
    assert_eq!(
        mapping_errors(r#"{"Asset": "Foundation.Decimal"}"#),
        vec!["`customScalarTypes` maps `Asset`, which is not a scalar of the schema"]
    );
}

#[test]
fn a_mapping_of_a_built_in_scalar_is_an_error() {
    for scalar in ["Int", "Float", "String", "Boolean", "ID"] {
        assert_eq!(
            mapping_errors(&format!(r#"{{"{scalar}": "Foundation.Decimal"}}"#)),
            vec![format!(
                "`customScalarTypes` maps `{scalar}`, a built-in scalar, which reads as itself"
            )],
            "{scalar}"
        );
    }
}

#[test]
fn a_mapping_to_an_empty_type_is_an_error() {
    for swift_type in ["", "  "] {
        assert_eq!(
            mapping_errors(&format!(r#"{{"Decimal": "{swift_type}"}}"#)),
            vec!["`customScalarTypes` maps `Decimal` to no type: write the Swift type it reads as"],
            "{swift_type:?}"
        );
    }
}

#[test]
fn a_plain_mapped_field_reads_as_an_optional_of_its_type_wherever_the_schema_puts_it() {
    let swift = emitted_mapped("query Probe { assets { price listedAt prices } }");
    assert_eq!(
        accessor(&swift, "price"),
        vec![
            "            @MainActor public var price: Foundation.Decimal? { anchor.mapped(Slots.Asset.price) }"
        ]
    );
    assert_eq!(
        accessor(&swift, "listedAt"),
        vec![
            "            @MainActor public var listedAt: Foundation.Date? { anchor.mapped(Slots.Asset.listedAt) }"
        ],
        "the schema's non-null promises the text, not the conversion"
    );
    assert_eq!(
        accessor(&swift, "prices"),
        vec![
            "            @MainActor public var prices: [Foundation.Decimal?]? { anchor.nullableMappedList(Slots.Asset.prices) }"
        ]
    );
    assert!(swift.starts_with("// Generated by batonc. Do not edit.\nimport Foundation\n"));
}

#[test]
fn catch_on_a_mapped_field_is_a_result_of_the_type_when_non_null_and_of_an_optional_otherwise() {
    let swift = emitted_mapped(
        "fragment Probe_asset on Asset { price @catch listedAt @catch }
         query Probe { assets { ...Probe_asset } }",
    );
    assert_eq!(
        accessor(&swift, "listedAt"),
        vec![
            r#"    @MainActor public var listedAt: Result<Foundation.Date, Baton.FieldErrors> { anchor.caughtMapped(Slots.Asset.listedAt, path: "listedAt") }"#
        ]
    );
    assert_eq!(
        accessor(&swift, "price"),
        vec![
            r#"    @MainActor public var price: Result<Foundation.Decimal?, Baton.FieldErrors> { anchor.caughtOptionalMapped(Slots.Asset.price, path: "price") }"#
        ]
    );
}

#[test]
fn required_and_throw_on_field_error_make_a_mapped_field_a_throwing_getter_of_its_type() {
    let swift = emitted_mapped(
        "fragment Probe_asset on Asset { price @required(action: LOG) }
         fragment Strict_asset on Asset @throwOnFieldError { listedAt page prices }
         query Probe { assets { ...Probe_asset ...Strict_asset } }",
    );
    assert_eq!(
        accessor(&swift, "price"),
        vec![
            r#"    @MainActor public var price: Foundation.Decimal { get throws { try anchor.throwingMapped(Slots.Asset.price, path: "price") } }"#
        ]
    );
    assert_eq!(
        accessor(&swift, "listedAt"),
        vec![
            r#"    @MainActor public var listedAt: Foundation.Date { get throws { try anchor.throwingMapped(Slots.Asset.listedAt, path: "listedAt") } }"#
        ]
    );
}

#[test]
fn throw_on_field_error_keeps_a_schema_nullable_mapped_field_optional() {
    let swift = emitted_mapped(
        "fragment Strict_asset on Asset @throwOnFieldError { listedAt page prices }
         query Probe { assets { ...Strict_asset } }",
    );
    assert_eq!(
        accessor(&swift, "page"),
        vec!["    @MainActor public var page: Foundation.URL? { anchor.mapped(Slots.Asset.page) }"],
        "a null is data, not an error"
    );
    assert_eq!(
        accessor(&swift, "prices"),
        vec![
            "    @MainActor public var prices: [Foundation.Decimal?]? { anchor.nullableMappedList(Slots.Asset.prices) }"
        ]
    );
}

#[test]
fn a_required_none_mapped_field_is_satisfied_only_when_its_text_converts() {
    let swift = emitted_mapped(
        "fragment Probe_asset on Asset { price @required(action: NONE) }
         query Probe { assets { ...Probe_asset } }",
    );
    let satisfied = function_body(&swift, "Probe_asset", "satisfied");
    assert!(
        satisfied.contains(
            r#"guard anchor.converts(Slots.Asset.price, to: Foundation.Decimal.self, path: "price", log: false) else { return false }"#
        ),
        "{satisfied}"
    );
    assert!(!satisfied.contains("hasValue("), "{satisfied}");
}

#[test]
fn field_errors_collect_a_single_mapped_value_s_conversion_and_not_a_list_s() {
    let swift = emitted_mapped(
        "fragment Probe_asset on Asset @throwOnFieldError { price prices }
         query Probe { assets { ...Probe_asset } }",
    );
    let field_errors = function_body(&swift, "Probe_asset", "fieldErrors");
    assert!(
        field_errors.contains(
            r#"anchor.collectConversion(Slots.Asset.price, to: Foundation.Decimal.self, path: "price", into: &errors)"#
        ),
        "{field_errors}"
    );
    assert!(
        !field_errors.contains("collectConversion(Slots.Asset.prices"),
        "a list leaves out what does not convert: {field_errors}"
    );
    assert!(
        field_errors.contains("anchor.collectError(Slots.Asset.prices, into: &errors)"),
        "{field_errors}"
    );
}

#[test]
fn a_variable_of_a_mapped_scalar_is_typed_as_the_mapped_type() {
    let swift = emitted_mapped(
        "query Probe($price: Decimal!, $among: [Decimal!]) { assetsPricedAbove(price: $price, among: $among) { uuid } }",
    );
    assert!(
        swift.contains("    public var price: Foundation.Decimal\n"),
        "{swift}"
    );
    assert!(
        swift.contains("    public var among: [Foundation.Decimal]?\n"),
        "{swift}"
    );
    assert!(
        swift.contains(r#""price": Baton.Variable(self.price)"#),
        "{swift}"
    );
}

#[test]
fn an_unmapped_custom_scalar_still_reads_as_a_string() {
    let swift = emitted_mapped("query Probe { tokenizer { json } }");
    assert!(
        swift.contains("public var json: String? { anchor.string("),
        "{swift}"
    );
}
