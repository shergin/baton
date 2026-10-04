//! Tests of the names generated Swift declares: the names nested types are
//! kept off, and the allocator that gives each declaration of a scope its
//! own.

use super::*;

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
        "Result",
        "Optional",
        "String",
        "Int",
        "Double",
        "Bool",
    ];
    let lenses = Reserved::lenses([]);
    for name in reserved {
        assert_eq!(lenses.type_name(&lower_camel(name)), format!("{name}Lens"));
        assert_eq!(lenses.type_name(name), format!("{name}Lens"));
    }
    assert_eq!(lenses.type_name("owner"), "Owner");
    assert_eq!(lenses.type_name("typesLens"), "TypesLens");
}

#[test]
fn a_nested_lens_is_never_named_like_a_fragment_or_operation_of_the_program() {
    let lenses = Reserved::lenses(["TestNotes_character", "TestNotesRefetchQuery"]);
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
    let builders = Reserved::builders();
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
fn a_name_the_scope_has_is_numbered_and_one_reserved_takes_the_suffix_first() {
    let lenses = Reserved::lenses(["Notes"]);
    let mut scope = Scope::new("Lens", &lenses);
    scope.declare("Origin", Kind::Instance, "the field `Origin`");
    assert_eq!(
        scope.nested_type("origin", "the lens of `origin`"),
        "Origin2"
    );
    assert_eq!(
        scope.nested_type("origin", "the lens of `origin`"),
        "Origin3"
    );
    assert_eq!(
        scope.nested_type("notes", "the lens of `notes`"),
        "NotesLens"
    );
    assert_eq!(
        scope.nested_type("notesLens", "the lens of `notesLens`"),
        "NotesLens2"
    );
    assert!(scope.finish().is_empty());
}

#[test]
fn a_derived_member_takes_the_first_free_candidate_and_numbers_the_last() {
    let none = Reserved::none();
    let mut scope = Scope::new("Lens", &none);
    scope.declare("testNotes", Kind::Instance, "the field `testNotes`");
    let candidates = ["testNotes".to_string(), "testNotes_character".to_string()];
    assert_eq!(
        scope.member(&candidates, Kind::Instance, "the spread"),
        "testNotes_character"
    );
    assert_eq!(
        scope.member(&candidates, Kind::Instance, "the spread again"),
        "testNotes_character2"
    );
    // A static member of the name is no obstacle: Swift tells them apart.
    scope.declare("satisfied", Kind::Static, "the check");
    assert_eq!(
        scope.member(&["satisfied".to_string()], Kind::Instance, "the field"),
        "satisfied"
    );
    assert!(scope.finish().is_empty());
}

#[test]
fn a_type_condition_numbers_its_accessor_and_its_lens_together() {
    let lenses = Reserved::lenses([]);
    let mut scope = Scope::new("Lens", &lenses);
    scope.declare("asCharacter", Kind::Instance, "the field `asCharacter`");
    assert_eq!(
        scope.member_and_type("asCharacter", "AsCharacter", "the type condition"),
        ("asCharacter2".to_string(), "AsCharacter2".to_string())
    );
    assert_eq!(
        scope.member_and_type("asLocation", "AsLocation", "another"),
        ("asLocation".to_string(), "AsLocation".to_string())
    );
    assert!(scope.finish().is_empty());
}

#[test]
fn a_name_declared_twice_is_reported_with_both_declarations() {
    let none = Reserved::none();
    let mut scope = Scope::new("TestQuery", &none);
    scope.declare("variables", Kind::Instance, "the variable `$variables`");
    scope.declare("variables", Kind::Instance, "the operation's variables");
    scope.declare("Data", Kind::Type, "the operation's root lens");
    scope.declare("Data", Kind::Instance, "the variable `$Data`");
    let duplicates: Vec<String> = scope.finish().iter().map(ToString::to_string).collect();
    assert_eq!(
        duplicates,
        [
            "internal error: `TestQuery` would declare `variables` twice, as the variable `$variables` and as the operation's variables; please report it",
            "internal error: `TestQuery` would declare `Data` twice, as the operation's root lens and as the variable `$Data`; please report it",
        ]
    );
}
