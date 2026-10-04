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

#[test]
fn a_field_named_like_a_lens_member_must_be_aliased() {
    assert_eq!(
        errors("query Q { anchor { id } }", Some(Marker::Query)),
        vec![
            "`anchor` is a member every lens has, so a field of that name would hide it; alias the field"
        ]
    );
    assert_eq!(
        errors("query Q { a { recordID } }", Some(Marker::Query)).len(),
        1
    );
    assert!(errors("query Q { place: anchor { id } }", Some(Marker::Query)).is_empty());
}
