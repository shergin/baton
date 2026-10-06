//! Tests of the decide pass: documents compiled against the test schema, the
//! variants and guards their normalization comes to, and what the store
//! keeps a scalar as.

use std::path::{Path, PathBuf};

use super::*;
use crate::config::Config;
use crate::documents::Document;
use crate::pipeline::{self, TypeKind, TypePlan};

/// The normalization of the one operation in `text`.
fn decided(text: &str) -> NormalizationSelection {
    let schema_path = Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("the compiler sits one level below the repository root")
        .join("spec/tests/schema.graphql");
    let schema = std::fs::read_to_string(&schema_path).expect("the test schema is readable");
    let document = Document {
        path: PathBuf::from("Decide.swift"),
        index: 0,
        start: crate::swift::Position { line: 1, column: 1 },
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
    let operation = &compiled.plan.operations[0];
    normalization(&operation.root_type, &operation.normalization)
}

/// The child selection of the root field at `index`.
fn child(selection: &NormalizationSelection, index: usize) -> &NormalizationSelection {
    match &selection.variants[0].fields[index].kind {
        NormalizationKind::Linked { selection, .. } => selection,
        NormalizationKind::Scalar { .. } => panic!("field {index} is a scalar"),
    }
}

fn keys(fields: &[NormalizationField]) -> Vec<String> {
    fields
        .iter()
        .map(|field| field.response_key.clone())
        .collect()
}

fn storage_names(fields: &[NormalizationField]) -> Vec<String> {
    fields.iter().map(|field| field.key.name.clone()).collect()
}

/// A variant as its types, its response keys and its storage key names.
type Shape = (Option<Vec<String>>, Vec<String>, Vec<String>);

#[test]
fn a_union_reads_each_member_by_its_own_fields_and_one_alias_by_each_type_s_key() {
    let root = decided(
        "query Probe { search(name: \"a\") { __typename ... on Character { label: name } ... on Location { label: dimension } ... on Node { id } } }",
    );
    let search = child(&root, 0);
    assert!(search.is_abstract);
    let variants: Vec<Shape> = search
        .variants
        .iter()
        .map(|variant| {
            (
                variant.types.clone(),
                keys(&variant.fields),
                storage_names(&variant.fields),
            )
        })
        .collect();
    assert_eq!(
        variants,
        vec![
            (
                Some(vec!["Character".into()]),
                vec!["__typename".into(), "label".into(), "id".into()],
                vec!["__typename".into(), "name".into(), "id".into()]
            ),
            (
                Some(vec!["Episode".into()]),
                vec!["__typename".into(), "id".into()],
                vec!["__typename".into(), "id".into()]
            ),
            (
                Some(vec!["Location".into()]),
                vec!["__typename".into(), "label".into(), "id".into()],
                vec!["__typename".into(), "dimension".into(), "id".into()]
            ),
            (
                None,
                vec!["__typename".into(), "id".into()],
                vec!["__typename".into(), "id".into()]
            ),
            (None, vec!["__typename".into()], vec!["__typename".into()]),
        ],
        "Relay's __isNode is dropped from the fields, __typename leads, the alias keys each type's own field, and Node has a variant for a type the build did not list"
    );
}

#[test]
fn implementers_that_read_only_the_interface_s_own_fields_share_the_variant_for_every_other_type() {
    let root = decided(
        "query Probe($id: ID!) { node(id: $id) { id ... on Character { name } ... on Episode { name } } }",
    );
    let node = child(&root, 0);
    assert_eq!(node.variants.len(), 2);
    assert_eq!(
        node.variants[0].types,
        Some(vec!["Character".into(), "Episode".into()])
    );
    assert_eq!(
        keys(&node.variants[0].fields),
        vec!["__typename", "id", "name"]
    );
    assert_eq!(node.variants[1].types, None);
    assert_eq!(keys(&node.variants[1].fields), vec!["__typename", "id"]);
}

#[test]
fn include_and_skip_become_guards_and_a_field_selected_twice_is_one_field_selected_when_either_holds()
 {
    let root = decided(
        "query Probe($x: Boolean!, $y: Boolean!, $id: ID!) { character(id: $id) { origin { id } origin @include(if: $x) { name } name @skip(if: $y) ... @include(if: $x) { status } } }",
    );
    let character = child(&root, 0);
    let fields = &character.variants[0].fields;
    assert_eq!(keys(fields), vec!["origin", "id", "status", "name"]);
    let guard = |variable: &str, passing: bool| Guard {
        variable: variable.to_string(),
        passing,
    };
    assert!(fields[0].guards.is_empty(), "origin is always fetched");
    assert_eq!(fields[2].guards, vec![vec![guard("x", true)]]);
    assert_eq!(fields[3].guards, vec![vec![guard("y", false)]]);
    let NormalizationKind::Linked {
        selection: origin, ..
    } = &fields[0].kind
    else {
        panic!("origin is a link");
    };
    let origin_fields = &origin.variants[0].fields;
    assert_eq!(keys(origin_fields), vec!["id", "name"]);
    assert!(
        origin_fields[0].guards.is_empty(),
        "id comes with every origin"
    );
    assert_eq!(
        origin_fields[1].guards,
        vec![vec![guard("x", true)]],
        "name only with the conditional one"
    );
}

#[test]
fn guards_that_hold_together_simplify_and_contradictions_drop() {
    let x = Guard {
        variable: "x".into(),
        passing: true,
    };
    let not_x = Guard {
        variable: "x".into(),
        passing: false,
    };
    assert_eq!(any(vec![vec![x.clone()], vec![]]), Vec::<Vec<Guard>>::new());
    assert_eq!(
        any(vec![vec![x.clone(), not_x.clone()], vec![x.clone()]]),
        vec![vec![x.clone()]]
    );
    assert_eq!(
        any(vec![vec![x.clone()], vec![x.clone()]]),
        vec![vec![x.clone()]]
    );
    assert_eq!(
        any(vec![vec![not_x.clone(), x.clone()]]),
        vec![vec![not_x, x]],
        "a field no variables select keeps a guard none pass, not none"
    );
}

#[test]
fn a_field_selected_twice_under_different_conditions_is_selected_when_either_holds() {
    let root = decided(
        "query Probe($x: Boolean!, $y: Boolean!, $id: ID!) { character(id: $id) { name @include(if: $x) name @include(if: $y) origin @include(if: $x) { name } origin @include(if: $y) { id } } }",
    );
    let fields = &child(&root, 0).variants[0].fields;
    assert_eq!(keys(fields), vec!["name", "origin", "id"]);
    let guard = |variable: &str| {
        vec![Guard {
            variable: variable.to_string(),
            passing: true,
        }]
    };
    assert_eq!(fields[0].guards, vec![guard("x"), guard("y")]);
    assert_eq!(fields[1].guards, vec![guard("x"), guard("y")]);
    let NormalizationKind::Linked {
        selection: origin, ..
    } = &fields[1].kind
    else {
        panic!("origin is a link");
    };
    let origin_fields = &origin.variants[0].fields;
    assert_eq!(keys(origin_fields), vec!["name", "id"]);
    assert_eq!(origin_fields[0].guards, vec![guard("x")]);
    assert_eq!(
        origin_fields[1].guards,
        vec![guard("x"), guard("y")],
        "Relay adds the id to both"
    );
}

#[test]
fn a_field_under_a_condition_and_its_negation_is_fetched_by_no_variables() {
    let root = decided(
        "query Probe($x: Boolean!, $id: ID!) { character(id: $id) { name species @include(if: $x) @skip(if: $x) } }",
    );
    let fields = &child(&root, 0).variants[0].fields;
    let species = fields
        .iter()
        .find(|field| field.response_key == "species")
        .expect("species is in the plan");
    assert_eq!(species.guards.len(), 1);
    assert!(
        species.guards[0].len() == 2,
        "one conjunction that no value of $x passes"
    );
}

#[test]
fn a_field_the_initial_part_selects_goes_before_its_deferred_copy() {
    let root = decided(
        "query Probe($id: ID!) { character(id: $id) { ...ProbeDeferOrigin_character @defer(label: \"later\") origin { id dimension } } } fragment ProbeDeferOrigin_character on Character { origin { name } }",
    );
    let fields = &child(&root, 0).variants[0].fields;
    let origins: Vec<Option<&str>> = fields
        .iter()
        .filter(|field| field.response_key == "origin")
        .map(|field| field.deferred.as_deref())
        .collect();
    assert_eq!(origins, vec![None, Some("Probe$defer$later")]);
}

/// A named type of `kind`, nullable.
fn named(kind: TypeKind) -> TypePlan {
    TypePlan::Named {
        name: format!("{kind:?}"),
        kind,
        non_null: false,
        mapped: None,
    }
}

/// A nullable list of `element`.
fn list_of(element: TypePlan) -> TypePlan {
    TypePlan::List {
        element: Box::new(element),
        non_null: false,
    }
}

/// `type_` made non-null.
fn non_null(type_: TypePlan) -> TypePlan {
    match type_ {
        TypePlan::Named {
            name, kind, mapped, ..
        } => TypePlan::Named {
            name,
            kind,
            non_null: true,
            mapped,
        },
        TypePlan::List { element, .. } => TypePlan::List {
            element,
            non_null: true,
        },
    }
}

#[test]
fn an_id_and_an_unmapped_custom_scalar_are_kept_as_their_text() {
    for kind in [TypeKind::String, TypeKind::Id, TypeKind::CustomScalar] {
        assert_eq!(
            ScalarShape::of(&named(kind)).primitive,
            Primitive::String,
            "{kind:?}"
        );
    }
}

#[test]
fn an_enum_reads_as_the_enum_its_schema_type_names() {
    let status = TypePlan::Named {
        name: "Status".to_string(),
        kind: TypeKind::Enum,
        non_null: false,
        mapped: None,
    };
    assert_eq!(
        ScalarShape::of(&status).primitive,
        Primitive::Enum("Status".to_string())
    );
    assert_eq!(
        ScalarShape::of(&list_of(status)).primitive,
        Primitive::Enum("Status".to_string())
    );
}

#[test]
fn a_float_is_kept_as_a_double_a_boolean_as_a_bool_and_an_int_as_an_int() {
    assert_eq!(
        ScalarShape::of(&named(TypeKind::Float)).primitive,
        Primitive::Double
    );
    assert_eq!(
        ScalarShape::of(&named(TypeKind::Boolean)).primitive,
        Primitive::Bool
    );
    assert_eq!(
        ScalarShape::of(&named(TypeKind::Int)).primitive,
        Primitive::Int
    );
}

/// Whether a scalar shape is a list, and if so whether its elements are
/// non-null.
fn elements_non_null(shape: ScalarShape) -> Option<bool> {
    shape.list.map(|list| list.non_null)
}

#[test]
fn a_scalar_shape_is_a_list_exactly_when_its_field_is() {
    let float_list = ScalarShape::of(&list_of(named(TypeKind::Float)));
    assert_eq!(float_list.primitive, Primitive::Double);
    assert_eq!(elements_non_null(float_list), Some(false));
    let id_list = ScalarShape::of(&non_null(list_of(non_null(named(TypeKind::Id)))));
    assert_eq!(id_list.primitive, Primitive::String);
    assert_eq!(elements_non_null(id_list), Some(true));
    let id = ScalarShape::of(&non_null(named(TypeKind::Id)));
    assert_eq!(id.primitive, Primitive::String);
    assert_eq!(elements_non_null(id), None);
}

#[test]
fn a_list_shape_follows_its_elements_nullability_not_its_own() {
    let shapes = [
        (list_of(named(TypeKind::String)), false),
        (non_null(list_of(named(TypeKind::String))), false),
        (list_of(non_null(named(TypeKind::String))), true),
        (non_null(list_of(non_null(named(TypeKind::String)))), true),
    ];
    for (type_, expected) in shapes {
        assert_eq!(
            elements_non_null(ScalarShape::of(&type_)),
            Some(expected),
            "{type_:?}"
        );
    }
}

/// The slot of the field stored under `name` among `fields`, as the
/// generated code refers to it on `type_name`.
fn slot_of(type_name: &str, fields: &[NormalizationField], name: &str) -> SlotRef {
    let field = fields
        .iter()
        .find(|field| field.key.name == name)
        .unwrap_or_else(|| panic!("no field is stored under `{name}`"));
    SlotRef::new(type_name, &field.key)
}

#[test]
fn a_key_leaves_out_an_argument_whose_constant_is_null() {
    let root = decided(
        "query Probe { character(id: \"1\") { notes(after: null, first: 2) { edges { cursor } } } }",
    );
    let slot = slot_of("Character", &child(&root, 0).variants[0].fields, "notes");
    assert_eq!(slot.template, "notes(first:2)");
    assert!(slot.has_arguments);
    assert_eq!(
        slot.arguments,
        vec![keys::KeyArgument {
            name: "first".into(),
            value: vec![KeyPart::Literal("2".into())],
        }]
    );
}

#[test]
fn a_key_whose_every_argument_is_a_null_constant_is_the_field_name_alone() {
    let root = decided("query Probe { characters(filter: null) { info { count } } }");
    let slot = slot_of("Query", &root.variants[0].fields, "characters");
    assert_eq!(slot.template, "characters");
    assert!(!slot.has_arguments);
    assert!(slot.arguments.is_empty());
    assert_eq!(slot.member(), "characters");
}

#[test]
fn a_variable_argument_stays_in_the_key_as_a_variable_part() {
    let root = decided(
        "query Probe($after: String) { character(id: \"1\") { notes(after: $after, first: 2) { edges { cursor } } } }",
    );
    let slot = slot_of("Character", &child(&root, 0).variants[0].fields, "notes");
    assert_eq!(slot.template, "notes(after:$after,first:2)");
    assert!(slot.has_variables());
    assert_eq!(
        slot.arguments,
        vec![
            keys::KeyArgument {
                name: "after".into(),
                value: vec![KeyPart::Variable("after".into())],
            },
            keys::KeyArgument {
                name: "first".into(),
                value: vec![KeyPart::Literal("2".into())],
            },
        ]
    );
}

#[test]
fn a_null_inside_an_object_argument_stays_in_its_literal() {
    let root = decided("query Probe { characters(filter: {name: null}) { info { count } } }");
    let slot = slot_of("Query", &root.variants[0].fields, "characters");
    assert_eq!(slot.template, "characters(filter:{\"name\":null})");
    assert_eq!(
        slot.arguments,
        vec![keys::KeyArgument {
            name: "filter".into(),
            value: vec![KeyPart::Literal("{\"name\":null}".into())],
        }]
    );
}

/// A variant as its condition and its response keys.
fn conditioned(selection: &NormalizationSelection) -> Vec<(Option<String>, Vec<String>)> {
    selection
        .variants
        .iter()
        .filter(|variant| variant.types.is_none())
        .map(|variant| (variant.condition.clone(), keys(&variant.fields)))
        .collect()
}

#[test]
fn an_interface_several_types_satisfy_decides_a_variant_and_a_membership_and_a_concrete_type_neither()
 {
    let root = decided(
        "query Probe { search(name: \"a\") { __typename ... on Named { name } ... on Character { status } } }",
    );
    let search = child(&root, 0);
    assert_eq!(
        conditioned(search),
        vec![
            (
                Some("Named".to_string()),
                vec!["__typename".to_string(), "name".to_string()]
            ),
            (
                Some("Node".to_string()),
                vec!["__typename".to_string(), "id".to_string()]
            ),
            (None, vec!["__typename".to_string()]),
        ],
        "the Named variant carries the shared fields and its own, Relay's Node fragment has its own, the concrete Character has none, and the shared one comes last"
    );
    assert_eq!(
        search.memberships,
        vec![
            ("__isNamed".to_string(), "Named".to_string()),
            ("__isNode".to_string(), "Node".to_string())
        ]
    );
    assert!(
        search
            .variants
            .iter()
            .all(|variant| variant.condition.is_none() || variant.types.is_none()),
        "a condition variant serves no listed types"
    );
}

#[test]
fn a_selection_on_an_object_type_has_no_condition_variants_and_no_memberships() {
    let root = decided("query Probe { character(id: \"1\") { id ... on Named { name } } }");
    let character = child(&root, 0);
    assert!(!character.is_abstract);
    assert!(
        character
            .variants
            .iter()
            .all(|variant| variant.condition.is_none())
    );
    assert!(character.memberships.is_empty());
}

#[test]
fn a_concrete_fragment_inside_a_condition_belongs_to_its_type_and_not_to_the_condition() {
    let root = decided(
        "query Probe { search(name: \"a\") { __typename ... on Named { name ... on Character { status } } } }",
    );
    let search = child(&root, 0);
    assert_eq!(
        conditioned(search),
        vec![
            (
                Some("Named".to_string()),
                vec!["__typename".to_string(), "name".to_string()]
            ),
            (
                Some("Node".to_string()),
                vec!["__typename".to_string(), "id".to_string()]
            ),
            (None, vec!["__typename".to_string()]),
        ],
        "a type the build did not list is no Character, so status is not under Named"
    );
    let character = search
        .variants
        .iter()
        .find(|variant| variant.types.as_deref() == Some(&["Character".to_string()][..]))
        .expect("Character has its own variant");
    assert!(keys(&character.fields).contains(&"status".to_string()));
}

#[test]
fn a_condition_inside_a_concrete_fragment_decides_no_condition_variant_and_no_membership() {
    let root = decided(
        "query Probe { search(name: \"a\") { __typename ... on Character { ... on Named { name } } } }",
    );
    let search = child(&root, 0);
    assert_eq!(
        conditioned(search),
        vec![
            (
                Some("Node".to_string()),
                vec!["__typename".to_string(), "id".to_string()]
            ),
            (None, vec!["__typename".to_string()]),
        ],
        "a type the build did not list is no Character, so nothing under Character is under Named; only Relay's Node fragment has a variant"
    );
    assert_eq!(
        search.memberships,
        vec![("__isNode".to_string(), "Node".to_string())]
    );
}

#[test]
fn an_interface_every_compiled_member_satisfies_decides_a_variant_and_a_membership() {
    let root = decided("query Probe { search(name: \"a\") { __typename ... on Node { id } } }");
    let search = child(&root, 0);
    assert_eq!(
        conditioned(search),
        vec![
            (
                Some("Node".to_string()),
                vec!["__typename".to_string(), "id".to_string()]
            ),
            (None, vec!["__typename".to_string()]),
        ],
        "every compiled member implements Node, which says nothing of a type the build did not list"
    );
    assert_eq!(
        search.memberships,
        vec![("__isNode".to_string(), "Node".to_string())]
    );
}

#[test]
fn a_condition_on_the_parent_type_itself_decides_no_variant_and_no_membership() {
    let root = decided("query Probe($id: ID!) { node(id: $id) { id ... on Node { id } } }");
    let node = child(&root, 0);
    assert!(node.is_abstract);
    assert!(
        node.variants
            .iter()
            .all(|variant| variant.condition.is_none())
    );
    assert!(node.memberships.is_empty());
}
