//! Tests of the allocator that gives each declaration of a scope its own
//! name, with Swift's names.

use super::*;
use crate::names::SwiftNaming;

/// Swift's names, with no mapped scalars.
fn swift() -> SwiftNaming {
    SwiftNaming::default()
}

#[test]
fn a_name_the_scope_has_is_numbered_and_one_reserved_takes_the_suffix_first() {
    let lenses = Reserved::new(&swift(), Position::Lens, ["Notes"]);
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
    let none = Reserved::none(&swift());
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
    let lenses = Reserved::new(&swift(), Position::Lens, [] as [&str; 0]);
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
fn a_name_the_compiler_chose_twice_is_an_internal_error_naming_both() {
    let none = Reserved::none(&swift());
    let mut scope = Scope::new("TestQuery", &none);
    scope.declare("variables", Kind::Instance, "the operation's `variables`");
    scope.declare("variables", Kind::Instance, "the builder's `variables`");
    scope.declare("Data", Kind::Type, "the operation's root lens `Data`");
    scope.declare("Data", Kind::Static, "the plan's `Data`");
    let errors: Vec<String> = scope.finish().iter().map(ToString::to_string).collect();
    assert_eq!(
        errors,
        [
            "internal error: `TestQuery` would declare `variables` twice, as the operation's `variables` and as the builder's `variables`; please report it",
            "internal error: `TestQuery` would declare `Data` twice, as the operation's root lens `Data` and as the plan's `Data`; please report it",
        ]
    );
}

#[test]
fn a_name_the_document_chose_that_another_declaration_takes_is_a_clash_at_the_name() {
    let written = |offset, remedy| {
        Some(Written {
            origin: Origin {
                path: "Probe.swift".to_string(),
                document: 0,
                offset,
            },
            remedy,
        })
    };
    let none = Reserved::none(&swift());
    let mut scope = Scope::new("TestQuery", &none);
    scope.declare_written(
        "variables",
        Kind::Instance,
        "the variable `$variables`",
        written(12, "rename the variable"),
    );
    scope.declare("variables", Kind::Instance, "the operation's `variables`");
    scope.declare("Data", Kind::Type, "the operation's root lens `Data`");
    scope.declare_written(
        "Data",
        Kind::Instance,
        "the variable `$Data`",
        written(30, "rename the variable"),
    );
    // Two names the document chose: the clash is at the second.
    scope.declare_written(
        "name",
        Kind::Instance,
        "the field `name`",
        written(40, "alias the field"),
    );
    scope.declare_written(
        "name",
        Kind::Instance,
        "the selection aliased `name`",
        written(50, "choose another alias"),
    );
    let clashes: Vec<(u32, String)> = scope
        .finish()
        .into_iter()
        .map(|error| match error {
            NameError::Clash(clash) => (clash.origin.offset, clash.to_string()),
            NameError::Duplicate(duplicate) => panic!("{duplicate}"),
        })
        .collect();
    assert_eq!(
        clashes,
        [
            (
                12,
                "the variable `$variables` clashes with the operation's `variables` in the generated Swift; rename the variable".to_string()
            ),
            (
                30,
                "the variable `$Data` clashes with the operation's root lens `Data` in the generated Swift; rename the variable".to_string()
            ),
            (
                50,
                "the selection aliased `name` clashes with the field `name`; choose another alias".to_string()
            ),
        ]
    );
}
