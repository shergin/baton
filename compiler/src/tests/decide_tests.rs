//! Tests of the decide pass: documents compiled against the test schema, and
//! the variants and guards their normalization comes to.

use std::path::{Path, PathBuf};

use super::*;
use crate::config::Config;
use crate::documents::Document;
use crate::pipeline;

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
            (None, vec!["__typename".into()], vec!["__typename".into()]),
        ],
        "Relay's __isNode is dropped, __typename leads, and the alias keys each type's own field"
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
    assert_eq!(any(vec![vec![x.clone()], vec![x.clone()]]), vec![vec![x]]);
}
