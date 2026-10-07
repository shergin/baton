//! Tests of what an `@inline` fragment may say and how its spread is named:
//! the refusals Baton adds to Relay's, each at the text it is about,
//! Relay's own refusals of `@required` inside one and of `@catch` on its
//! spread, and an alias that names the spread as it is named anyway.

use super::*;

/// The diagnostics compiling `text` against the test schema fails with, each
/// as its message and the line and column it points at.
fn refusals(text: &str) -> Vec<(String, u32, u32)> {
    let (sdl, path) = schema();
    let mut config: Config = serde_json::from_str("{}").expect("the configuration parses");
    config.path = PathBuf::from("baton.json");
    let source = document(text);
    match compile(&sdl, &path, &[], std::slice::from_ref(&source), &config) {
        Ok(_) => Vec::new(),
        Err(diagnostics) => diagnostics
            .iter()
            .map(|diagnostic| {
                let rendered =
                    crate::diagnostics::render(diagnostic, std::slice::from_ref(&source));
                (
                    diagnostic.message().to_string(),
                    rendered.line,
                    rendered.column,
                )
            })
            .collect(),
    }
}

/// The emitted Swift of `text` against the test schema, every file of it.
fn emitted(text: &str) -> String {
    let (sdl, path) = schema();
    let mut config: Config = serde_json::from_str("{}").expect("the configuration parses");
    config.path = PathBuf::from("baton.json");
    let compiled = compile(&sdl, &path, &[], &[document(text)], &config)
        .unwrap_or_else(|errors| panic!("{errors:?}"));
    let output = crate::emit::emit(&compiled.plan, &config).expect("the plan emits");
    output.files.into_values().collect::<Vec<_>>().join("\n")
}

#[test]
fn a_lens_fragment_spread_inside_an_inline_fragment_is_refused_at_the_spread() {
    let text = "fragment Lens_character on Character { name }
fragment LensLocation_location on Location { name }
fragment Value_character on Character @inline {
  id
  ...Lens_character
  origin { ...LensLocation_location }
}";
    assert_eq!(
        refusals(text),
        vec![
            (
                "`...Lens_character` spreads a lens fragment inside the `@inline` fragment `Value_character`; a value holds no lens, so an inline fragment spreads only inline fragments".to_string(),
                5,
                6
            ),
            (
                "`...LensLocation_location` spreads a lens fragment inside the `@inline` fragment `Value_character`; a value holds no lens, so an inline fragment spreads only inline fragments".to_string(),
                6,
                15
            ),
        ]
    );
}

#[test]
fn an_inline_fragment_spreads_an_inline_fragment_inside_it_and_under_a_type_condition() {
    let text = "fragment Origin_location on Location @inline { name }
fragment Value_character on Character @inline {
  origin { ...Origin_location }
  ... on Character { origin { ...Origin_location } }
}
query Probe { character(id: 1) { ...Value_character } }";
    assert_eq!(refusals(text), Vec::new());
}

#[test]
fn a_connection_inside_an_inline_fragment_is_refused_at_the_fragment_name() {
    let text = "fragment Value_character on Character @inline {
  notes(first: 2) @connection(key: \"Value_notes\") { edges { node { id } } }
}";
    assert_eq!(
        refusals(text),
        vec![(
            "`Value_character` is `@inline` and selects a `@connection`; a value paginates nothing, so an inline fragment reads the field without `@connection`".to_string(),
            1,
            10
        )]
    );
}

#[test]
fn a_refetchable_inline_fragment_is_refused_at_the_fragment_name() {
    let text = "fragment Value_character on Character
  @inline
  @refetchable(queryName: \"ValueRefetchQuery\") {
  name
}";
    assert_eq!(
        refusals(text),
        vec![(
            "`Value_character` is `@inline` and `@refetchable`; a value is not live, so an inline fragment is not refetched".to_string(),
            1,
            10
        )]
    );
}

#[test]
fn required_inside_an_inline_fragment_is_refused_with_relay_s_message() {
    let text = "fragment Value_character on Character @inline {
  name @required(action: NONE)
}";
    assert_eq!(
        refusals(text),
        vec![(
            "@required is not supported within @inline fragments.".to_string(),
            2,
            8
        )]
    );
}

#[test]
fn catch_on_the_spread_of_an_inline_fragment_is_refused_by_relay_s_schema() {
    let text = "fragment Value_character on Character @inline { name }
query Probe { character(id: 1) { ...Value_character @catch } }";
    let refused = refusals(text);
    assert_eq!(refused.len(), 1, "{refused:?}");
    assert_eq!(
        refused[0],
        (
            "Directive 'catch' not supported in this location. Supported location(s): FIELD, FRAGMENT_DEFINITION, QUERY, MUTATION, INLINE_FRAGMENT"
                .to_string(),
            2,
            54
        )
    );
}

#[test]
fn an_alias_that_names_an_inline_spread_by_its_fragment_is_no_alias() {
    let fragment = "fragment Value_character on Character @inline { name }";
    let plain = emitted(&format!(
        "{fragment} query Probe {{ character(id: 1) {{ ...Value_character }} }}"
    ));
    let aliased = emitted(&format!(
        "{fragment} query Probe {{ character(id: 1) {{ ...Value_character @alias(as: \"Value_character\") }} }}"
    ));
    let accessor =
        "@MainActor public var value: Value_character { .init(anchor: anchor.entering()) }";
    assert!(plain.contains(accessor), "{plain}");
    assert!(aliased.contains(accessor), "{aliased}");
    assert!(!aliased.contains("var Value_character"), "{aliased}");
    let renamed = emitted(&format!(
        "{fragment} query Probe {{ character(id: 1) {{ ...Value_character @alias(as: \"chosen\") }} }}"
    ));
    assert!(
        renamed.contains(
            "@MainActor public var chosen: Value_character { .init(anchor: anchor.entering()) }"
        ),
        "{renamed}"
    );
}

#[test]
fn a_throwing_value_spread_inside_a_value_is_refused_at_the_outer_fragment_name() {
    let text = "fragment Inner_character on Character @inline @throwOnFieldError { name }
fragment Outer_character on Character @inline {
  id
  origin { id }
  ...Inner_character
}";
    assert_eq!(
        refusals(text),
        vec![(
            "`Inner_character` is `@throwOnFieldError` and is spread inside the `@inline` fragment `Outer_character`; a value is built in one pass, so the policy goes on `Outer_character`, whose errors include those of the values it spreads".to_string(),
            2,
            10
        )]
    );
}

#[test]
fn a_scanning_value_collects_a_spread_with_arguments_through_its_binding_and_a_conditional_one_under_its_guard()
 {
    let swift = emitted(
        "fragment Counted_character on Character @inline @argumentDefinitions(count: {type: \"Int\", defaultValue: 2}) { notes(first: $count) { totalCount } }
fragment Named_character on Character @inline { name }
fragment Outer_character on Character @inline @throwOnFieldError @argumentDefinitions(withName: {type: \"Boolean!\"}) {
  id
  ...Counted_character @arguments(count: 1)
  ...Named_character @include(if: $withName) @alias(as: \"named\")
}
query Probe($withName: Boolean!) { character(id: 1) { ...Outer_character @arguments(withName: $withName) } }",
    );
    let start = swift
        .find("public struct Outer_character:")
        .expect("the outer value is emitted");
    let outer = &swift[start..];
    let body = &outer[outer
        .find("static func fieldErrors(")
        .expect("the outer value collects its errors")..];
    let body = &body[..body.find("\n    }\n").expect("the function closes")];
    let lines: Vec<&str> = body.lines().map(str::trim).collect();
    let counted = lines
        .iter()
        .position(|line| *line == "typealias Fragment = Counted_character")
        .unwrap_or_else(|| panic!("{body}"));
    assert!(
        lines[counted + 1].starts_with("let bound = anchor.binding(Sites."),
        "{body}"
    );
    assert_eq!(
        lines[counted + 2],
        "errors.append(contentsOf: Fragment.fieldErrors(bound))"
    );
    let named = lines
        .iter()
        .position(|line| *line == "typealias Fragment = Named_character")
        .unwrap_or_else(|| panic!("{body}"));
    assert!(
        lines[named + 1].starts_with("if anchor.owner.selects(Guards.")
            && lines[named + 1]
                .ends_with("{ errors.append(contentsOf: Fragment.fieldErrors(anchor)) }"),
        "{body}"
    );
}
