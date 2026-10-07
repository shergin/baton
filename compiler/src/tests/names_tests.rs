//! Tests of the names generated Swift declares: the names nested types are
//! kept off, and the identifiers a document's names become.

use super::*;
use crate::naming::{Position, Reserved, capitalize};

#[test]
fn a_nested_lens_is_never_named_like_what_a_lens_spells_unqualified_or_a_swift_keyword() {
    // Spelled out rather than read from the list, so that a name dropped
    // from it fails here.
    let reserved = [
        "Type",
        "Self",
        "Protocol",
        "Any",
        "MainActor",
        "Baton",
        "Types",
        "Slots",
        "AbstractSlots",
        "Sites",
        "Guards",
        "Result",
        "Optional",
        "String",
        "Int",
        "Double",
        "Bool",
    ];
    let lenses = Reserved::new(&SwiftNaming::default(), Position::Lens, [] as [&str; 0]);
    for name in reserved {
        assert_eq!(lenses.type_name(&lower_camel(name)), format!("{name}Lens"));
        assert_eq!(lenses.type_name(name), format!("{name}Lens"));
    }
    assert_eq!(lenses.type_name("owner"), "Owner");
    assert_eq!(lenses.type_name("typesLens"), "TypesLens");
}

#[test]
fn a_nested_lens_is_never_named_like_a_fragment_or_operation_of_the_program() {
    let lenses = Reserved::new(
        &SwiftNaming::default(),
        Position::Lens,
        ["TestNotes_character", "TestNotesRefetchQuery"],
    );
    assert_eq!(
        lenses.type_name("testNotes_character"),
        "TestNotes_characterLens"
    );
    assert_eq!(
        lenses.type_name("testNotesRefetchQuery"),
        "TestNotesRefetchQueryLens"
    );
    assert_eq!(lenses.type_name("testNotes"), "TestNotes");
}

#[test]
fn a_nested_builder_is_never_named_like_what_a_builder_spells_or_a_swift_keyword() {
    let builders = Reserved::new(&SwiftNaming::default(), Position::Builder, [] as [&str; 0]);
    for name in [
        "type", "self", "string", "sendable", "int", "double", "bool", "baton",
    ] {
        assert_eq!(
            builders.type_name(name),
            format!("{}Response", capitalize(name))
        );
    }
    assert_eq!(builders.type_name("result"), "Result");
    assert_eq!(builders.type_name("character"), "Character");
}

#[test]
fn a_call_site_label_is_escaped_only_where_swift_requires_it() {
    assert_eq!(call_label("self"), "self");
    assert_eq!(call_label("where"), "where");
    assert_eq!(call_label("in"), "in");
    assert_eq!(call_label("var"), "var");
    assert_eq!(call_label("let"), "let");
    assert_eq!(call_label("inout"), "`inout`");
    // A bare `_` is no label: the argument would go to an unlabelled
    // parameter.
    assert_eq!(call_label("_"), "`_`");
}

#[test]
fn an_enum_value_is_its_case_escaped_and_unknown_takes_an_underscore() {
    assert_eq!(enum_case_name("ALIVE"), "ALIVE");
    assert_eq!(enum_case_name("UNKNOWN"), "UNKNOWN");
    assert_eq!(
        enum_case_name("unknown"),
        "unknown_",
        "the case for a value the build does not know is `unknown`"
    );
    assert_eq!(enum_case_name("default"), "`default`");
    assert_eq!(enum_case_name("self"), "`self`");
    assert_eq!(enum_case_name("Type"), "`Type`");
}

#[test]
fn an_enum_named_like_what_the_module_keeps_or_the_standard_library_takes_enum_after_its_name() {
    assert_eq!(enum_type_name("Status"), "Status");
    for name in [
        "Types",
        "Slots",
        "Sites",
        "Guards",
        "AbstractSlots",
        "Baton",
        "Swift",
        "Foundation",
        "Data",
        "Action",
        "OptimisticResponse",
    ] {
        assert_eq!(enum_type_name(name), format!("{name}Enum"));
    }
    for name in ["Result", "Optional", "String", "Hasher"] {
        assert_eq!(enum_type_name(name), format!("{name}Enum"));
    }
    assert_eq!(enum_type_name("Self"), "SelfEnum");
    assert_eq!(enum_type_name("class"), "`class`");
}
