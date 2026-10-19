//! Tests of what a document may say: directives by place, and one
//! definition of the marker's kind.

use std::path::Path;

use super::*;

fn errors(text: &str, marker: Option<Marker>) -> Vec<String> {
    let key = SourceLocationKey::embedded(&Path::new("Directives.swift").to_string_lossy(), 0);
    let parsed = graphql_syntax::parse_executable(text, key).expect("the document parses");
    check(&parsed.definitions, key, marker)
        .iter()
        .map(|error| error.message().to_string())
        .collect()
}

#[test]
fn the_directives_baton_gives_a_meaning_pass_in_their_places() {
    assert!(
        errors(
            "query Q($x: Boolean!) @throwOnFieldError { a @include(if: $x) @required(action: LOG) { b @catch } ... @defer(label: \"l\") { c } ...F @arguments(n: 1) @alias(as: \"f\") }",
            Some(Marker::Query)
        )
        .is_empty()
    );
    assert!(
        errors(
            "fragment F on T @argumentDefinitions(n: {type: \"Int\"}) @refetchable(queryName: \"FRefetch\") { a }",
            Some(Marker::Fragment)
        )
        .is_empty()
    );
}

#[test]
fn stream_and_stream_connection_on_a_field_pass_the_directive_check() {
    assert!(
        errors(
            "query Q { a @stream(label: \"l\", initialCount: 1) { b } }",
            Some(Marker::Query)
        )
        .is_empty()
    );
    assert!(
        errors(
            "query Q { a(first: 2) @stream_connection(key: \"Q_a\", initial_count: 1) { edges { node { b } } } }",
            Some(Marker::Query)
        )
        .is_empty()
    );
}

#[test]
fn stream_on_a_fragment_spread_is_an_error_at_it() {
    assert_eq!(
        errors(
            "query Q { a { ...F @stream(initialCount: 1) } }",
            Some(Marker::Query)
        )
        .len(),
        1
    );
}

#[test]
fn inline_on_a_fragment_definition_passes_the_directive_check() {
    assert!(errors("fragment F on T @inline { a }", Some(Marker::Fragment)).is_empty());
    assert!(
        errors(
            "fragment F on T @inline @throwOnFieldError @argumentDefinitions(n: {type: \"Int\"}) { a }",
            Some(Marker::Fragment)
        )
        .is_empty()
    );
}

#[test]
fn a_directive_baton_gives_no_meaning_is_an_error_at_it() {
    assert_eq!(
        errors("fragment F on T @no_inline { a }", Some(Marker::Fragment)),
        vec![
            "`@no_inline` on a fragment definition has no meaning in Baton; a fragment definition takes `@argumentDefinitions`, `@refetchable`, `@throwOnFieldError`, `@inline`"
        ]
    );
    assert_eq!(
        errors(
            "query Q { a { ...F @relay(mask: false) } }",
            Some(Marker::Query)
        )
        .len(),
        1
    );
    assert_eq!(
        errors("query Q @raw_response_type { a }", Some(Marker::Query)).len(),
        1
    );
}

#[test]
fn a_query_takes_a_cache_expiration_and_a_mutation_or_a_subscription_does_not() {
    assert!(
        errors(
            "query Q @cacheExpiration(seconds: 30) @throwOnFieldError { a }",
            Some(Marker::Query)
        )
        .is_empty()
    );
    assert_eq!(
        errors(
            "mutation M @cacheExpiration(seconds: 30) { a }",
            Some(Marker::Mutation)
        ),
        vec![
            "`@cacheExpiration` on a mutation has no meaning in Baton; a mutation takes `@throwOnFieldError`, `@deletes`"
        ]
    );
    assert_eq!(
        errors(
            "subscription S @cacheExpiration(seconds: 30) { a }",
            Some(Marker::Subscription)
        ),
        vec![
            "`@cacheExpiration` on a subscription has no meaning in Baton; a subscription takes `@throwOnFieldError`"
        ]
    );
    assert_eq!(
        errors("query Q @live { a }", Some(Marker::Query)),
        vec![
            "`@live` on a query has no meaning in Baton; a query takes `@throwOnFieldError`, `@cacheExpiration`"
        ]
    );
}

#[test]
fn a_mutation_takes_deletes_and_a_query_or_a_subscription_does_not() {
    assert!(
        errors(
            "mutation M($id: ID!) @deletes(type: \"Note\", id: $id) @throwOnFieldError { discardNote(id: $id) { deleted } }",
            Some(Marker::Mutation)
        )
        .is_empty()
    );
    assert!(
        errors(
            "mutation M($id: ID!, $uuid: String!) @deletes(type: \"Note\", id: $id) @deletes(type: \"Asset\", id: $uuid) { discardNote(id: $id) { deleted } discardAsset(uuid: $uuid) { deleted } }",
            Some(Marker::Mutation)
        )
        .is_empty(),
        "the directive repeats, one record each"
    );
    assert_eq!(
        errors(
            "query Q($id: ID!) @deletes(type: \"Note\", id: $id) { node(id: $id) { id } }",
            Some(Marker::Query)
        ),
        vec![
            "`@deletes` on a query has no meaning in Baton; a query takes `@throwOnFieldError`, `@cacheExpiration`"
        ]
    );
    assert_eq!(
        errors(
            "subscription S($id: ID!) @deletes(type: \"Note\", id: $id) { noteAdded(characterId: $id) { character { id } } }",
            Some(Marker::Subscription)
        ),
        vec![
            "`@deletes` on a subscription has no meaning in Baton; a subscription takes `@throwOnFieldError`"
        ]
    );
}

#[test]
fn deletes_on_a_field_or_a_fragment_definition_is_an_error_at_it() {
    assert_eq!(
        errors(
            "mutation M($id: ID!) { discardNote(id: $id) @deletes(type: \"Note\", id: $id) { deleted } }",
            Some(Marker::Mutation)
        ),
        vec![
            "`@deletes` on a field has no meaning in Baton; a field takes `@include`, `@skip`, `@required`, `@catch`, `@connection`, `@appendEdge`, `@prependEdge`, `@appendNode`, `@prependNode`, `@deleteEdge`, `@deleteRecord`, `@stream`, `@stream_connection`, `@paged`"
        ]
    );
    assert_eq!(
        errors(
            "fragment F on Note @deletes(type: \"Note\", id: $id) { id }",
            Some(Marker::Fragment)
        )
        .len(),
        1
    );
}

/// The errors in `text`, each with the text it points at: the rest of the
/// document from its position.
fn errors_at(text: &str, marker: Option<Marker>) -> Vec<(String, String)> {
    let key = SourceLocationKey::embedded(&Path::new("Directives.swift").to_string_lossy(), 0);
    let parsed = graphql_syntax::parse_executable(text, key).expect("the document parses");
    check(&parsed.definitions, key, marker)
        .iter()
        .map(|error| {
            let start = error.location().span().start as usize;
            (error.message().to_string(), text[start..].to_string())
        })
        .collect()
}

#[test]
fn paged_on_a_field_passes_the_directive_check() {
    assert!(
        errors(
            "query Q($page: Int!) { page(page: $page) { pageInfo { hasNextPage } notes @paged(key: \"Q_notes\", page: $page) { id } } }",
            Some(Marker::Query)
        )
        .is_empty()
    );
    assert!(
        errors(
            "fragment F on Character { friends(page: $page) { pageInfo { hasNextPage } nodes @paged(key: \"F_nodes\", page: $page) { id } } }",
            Some(Marker::Fragment)
        )
        .is_empty()
    );
}

#[test]
fn paged_on_a_query_a_fragment_definition_an_inline_fragment_or_a_spread_is_an_error_at_it() {
    for (text, marker, message) in [
        (
            "query Q($page: Int!) @paged(key: \"Q_notes\", page: $page) { page(page: $page) { notes { id } } }",
            Marker::Query,
            "`@paged` on a query has no meaning in Baton; a query takes `@throwOnFieldError`, `@cacheExpiration`",
        ),
        (
            "fragment F on Page @paged(key: \"F_notes\", page: $page) { notes { id } }",
            Marker::Fragment,
            "`@paged` on a fragment definition has no meaning in Baton; a fragment definition takes `@argumentDefinitions`, `@refetchable`, `@throwOnFieldError`, `@inline`",
        ),
        (
            "query Q($page: Int!) { page(page: $page) { ... on Page @paged(key: \"Q_notes\", page: $page) { notes { id } } } }",
            Marker::Query,
            "`@paged` on an inline fragment has no meaning in Baton; an inline fragment takes `@include`, `@skip`, `@defer`, `@alias`, `@catch`",
        ),
        (
            "query Q($page: Int!) { page(page: $page) { ...F @paged(key: \"Q_notes\", page: $page) } }",
            Marker::Query,
            "`@paged` on a fragment spread has no meaning in Baton; a fragment spread takes `@include`, `@skip`, `@defer`, `@arguments`, `@alias`, `@catch`",
        ),
    ] {
        let errors = errors_at(text, Some(marker));
        assert_eq!(errors.len(), 1, "{text}: {errors:?}");
        let (error, at) = &errors[0];
        assert_eq!(error, message, "{text}");
        assert!(at.starts_with("@paged("), "{text}: at `{at}`");
    }
}

/// What taking `@deletes` off a document leaves.
struct Taken {
    /// Each `@deletes` taken, as its operation, its type and its variable.
    deletes: Vec<(String, String, String)>,
    /// The directives each definition keeps, by name.
    kept: Vec<Vec<String>>,
    /// The errors of the directives' shape and of the variables they name.
    errors: Vec<String>,
}

/// The `@deletes` taken off `text`'s mutations, each kept when a field
/// passes its variable, as the pipeline checks once every document is
/// parsed.
fn taken(text: &str) -> Taken {
    let key = SourceLocationKey::embedded(&Path::new("Directives.swift").to_string_lossy(), 0);
    let mut parsed = graphql_syntax::parse_executable(text, key).expect("the document parses");
    let mut errors = Vec::new();
    let mut deletes = take_deletes(&mut parsed.definitions, key, &mut errors);
    check_passes(&mut deletes, &parsed.definitions, &mut errors);
    let deletes = deletes
        .into_iter()
        .flat_map(|(operation, deletes)| {
            deletes
                .into_iter()
                .map(move |deletes| (operation.clone(), deletes.type_name, deletes.variable))
        })
        .collect();
    let kept = parsed
        .definitions
        .iter()
        .map(|definition| match definition {
            ExecutableDefinition::Operation(operation) => operation
                .directives
                .iter()
                .map(|directive| directive.name.value.lookup().to_string())
                .collect(),
            ExecutableDefinition::Fragment(fragment) => fragment
                .directives
                .iter()
                .map(|directive| directive.name.value.lookup().to_string())
                .collect(),
        })
        .collect();
    let errors = errors
        .iter()
        .map(|error| error.message().to_string())
        .collect();
    Taken {
        deletes,
        kept,
        errors,
    }
}

#[test]
fn deletes_is_taken_off_a_mutation_before_relay_sees_it_and_its_other_directives_stay() {
    let Taken {
        deletes,
        kept,
        errors,
    } = taken(
        "mutation M($id: ID!, $uuid: String!) @throwOnFieldError @deletes(type: \"Note\", id: $id) @deletes(type: \"Asset\", id: $uuid) { discardNote(id: $id) { deleted } discardAsset(uuid: $uuid) { deleted } }",
    );
    assert!(errors.is_empty(), "{errors:?}");
    assert_eq!(
        deletes,
        vec![
            ("M".to_string(), "Note".to_string(), "id".to_string()),
            ("M".to_string(), "Asset".to_string(), "uuid".to_string()),
        ]
    );
    assert_eq!(kept, vec![vec!["throwOnFieldError".to_string()]]);
}

#[test]
fn deletes_on_a_query_is_left_for_the_directive_check_to_refuse() {
    let Taken {
        deletes,
        kept,
        errors,
    } = taken("query Q($id: ID!) @deletes(type: \"Note\", id: $id) { node(id: $id) { id } }");
    assert!(deletes.is_empty());
    assert_eq!(kept, vec![vec!["deletes".to_string()]]);
    assert!(errors.is_empty(), "{errors:?}");
}

#[test]
fn deletes_naming_a_variable_no_field_passes_is_dropped_with_an_error() {
    let Taken {
        deletes, errors, ..
    } = taken(
        "mutation M($id: ID!, $other: ID!) @deletes(type: \"Note\", id: $other) @deletes(type: \"Note\", id: $id) { discardNote(id: $id) { deleted } }",
    );
    assert_eq!(
        deletes,
        vec![("M".to_string(), "Note".to_string(), "id".to_string())]
    );
    assert_eq!(
        errors,
        vec![
            "`@deletes` names `$other`, which no field of `M` passes: a server refuses a variable its operation does not use"
        ]
    );
}

#[test]
fn a_variable_deletes_names_counts_as_passed_inside_the_fragments_a_mutation_spreads() {
    for fragments in [
        "fragment F on Mutation { discardNote(id: $id) { deleted } }",
        "fragment F on Mutation { ...G } fragment G on Mutation { ... on Mutation { discardNote(id: $id) { deleted } } }",
    ] {
        let Taken {
            deletes, errors, ..
        } = taken(&format!(
            "mutation M($id: ID!) @deletes(type: \"Note\", id: $id) {{ ...F }} {fragments}"
        ));
        assert!(errors.is_empty(), "{fragments}: {errors:?}");
        assert_eq!(deletes.len(), 1, "{fragments}");
    }
}

#[test]
fn a_fragment_that_shadows_the_variable_a_cycle_of_spreads_or_a_missing_fragment_passes_nothing() {
    for fragments in [
        "fragment F on Mutation @argumentDefinitions(id: {type: \"ID!\"}) { discardNote(id: $id) { deleted } }",
        "fragment F on Mutation { ...G } fragment G on Mutation { ...F }",
        "fragment G on Mutation { discardNote(id: $id) { deleted } }",
    ] {
        let Taken {
            deletes, errors, ..
        } = taken(&format!(
            "mutation M($id: ID!) @deletes(type: \"Note\", id: $id) {{ ...F }} {fragments}"
        ));
        assert!(deletes.is_empty(), "{fragments}");
        assert_eq!(errors.len(), 1, "{fragments}: {errors:?}");
    }
}

#[test]
fn a_variable_deletes_names_counts_as_passed_wherever_a_field_or_a_spread_passes_it() {
    for selection in [
        "discardNote(id: $id) { deleted }",
        "discardNote(id: \"n1\") { deleted @include(if: $id) }",
        "charactersMatching(filters: [{name: $id}]) { id }",
        "... on Mutation { discardNote(id: $id) { deleted } }",
        "...F @arguments(id: $id)",
        "rename(id: \"1\", name: \"a\") { character { notes(after: $id) { totalCount } } }",
    ] {
        let Taken {
            deletes, errors, ..
        } = taken(&format!(
            "mutation M($id: ID!) @deletes(type: \"Note\", id: $id) {{ {selection} }}"
        ));
        assert!(errors.is_empty(), "{selection}: {errors:?}");
        assert_eq!(deletes.len(), 1, "{selection}");
    }
}

#[test]
fn a_marker_holds_exactly_one_definition_of_its_own_kind() {
    assert_eq!(
        errors("query Q { a }", Some(Marker::Fragment)),
        vec![
            "`@Fragment` holds 1 definitions, 0 of them a fragment: it takes exactly one fragment"
        ]
    );
    assert_eq!(
        errors(
            "fragment F on T { a } fragment G on T { b }",
            Some(Marker::Fragment)
        )
        .len(),
        1
    );
    assert!(
        errors("fragment F on T { a } fragment G on T { b }", None).is_empty(),
        "a .graphql file holds any number"
    );
}
