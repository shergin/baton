//! Tests of configured identity: the diagnostics of an `identity` block the
//! schema cannot honour, the key fields the compiler selects where a
//! document leaves them out, and the digest an image is versioned by.

use super::*;

/// The configuration with `identity` set to the given JSON.
fn configured(identity: &str) -> Config {
    let mut config: Config = serde_json::from_str(&format!(r#"{{"identity": {identity}}}"#))
        .expect("the configuration parses");
    config.path = PathBuf::from("baton.json");
    config
}

/// The messages compiling `QUERY` fails with under the identity block.
fn identity_errors(identity: &str) -> Vec<String> {
    errors(&format!(r#"{{"identity": {identity}}}"#), QUERY)
}

/// The compiled plan of `text` under the identity block.
fn compiled(identity: &str, text: &str) -> crate::pipeline::plan::Plan {
    let (sdl, path) = schema();
    compile(&sdl, &path, &[document(text)], &configured(identity))
        .unwrap_or_else(|errors| panic!("{errors:?}"))
        .plan
}

/// The text the server receives for `text` under the identity block.
fn sent(identity: &str, text: &str) -> String {
    compiled(identity, text).operations[0].text.clone()
}

#[test]
fn an_identity_for_a_type_the_schema_lacks_is_an_error_pointing_at_the_configuration() {
    let (sdl, path) = schema();
    let diagnostics = compile(
        &sdl,
        &path,
        &[document(QUERY)],
        &configured(r#"{"types": {"Robot": ["id"]}}"#),
    )
    .err()
    .expect("an unknown type does not compile");
    let messages: Vec<String> = diagnostics
        .iter()
        .map(|diagnostic| diagnostic.message().to_string())
        .collect();
    assert_eq!(
        messages,
        vec!["the identity of `Robot` is configured, but the schema has no such type"]
    );
    assert_eq!(
        diagnostics[0].location().source_location(),
        SourceLocationKey::standalone("baton.json"),
        "the diagnostic points at the configuration file"
    );
}

#[test]
fn an_identity_for_a_union_is_an_error() {
    assert_eq!(
        identity_errors(r#"{"types": {"SearchResult": ["id"]}}"#),
        vec![
            "the identity of `SearchResult` is configured, but `SearchResult` is not an object or interface type"
        ]
    );
}

#[test]
fn an_identity_naming_a_field_the_type_lacks_is_an_error() {
    assert_eq!(
        identity_errors(r#"{"types": {"Quote": ["id"]}}"#),
        vec!["the identity of `Quote` names `id`, which `Quote` does not have"]
    );
}

#[test]
fn an_identity_naming_a_list_a_link_a_float_or_a_boolean_is_an_error() {
    for (type_, field) in [
        ("Tokenizer", "strings"),
        ("Character", "episode"),
        ("Character", "origin"),
        ("Quote", "rate"),
        ("Character", "favorite"),
    ] {
        assert_eq!(
            identity_errors(&format!(r#"{{"types": {{"{type_}": ["{field}"]}}}}"#)),
            vec![format!(
                "the identity of `{type_}` names `{field}`, which is not a scalar of one value: a key is own scalar fields"
            )],
            "{type_}.{field}"
        );
    }
}

#[test]
fn an_identity_naming_no_field_is_an_error() {
    assert_eq!(
        identity_errors(r#"{"types": {"Asset": []}}"#),
        vec!["the identity of Asset names no field"]
    );
    assert_eq!(
        identity_errors(r#"{"default": []}"#),
        vec!["the identity of the default names no field"]
    );
}

#[test]
fn an_identity_naming_a_path_through_a_link_is_an_error() {
    let messages = identity_errors(r#"{"types": {"Asset": ["owner.id"]}}"#);
    assert!(
        messages.contains(
            &"the identity of Asset names `owner.id`: a key is own scalar fields, not a path through a link"
                .to_string()
        ),
        "{messages:?}"
    );
}

#[test]
fn an_object_implementing_two_interfaces_whose_identities_differ_is_an_error() {
    let messages = identity_errors(r#"{"types": {"Node": ["id"], "Named": ["name"]}}"#);
    for name in ["Character", "Location"] {
        assert!(
            messages.contains(&format!(
                "`{name}` implements interfaces whose identities differ: configure the identity of `{name}` itself"
            )),
            "{messages:?}"
        );
    }
    assert_eq!(messages.len(), 2, "{messages:?}");
    assert!(
        identity_errors(r#"{"types": {"Node": ["id"], "Named": ["name"], "Character": ["id"], "Location": ["id"]}}"#)
            .is_empty(),
        "the object's own entry settles it"
    );
}

const TEST_IDENTITY: &str = r#"{"types": {"Asset": ["uuid"], "Quote": ["base", "quote"]}}"#;

/// The lines of `text` that select `field` at any depth.
fn selections_of(text: &str, field: &str) -> usize {
    text.lines().filter(|line| line.trim() == field).count()
}

#[test]
fn the_key_field_a_document_leaves_out_is_selected() {
    let text = sent(TEST_IDENTITY, "query Probe { assets { name } }");
    assert_eq!(selections_of(&text, "uuid"), 1, "{text}");

    let text = sent(TEST_IDENTITY, "query Probe { quotes { rate } }");
    assert_eq!(selections_of(&text, "base"), 1, "{text}");
    assert_eq!(selections_of(&text, "quote"), 1, "{text}");
    assert!(
        text.find("    base").unwrap() < text.find("    quote").unwrap(),
        "the key fields come in the configured order: {text}"
    );

    let plan = compiled(TEST_IDENTITY, "query Probe { quotes { rate } }");
    let SelectionPlan::Linked { keys, .. } = &plan.operations[0].normalization[0] else {
        panic!("quotes is a link");
    };
    assert_eq!(
        keys.get("Quote"),
        Some(&vec!["base".to_string(), "quote".to_string()])
    );
}

#[test]
fn a_key_field_the_document_selects_is_not_selected_again() {
    let text = sent(TEST_IDENTITY, "query Probe { assets { uuid name } }");
    assert_eq!(selections_of(&text, "uuid"), 1, "{text}");
    let text = sent(TEST_IDENTITY, "query Probe { quotes { quote rate base } }");
    assert_eq!(selections_of(&text, "base"), 1, "{text}");
    assert_eq!(selections_of(&text, "quote"), 1, "{text}");
}

#[test]
fn an_interface_whose_keyed_members_share_its_own_key_selects_it_once_on_itself() {
    let text = sent("{}", "query Probe { node(id: \"1\") { __typename } }");
    assert_eq!(selections_of(&text, "id"), 1, "{text}");
    assert!(!text.contains("... on Character"), "{text}");
}

#[test]
fn a_union_of_differently_keyed_members_selects_only_the_keys_relay_does_not() {
    let text = sent(
        r#"{"types": {"Character": ["name"]}}"#,
        "query Probe { search(name: \"a\") { __typename } }",
    );
    let character = text
        .split("... on Character {")
        .nth(1)
        .unwrap_or_else(|| panic!("Character is selected under its condition: {text}"));
    let character = &character[..character.find('}').unwrap()];
    assert_eq!(
        character.split_whitespace().collect::<Vec<_>>(),
        vec!["name"],
        "{text}"
    );
    for member in ["Location", "Episode"] {
        assert!(
            !text.contains(&format!("... on {member}")),
            "Relay's `... on Node {{ id }}` keys {member}: {text}"
        );
    }
    assert!(
        text.contains("... on Node {\n      __isNode: __typename\n      id\n    }"),
        "{text}"
    );
}

#[test]
fn an_alias_taking_a_key_field_s_name_is_refused_at_the_alias() {
    let (sdl, path) = schema();
    let text = "query Probe { assets { uuid: name } }";
    let diagnostics = compile(&sdl, &path, &[document(text)], &configured(TEST_IDENTITY))
        .err()
        .expect("an alias taking the key's name does not compile");
    let messages: Vec<String> = diagnostics
        .iter()
        .map(|diagnostic| diagnostic.message().to_string())
        .collect();
    assert_eq!(
        messages,
        vec!["`uuid` keys `Asset`: no field may be aliased to it"]
    );
    let span = diagnostics[0].location().span();
    assert_eq!(
        &text[span.start as usize..span.end as usize],
        "uuid",
        "the diagnostic points at the alias"
    );

    compiled(TEST_IDENTITY, "query Probe { assets { label: name } }");
}

#[test]
fn the_digest_changes_with_a_configured_identity_and_stays_with_the_default() {
    let plain = compiled("{}", QUERY).schema_digest;
    let (sdl, _) = schema();
    assert_eq!(plain, format!("{:x}", md5::compute(sdl.as_bytes())));
    assert_eq!(
        compiled(r#"{"default": ["id"]}"#, QUERY).schema_digest,
        plain
    );
    let configured = compiled(TEST_IDENTITY, QUERY).schema_digest;
    assert_ne!(configured, plain);
    assert_ne!(
        compiled(r#"{"types": {"Asset": ["uuid", "name"]}}"#, QUERY).schema_digest,
        configured,
        "another keying is another digest"
    );
}

/// The configuration with the test identity and `lookups` set to the given
/// JSON list.
fn with_lookups(identity: &str, lookups: &str) -> String {
    format!(r#"{{"identity": {identity}, "lookups": {lookups}}}"#)
}

const QUOTE_QUERY: &str =
    "query Probe($base: String!, $quote: String!) { quote(base: $base, quote: $quote) { rate } }";

/// The emitted Swift of `text` under `config`, the operation's file.
fn emitted(config: &str, text: &str) -> String {
    let (sdl, path) = schema();
    let mut config: Config = serde_json::from_str(config).expect("the configuration parses");
    config.path = PathBuf::from("baton.json");
    let compiled = compile(&sdl, &path, &[document(text)], &config)
        .unwrap_or_else(|errors| panic!("{errors:?}"));
    let output = crate::emit::emit(&compiled.plan).expect("the plan emits");
    output
        .files
        .into_values()
        .next()
        .expect("the operation has a file")
}

#[test]
fn a_lookup_naming_its_argument_neither_way_or_both_ways_is_an_error() {
    let message = "the lookup `Query.quote` names its argument neither as `argument` nor as `arguments`, or as both";
    assert_eq!(
        errors(
            &with_lookups(
                TEST_IDENTITY,
                r#"[{"field": "Query.quote", "type": "Quote"}]"#
            ),
            QUERY
        ),
        vec![message]
    );
    assert_eq!(
        errors(
            &with_lookups(
                TEST_IDENTITY,
                r#"[{"field": "Query.quote", "type": "Quote", "argument": "base", "arguments": ["base", "quote"]}]"#
            ),
            QUERY
        ),
        vec![message]
    );
}

#[test]
fn each_lookup_argument_the_field_lacks_is_an_error() {
    assert_eq!(
        errors(
            &with_lookups(
                TEST_IDENTITY,
                r#"[{"field": "Query.quote", "type": "Quote", "arguments": ["from", "quote", "to"]}]"#
            ),
            QUERY
        ),
        vec![
            "the lookup `Query.quote` takes `from`, which the field has no argument of",
            "the lookup `Query.quote` takes `to`, which the field has no argument of",
            "the lookup `Query.quote` passes 3 arguments, but `Quote` is keyed by 2 fields: pass one per field, in the key's order",
        ]
    );
}

#[test]
fn a_typed_lookup_passing_other_than_one_argument_per_key_field_is_an_error() {
    assert_eq!(
        errors(
            &with_lookups(
                TEST_IDENTITY,
                r#"[{"field": "Query.quote", "type": "Quote", "argument": "base"}]"#
            ),
            QUERY
        ),
        vec![
            "the lookup `Query.quote` passes 1 argument, but `Quote` is keyed by 2 fields: pass one per field, in the key's order"
        ]
    );
    assert_eq!(
        errors(
            &with_lookups(
                TEST_IDENTITY,
                r#"[{"field": "Query.asset", "type": "Asset", "arguments": ["uuid", "uuid"]}]"#
            ),
            QUERY
        ),
        vec![
            "the lookup `Query.asset` passes 2 arguments, but `Asset` is keyed by 1 field: pass one per field, in the key's order"
        ]
    );
}

#[test]
fn a_typed_lookup_on_a_type_without_a_key_is_an_error() {
    assert_eq!(
        errors(
            r#"{"lookups": [{"field": "Query.quote", "type": "Quote", "arguments": ["base", "quote"]}]}"#,
            QUERY
        ),
        vec!["the lookup `Query.quote` names `Quote`, which has no key: a lookup finds an entity"]
    );
}

#[test]
fn a_lookup_without_a_type_passing_several_arguments_is_an_error() {
    assert_eq!(
        errors(
            r#"{"lookups": [{"field": "Query.node", "arguments": ["id", "id"]}]}"#,
            QUERY
        ),
        vec![
            "`Query.node` returns `Node`, an interface or union: the lookup finds an id among its types by one argument"
        ]
    );
}

#[test]
fn a_typed_lookup_with_two_arguments_passes_them_in_the_key_s_order() {
    let config = with_lookups(
        TEST_IDENTITY,
        r#"[{"field": "Query.quote", "type": "Quote", "arguments": ["base", "quote"]}]"#,
    );
    assert!(emitted(&config, QUOTE_QUERY).contains(
        r#"lookup: Baton.Lookup(type: Types.Quote, key: [.variable("base"), .variable("quote")])"#
    ));
    let reordered =
        "query Probe($to: String!, $from: String!) { quote(quote: $to, base: $from) { rate } }";
    assert!(
        emitted(&config, reordered).contains(
            r#"lookup: Baton.Lookup(type: Types.Quote, key: [.variable("from"), .variable("to")])"#
        ),
        "the configuration's order wins over the document's"
    );
}

#[test]
fn a_lookup_spelling_its_one_argument_in_the_singular_still_compiles() {
    let config = with_lookups(
        TEST_IDENTITY,
        r#"[{"field": "Query.asset", "type": "Asset", "argument": "uuid"}]"#,
    );
    assert!(
        emitted(
            &config,
            "query Probe($uuid: String!) { asset(uuid: $uuid) { name } }"
        )
        .contains(r#"lookup: Baton.Lookup(type: Types.Asset, key: [.variable("uuid")])"#)
    );
    let plural = with_lookups(
        TEST_IDENTITY,
        r#"[{"field": "Query.asset", "type": "Asset", "arguments": ["uuid"]}]"#,
    );
    assert!(
        emitted(&plural, "query Probe { asset(uuid: \"a1\") { name } }")
            .contains(r#"lookup: Baton.Lookup(type: Types.Asset, key: [.literal("a1")])"#)
    );
}

#[test]
fn a_lookup_without_a_type_probes_only_the_types_one_value_keys() {
    let (sdl, path) = schema();
    let mut config: Config = serde_json::from_str(&with_lookups(
        r#"{"types": {"Episode": ["id", "name"]}}"#,
        r#"[{"field": "Query.node", "argument": "id"}]"#,
    ))
    .expect("the configuration parses");
    config.path = PathBuf::from("baton.json");
    let compiled = compile(
        &sdl,
        &path,
        &[document("query Probe($id: ID!) { node(id: $id) { id } }")],
        &config,
    )
    .unwrap_or_else(|errors| panic!("{errors:?}"));
    let SelectionPlan::Linked {
        lookup: Some(lookup),
        possible_types,
        ..
    } = &compiled.plan.operations[0].normalization[0]
    else {
        panic!("node is a looked-up link");
    };
    assert!(possible_types.contains(&"Episode".to_string()));
    assert_eq!(
        lookup.possible_types,
        vec!["Character", "Location", "Note"],
        "an episode, keyed by two fields, is never found by one id"
    );
}

#[test]
fn a_lookup_without_a_type_keeps_its_own_set_beside_a_lens_testing_the_same_condition() {
    let (sdl, path) = schema();
    let mut config: Config = serde_json::from_str(&with_lookups(
        r#"{"types": {"Episode": ["id", "name"]}}"#,
        r#"[{"field": "Query.node", "argument": "id"}]"#,
    ))
    .expect("the configuration parses");
    config.path = PathBuf::from("baton.json");
    let text = "query Probe { node(id: \"1\") { __typename } namesake(name: \"a\") { ...ProbeNode @alias } } fragment ProbeNode on Node { id }";
    let compiled = compile(&sdl, &path, &[document(text)], &config)
        .unwrap_or_else(|errors| panic!("{errors:?}"));
    let output = crate::emit::emit(&compiled.plan).expect("the plan emits");
    let shared = &output.shared;
    assert!(
        shared.contains("static let Node_keyed = Baton.Members(Node, [Character, Location, Note])"),
        "the lookup probes only the types one id keys:\n{shared}"
    );
    assert!(
        shared.contains(
            "static let Node_possible = Baton.Members(Node, [Character, Episode, Location, Note])"
        ),
        "the lens tests every type that satisfies `... on Node`:\n{shared}"
    );
    let swift: String = output.files.values().cloned().collect();
    assert!(
        swift.contains("Baton.Lookup(type: nil, possibleTypes: Types.Node_keyed,"),
        "the lookup references its own set:\n{swift}"
    );
    assert!(
        !swift.contains("possibleTypes: Types.Node_possible"),
        "{swift}"
    );
}

#[test]
fn a_schema_type_named_like_a_set_of_types_is_refused_rather_than_declared_twice() {
    for set in ["Node_keyed", "Node_possible"] {
        let (sdl, path) = schema();
        let sdl =
            format!("{sdl}\ntype {set} {{ id: ID! }}\nextend type Query {{ probe: {set} }}\n");
        let mut config: Config = serde_json::from_str(&with_lookups(
            r#"{"types": {"Episode": ["id", "name"]}}"#,
            r#"[{"field": "Query.node", "argument": "id"}]"#,
        ))
        .expect("the configuration parses");
        config.path = PathBuf::from("baton.json");
        let text = "query Probe { node(id: \"1\") { __typename } namesake(name: \"a\") { ...ProbeNode @alias } probe { id } } fragment ProbeNode on Node { id }";
        let compiled = compile(&sdl, &path, &[document(text)], &config)
            .unwrap_or_else(|errors| panic!("{errors:?}"));
        let errors: Vec<String> = crate::emit::emit(&compiled.plan)
            .err()
            .unwrap_or_else(|| panic!("`{set}` is declared once"))
            .iter()
            .map(ToString::to_string)
            .collect();
        assert_eq!(errors.len(), 1, "{errors:?}");
        assert!(
            errors[0].contains(&format!(
                "`Types` would declare `{set}` twice, as the type `{set}`"
            )),
            "{errors:?}"
        );
    }
}
