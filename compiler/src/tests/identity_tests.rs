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
