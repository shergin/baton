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
fn a_directive_baton_gives_no_meaning_is_an_error_at_it() {
    assert_eq!(
        errors("fragment F on T @inline { a }", Some(Marker::Fragment)),
        vec![
            "`@inline` on a fragment definition has no meaning in Baton; a fragment definition takes `@argumentDefinitions`, `@refetchable`, `@throwOnFieldError`"
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
        errors(
            "query Q { a @stream(initialCount: 1) { b } }",
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
            "`@cacheExpiration` on a mutation has no meaning in Baton; a mutation takes `@throwOnFieldError`"
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
