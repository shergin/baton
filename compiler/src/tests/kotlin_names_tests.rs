//! Tests of names in generated Kotlin: what a keyword becomes in each
//! position, what the shared objects, an input object and an enum keep, and
//! the clash a variable named like a member of its operation's class is.

use std::path::{Path, PathBuf};

use super::*;
use crate::documents::Document;
use crate::naming::NameError;
use crate::pipeline;

/// The names `text`, one operation compiled against the test schema, would
/// declare twice in `naming`'s generated code.
fn clashes(text: &str, naming: &dyn Naming) -> Vec<String> {
    let schema_path = Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("the compiler sits one level below the repository root")
        .join("spec/tests/schema.graphql");
    let schema = std::fs::read_to_string(&schema_path).expect("the test schema is readable");
    let document = Document {
        path: PathBuf::from("Probe.kt"),
        index: 0,
        start: crate::documents::Position { line: 1, column: 1 },
        text: text.to_string(),
        embedded: None,
    };
    let compiled = pipeline::compile(
        &schema,
        &schema_path.to_string_lossy(),
        &[],
        &[document],
        &Config::default(),
    )
    .unwrap_or_else(|errors| panic!("the document does not compile: {errors:?}"));
    match crate::decide::program(&compiled.plan, naming) {
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

#[test]
fn a_hard_keyword_is_written_in_backticks_and_a_soft_one_is_not() {
    assert_eq!(escape("in"), "`in`");
    assert_eq!(escape("object"), "`object`");
    assert_eq!(escape("typeof"), "`typeof`");
    assert_eq!(escape("data"), "data");
    assert_eq!(escape("value"), "value");
    assert_eq!(escape("open"), "open");
    assert_eq!(escape("_"), "`_`");
}

#[test]
fn a_soft_keyword_that_starts_a_type_is_written_in_backticks() {
    // `other is suspend` would read `suspend` as the start of a function
    // type, and `QueryOperation<out.Data>` `out` as a variance.
    assert_eq!(escape("suspend"), "`suspend`");
    assert_eq!(escape("out"), "`out`");
    assert_eq!(escape("dynamic"), "`dynamic`");
}

#[test]
fn a_shared_constant_named_like_a_keyword_or_what_its_object_spells_takes_an_underscore() {
    assert_eq!(type_constant("Character"), "Character");
    assert_eq!(type_constant("in"), "in_");
    assert_eq!(type_constant("Registry"), "Registry_");
    assert_eq!(type_constant("format"), "format_");
    assert_eq!(type_constant("Registry_"), "Registry__");
    assert_eq!(type_constant("Types"), "Types");
    assert_eq!(slot_name("Types"), "Types_");
    assert_eq!(slot_name("class"), "class_");
    assert_eq!(slot_name("name"), "name");
}

#[test]
fn an_input_field_named_like_what_its_data_class_declares_takes_an_underscore() {
    assert_eq!(input_field_name("variable"), "variable_");
    assert_eq!(input_field_name("Variable"), "Variable_");
    assert_eq!(input_field_name("copy"), "copy_");
    assert_eq!(input_field_name("component2"), "component2_");
    assert_eq!(input_field_name("componentName"), "componentName");
    assert_eq!(input_field_name("in"), "`in`");
    assert_eq!(input_field_name("name"), "name");
}

#[test]
fn an_enum_value_named_like_its_interface_or_its_undeclared_case_in_any_case_takes_an_underscore() {
    assert_eq!(enum_value_name("ALIVE", "Status"), "ALIVE");
    assert_eq!(enum_value_name("UNKNOWN", "Status"), "UNKNOWN");
    assert_eq!(enum_value_name("Unknown", "Status"), "Unknown");
    assert_eq!(enum_value_name("Undeclared", "Status"), "Undeclared_");
    assert_eq!(enum_value_name("UNDECLARED", "Status"), "UNDECLARED_");
    assert_eq!(enum_value_name("undeclared_", "Status"), "undeclared__");
    assert_eq!(enum_value_name("Status", "Status"), "Status_");
    assert_eq!(enum_value_name("String", "Status"), "String_");
    assert_eq!(enum_value_name("in", "Status"), "`in`");
}

#[test]
fn a_schema_type_named_like_what_the_package_keeps_takes_a_suffix() {
    assert_eq!(enum_type_name("Status"), "Status");
    assert_eq!(enum_type_name("Plan"), "PlanEnum");
    assert_eq!(enum_type_name("String"), "StringEnum");
    assert_eq!(input_type_name("Types"), "TypesInput");
    assert_eq!(input_type_name("FilterCharacter"), "FilterCharacter");
}

#[test]
fn a_variable_named_like_what_its_class_declares_is_an_error_in_the_generated_kotlin() {
    let text = "query Probe($type: ID!) { character(id: $type) { id } }";
    assert_eq!(
        clashes(text, &KotlinNaming::default()),
        [
            "the variable `$type` clashes with the operation's `type` in the generated Kotlin; rename the variable"
        ]
    );
    assert!(clashes(text, &crate::names::SwiftNaming::default()).is_empty());
}

#[test]
fn a_variable_named_like_a_runtime_type_the_class_spells_is_an_error() {
    let text = "query Probe($Variable: ID!) { character(id: $Variable) { id } }";
    assert_eq!(
        clashes(text, &KotlinNaming::default()),
        [
            "the variable `$Variable` clashes with the runtime's `Variable` in the generated Kotlin; rename the variable"
        ]
    );
}

#[test]
fn a_variable_named_like_a_swift_member_is_free_in_kotlin() {
    let text = "query Probe($hashValue: ID!, $isStale: ID!) { a: character(id: $hashValue) { id } b: character(id: $isStale) { id } }";
    assert!(clashes(text, &KotlinNaming::default()).is_empty());
}

#[test]
fn a_mutation_has_no_resolution_to_clash_with() {
    let text = "mutation Probe($resolution: ID!) { setFavorite(id: $resolution, favorite: true) { character { id } } }";
    assert!(clashes(text, &KotlinNaming::default()).is_empty());
}
