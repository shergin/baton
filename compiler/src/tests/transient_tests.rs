//! Tests of `transient`, what never reaches the image: the configuration is
//! checked against the schema where it loads, an interface named applies to
//! its implementers, the plan marks the root fields named, the shared file
//! tells the registry the types and fields, and the digest folds the lists
//! in.

use super::*;

const CONFIG: &str = r#"{"transient": {"types": ["Secret"], "fields": ["Query.secrets"]}}"#;
const SECRETS: &str = "query Probe($code: String!) { secrets(code: $code) { id body } character(id: \"1\") { id name } }";

/// The plan of `text` under the configuration `config`.
fn compiled(config: &str, text: &str) -> crate::pipeline::plan::Plan {
    let (sdl, path) = schema();
    let mut config: Config = serde_json::from_str(config).expect("the configuration parses");
    config.path = PathBuf::from("baton.json");
    compile(&sdl, &path, &[], &[document(text)], &config)
        .unwrap_or_else(|errors| panic!("{errors:?}"))
        .plan
}

/// The root fields of the operation's normalization selection, by name,
/// with whether the plan marks each transient.
fn root_marks(plan: &crate::pipeline::plan::Plan) -> Vec<(String, bool)> {
    plan.operations[0]
        .normalization
        .iter()
        .filter_map(|selection| match selection {
            SelectionPlan::Scalar {
                name, transient, ..
            }
            | SelectionPlan::Linked {
                name, transient, ..
            } => Some((name.clone(), *transient)),
            _ => None,
        })
        .collect()
}

#[test]
fn each_name_the_schema_cannot_take_is_refused_where_the_configuration_loads() {
    let (sdl, path) = schema();
    for (block, message) in [
        (
            r#"{"types": ["Vault"]}"#,
            "`transient` names `Vault`, which the schema does not declare",
        ),
        (
            r#"{"types": ["Status"]}"#,
            "`transient` names `Status`, which is not an object or interface type",
        ),
        (
            r#"{"fields": ["secrets"]}"#,
            "`transient` names the field `secrets`: write `Query.field`",
        ),
        (
            r#"{"fields": ["Vault.secrets"]}"#,
            "`transient` names `Vault.secrets`, but the schema has no type `Vault`",
        ),
        (
            r#"{"fields": ["Character.secret"]}"#,
            "`transient` names `Character.secret`, but `Character` is not a root type: a type's records are kept out by naming the type",
        ),
        (
            r#"{"fields": ["Query.vault"]}"#,
            "`transient` names `Query.vault`, which `Query` does not have",
        ),
    ] {
        let config = format!(r#"{{"transient": {block}}}"#);
        assert_eq!(errors(&config, QUERY), vec![message.to_string()], "{block}");

        let mut parsed: Config = serde_json::from_str(&config).expect("the configuration parses");
        parsed.path = PathBuf::from("baton.json");
        let diagnostics = compile(&sdl, &path, &[], &[document(QUERY)], &parsed)
            .err()
            .expect("the configuration is refused");
        assert_eq!(
            diagnostics[0].location().source_location(),
            SourceLocationKey::standalone("baton.json"),
            "the diagnostic points at the configuration file"
        );
    }
}

#[test]
fn an_interface_named_applies_to_the_object_types_that_implement_it() {
    let plan = compiled(r#"{"transient": {"types": ["Named"]}}"#, QUERY);
    assert_eq!(
        plan.transient_types,
        BTreeSet::from(["Character".to_string(), "Location".to_string()])
    );
    let plan = compiled(CONFIG, QUERY);
    assert_eq!(plan.transient_types, BTreeSet::from(["Secret".to_string()]));
}

#[test]
fn the_plan_and_the_emitted_swift_mark_the_root_field_named_and_no_other() {
    let plan = compiled(CONFIG, SECRETS);
    assert_eq!(
        root_marks(&plan),
        vec![
            ("secrets".to_string(), true),
            ("character".to_string(), false)
        ]
    );
    let output = crate::emit::emit(&plan).expect("the plan emits");
    let swift: String = output.files.values().cloned().collect();
    let secrets = swift
        .lines()
        .find(|line| line.contains(".linked(\"secrets\""))
        .expect("the plan field of `secrets` is emitted");
    assert!(secrets.contains("transient: true"), "{secrets}");
    let character = swift
        .lines()
        .find(|line| line.contains(".linked(\"character\""))
        .expect("the plan field of `character` is emitted");
    assert!(!character.contains("transient"), "{character}");

    let unmarked = compiled("{}", SECRETS);
    assert_eq!(
        root_marks(&unmarked),
        vec![
            ("secrets".to_string(), false),
            ("character".to_string(), false)
        ],
        "without the configuration nothing is marked"
    );
}

#[test]
fn the_shared_file_declares_one_rule_set_and_every_plan_of_the_module_carries_it() {
    let output = crate::emit::emit(&compiled(CONFIG, SECRETS)).expect("the plan emits");
    for line in [
        r#"static let Secret = Baton.Registry.type("Secret", transient: true)"#,
        r#"static let transient = Baton.Transient(types: [Secret], fields: [(Query, "secrets")])"#,
        r#"static let Character = Baton.Registry.type("Character")"#,
    ] {
        assert!(
            output.shared.contains(line),
            "{line} is missing from:\n{}",
            output.shared
        );
    }
    let swift: String = output.files.values().cloned().collect();
    let plans = swift.matches("Baton.Plan(").count();
    assert!(plans > 0, "{swift}");
    assert_eq!(
        swift.matches("transient: Types.transient)").count(),
        plans,
        "every plan of the module carries the rules:\n{swift}"
    );

    let plain = crate::emit::emit(&compiled("{}", SECRETS)).expect("the plan emits");
    assert!(!plain.shared.contains("transient"), "{}", plain.shared);
    let swift: String = plain.files.values().cloned().collect();
    assert!(!swift.contains("Types.transient"), "{swift}");
}

#[test]
fn a_module_that_selects_no_transient_field_still_marks_the_transient_types() {
    let shared = crate::emit::emit(&compiled(CONFIG, QUERY))
        .expect("the plan emits")
        .shared;
    assert!(
        shared.contains(r#"static let Secret = Baton.Registry.type("Secret", transient: true)"#),
        "the type is the schema's, whichever documents the module has:\n{shared}"
    );
}

#[test]
fn the_digest_changes_with_the_lists_and_not_with_their_order() {
    let (sdl, _) = schema();
    let plain = compiled("{}", QUERY).schema_digest;
    assert_eq!(plain, format!("{:x}", md5::compute(sdl.as_bytes())));
    assert_eq!(
        compiled(r#"{"transient": {}}"#, QUERY).schema_digest,
        plain,
        "an empty block is the digest it was before the lists could be configured"
    );
    let types = compiled(r#"{"transient": {"types": ["Secret"]}}"#, QUERY).schema_digest;
    let fields = compiled(r#"{"transient": {"fields": ["Query.secrets"]}}"#, QUERY).schema_digest;
    let both = compiled(CONFIG, QUERY).schema_digest;
    let digests = BTreeSet::from([plain.clone(), types.clone(), fields.clone(), both.clone()]);
    assert_eq!(digests.len(), 4, "{digests:?}");
    assert_eq!(
        compiled(
            r#"{"transient": {"types": ["Secret", "Note"], "fields": ["Query.secrets"]}}"#,
            QUERY
        )
        .schema_digest,
        compiled(
            r#"{"transient": {"types": ["Note", "Secret"], "fields": ["Query.secrets"]}}"#,
            QUERY
        )
        .schema_digest
    );
}
