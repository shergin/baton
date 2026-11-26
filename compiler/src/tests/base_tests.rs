//! Tests of a target that spreads its bases' fragments: what a dependent
//! compilation reads of a base, what it reaches and checks, what it
//! generates through a base's lens and what it leaves to the base, the
//! spreads it refuses, and the report and fragments file a base is read
//! from.
//!
//! Each base here is compiled from documents as its own target and read
//! back from the fragments file `generate --fragments` writes for it, so a
//! dependent reads what a build hands it.

use std::path::{Path, PathBuf};

use super::*;
use crate::config::Config;
use crate::diagnostics::Rendered;
use crate::documents::{Document, Position};
use crate::emit::Output;
use crate::pipeline::{Plan, compile_with_bases};
use crate::report::Home;
use support::one_file;

/// The test schema's text and path.
fn schema() -> (String, String) {
    let path = Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("the compiler sits one level below the repository root")
        .join("spec/tests/schema.graphql");
    (
        std::fs::read_to_string(&path).expect("the test schema is readable"),
        path.to_string_lossy().into_owned(),
    )
}

/// The configuration both targets are compiled under: none, at `baton.json`.
fn config() -> Config {
    let mut config: Config = serde_json::from_str("{}").expect("the configuration parses");
    config.path = PathBuf::from("baton.json");
    config
}

/// The documents of `texts`, each a host path and a text.
fn documents(texts: &[(&str, &str)]) -> Vec<Document> {
    texts
        .iter()
        .enumerate()
        .map(|(index, (path, text))| Document {
            path: PathBuf::from(path),
            index,
            start: Position { line: 1, column: 1 },
            text: text.to_string(),
            embedded: None,
        })
        .collect()
}

/// The plan of `texts` spreading the fragments of `bases`, or its errors
/// rendered against the documents.
fn compiled(texts: &[(&str, &str)], bases: &[Base]) -> Result<Plan, Vec<Rendered>> {
    let (sdl, path) = schema();
    let documents = documents(texts);
    compile_with_bases(&one_file(&sdl, &path), &documents, &config(), bases)
        .map(|compiled| compiled.plan)
        .map_err(|errors| {
            errors
                .iter()
                .map(|error| crate::diagnostics::render(error, &documents))
                .collect()
        })
}

/// The plan of `texts` spreading the fragments of `bases`.
fn plan(texts: &[(&str, &str)], bases: &[Base]) -> Plan {
    compiled(texts, bases).unwrap_or_else(|errors| panic!("the documents compile: {errors:?}"))
}

/// The errors of `texts` spreading the fragments of `bases`.
fn errors(texts: &[(&str, &str)], bases: &[Base]) -> Vec<Rendered> {
    match compiled(texts, bases) {
        Ok(_) => panic!("the documents do not compile"),
        Err(errors) => errors,
    }
}

/// The fragments file of the target `texts`, generated in `module`.
fn fragments_file(module: Option<&str>, texts: &[(&str, &str)]) -> String {
    let home = Home {
        module: module.map(str::to_string),
        ..Home::default()
    };
    crate::report::fragments_text(&plan(texts, &[]), Path::new("/nowhere"), &home)
}

/// The base the target `texts`, generated in `module`, is to a dependent
/// that reads its fragments file at `path`.
fn base(path: &str, module: Option<&str>, texts: &[(&str, &str)]) -> Base {
    Base::parse(path, &fragments_file(module, texts))
        .unwrap_or_else(|error| panic!("the fragments file reads as a base: {error}"))
}

/// The Swift of `plan`.
fn swift(plan: &Plan) -> Output {
    crate::emit::swift(plan, &config()).unwrap_or_else(|errors| panic!("{errors:?}"))
}

/// The file `output` writes for `source`.
fn file<'a>(output: &'a Output, source: &str) -> &'a str {
    output
        .files
        .get(source)
        .unwrap_or_else(|| panic!("nothing is written for `{source}`"))
}

/// The fragment of `plan` named `name`.
fn fragment<'a>(plan: &'a Plan, name: &str) -> &'a crate::pipeline::FragmentPlan {
    plan.fragments
        .iter()
        .find(|fragment| fragment.name == name)
        .unwrap_or_else(|| panic!("the plan has no fragment `{name}`"))
}

const SHARED: &str = "Shared.graphql";
const SCREEN: &str = "Screen.graphql";
const BASE_PATH: &str = "out/shared/fragments.json";

const STATUS: &str = "fragment CharacterStatus_character on Character { status species }";
const ROW: &str =
    "fragment CharacterRow_character on Character { name ...CharacterStatus_character }";
const ROW_QUERY: &str = "query RowQuery { character(id: \"1\") { id ...CharacterRow_character } }";

/// The base declaring `CharacterStatus_character`, in the module `Shared`.
fn status_base() -> Base {
    base(BASE_PATH, Some("Shared"), &[(SHARED, STATUS)])
}

#[test]
fn a_spread_of_a_base_fragment_reads_through_the_base_s_lens() {
    let plan = plan(&[(SCREEN, ROW), (SCREEN, ROW_QUERY)], &[status_base()]);
    let status = fragment(&plan, "CharacterStatus_character");
    assert_eq!(
        status.base.as_ref().map(|base| base.module.as_deref()),
        Some(Some("Shared"))
    );
    assert_eq!(status.source, SHARED);
    assert!(fragment(&plan, "CharacterRow_character").base.is_none());

    let output = swift(&plan);
    let text = file(&output, SCREEN);
    assert!(
        text.contains("@_spi(Generated) import Baton\n@_spi(Generated) import Shared\n"),
        "{text}"
    );
    assert!(
        text.contains(
            "@MainActor public var characterStatus: CharacterStatus_character { .init(anchor: anchor.entering()) }"
        ),
        "{text}"
    );
    assert!(!text.contains("struct CharacterStatus_character"), "{text}");
    assert!(
        !output.files.contains_key(SHARED),
        "{:?}",
        output.files.keys()
    );

    let operation = &plan.operations[0];
    assert!(
        operation
            .text
            .contains("fragment CharacterStatus_character on Character{status,species}"),
        "{}",
        operation.text
    );
    assert!(
        text.contains(".scalar(\"status\", key: .fixed(Slots.Character.status)"),
        "{text}"
    );
    assert!(
        text.contains(".scalar(\"species\", key: .fixed(Slots.Character.species)"),
        "{text}"
    );
}

#[test]
fn a_target_without_bases_imports_no_module() {
    let plan = plan(&[(SCREEN, STATUS), (SCREEN, ROW), (SCREEN, ROW_QUERY)], &[]);
    let output = swift(&plan);
    let text = file(&output, SCREEN);
    assert!(
        text.starts_with(
            "// Generated by batonc. Do not edit.\nimport Foundation\n@_spi(Generated) import Baton\n\n"
        ),
        "{text}"
    );
}

#[test]
fn a_compilation_includes_only_the_base_fragments_it_reaches() {
    let mut shared = base(
        BASE_PATH,
        Some("Shared"),
        &[
            (
                SHARED,
                "fragment A_character on Character { name ...B_character }",
            ),
            (SHARED, "fragment B_character on Character { status }"),
        ],
    );
    // An unreached fragment is not even parsed: its text is not GraphQL.
    shared.fragments.push(BaseFragment {
        name: "C_character".to_string(),
        source: SHARED.to_string(),
        text: "fragment C_character on Character {".to_string(),
        package: None,
    });
    let plan = plan(
        &[(
            SCREEN,
            "query AQuery { character(id: \"1\") { id ...A_character } }",
        )],
        &[shared],
    );
    let mut bases: Vec<&str> = plan
        .fragments
        .iter()
        .filter(|fragment| fragment.base.is_some())
        .map(|fragment| fragment.name.as_str())
        .collect();
    bases.sort();
    assert_eq!(bases, ["A_character", "B_character"]);
    assert_eq!(plan.fragments.len(), 2);
    assert!(!plan.operations[0].text.contains("C_character"));
}

#[test]
fn a_base_compiled_against_another_digest_is_an_error_at_the_configuration() {
    let mut shared = status_base();
    shared.schema_digest = "00000000000000000000000000000000".to_string();
    let errors = errors(&[(SCREEN, ROW), (SCREEN, ROW_QUERY)], &[shared]);
    assert_eq!(errors.len(), 1, "{errors:?}");
    assert_eq!(
        (errors[0].path.as_str(), errors[0].line, errors[0].column),
        ("baton.json", 1, 1)
    );
    assert!(
        errors[0].message.starts_with(&format!(
            "the base `{BASE_PATH}` was compiled against another schema"
        )),
        "{}",
        errors[0].message
    );
    assert!(
        errors[0]
            .message
            .contains("its digest is `00000000000000000000000000000000`"),
        "{}",
        errors[0].message
    );
}

#[test]
fn a_fragment_the_target_and_a_base_both_declare_is_an_error_at_the_target_s_fragment() {
    let errors = errors(
        &[
            (
                SCREEN,
                "fragment CharacterStatus_character on Character { name }",
            ),
            (
                SCREEN,
                "query StatusQuery { character(id: \"1\") { id ...CharacterStatus_character } }",
            ),
        ],
        &[status_base()],
    );
    assert_eq!(errors.len(), 1, "{errors:?}");
    assert_eq!(
        (errors[0].path.as_str(), errors[0].line, errors[0].column),
        (SCREEN, 1, 10)
    );
    assert_eq!(
        errors[0].message,
        format!(
            "the base `{BASE_PATH}` declares a fragment `CharacterStatus_character` too, in `{SHARED}`: a fragment's name is unique among a target and its bases, so rename this one"
        )
    );
}

#[test]
fn two_bases_declaring_one_fragment_is_an_error_naming_both() {
    let first = status_base();
    let second = base(
        "out/other/fragments.json",
        Some("Other"),
        &[("Other.graphql", STATUS)],
    );
    let errors = errors(&[(SCREEN, ROW), (SCREEN, ROW_QUERY)], &[first, second]);
    assert_eq!(errors.len(), 1, "{errors:?}");
    assert_eq!(
        errors[0].message,
        format!(
            "two bases declare the fragment `CharacterStatus_character`: `{BASE_PATH}`, in `{SHARED}`, and `out/other/fragments.json`, in `Other.graphql`; a fragment's name is unique among a target and its bases"
        )
    );
    assert_eq!(errors[0].path, "out/other/fragments.json");
}

#[test]
fn a_base_fragment_spreading_what_no_base_declares_is_an_error_naming_both_and_the_base() {
    let mut shared = base(
        BASE_PATH,
        Some("Shared"),
        &[
            (
                SHARED,
                "fragment A_character on Character { name ...B_character }",
            ),
            (SHARED, "fragment B_character on Character { status }"),
        ],
    );
    shared
        .fragments
        .retain(|fragment| fragment.name != "B_character");
    let errors = errors(
        &[(
            SCREEN,
            "query AQuery { character(id: \"1\") { id ...A_character } }",
        )],
        &[shared],
    );
    assert_eq!(errors.len(), 1, "{errors:?}");
    assert_eq!(errors[0].path, BASE_PATH);
    assert_eq!(
        errors[0].message,
        format!(
            "the fragment `A_character` of the base `{BASE_PATH}` spreads `B_character`, which no base given declares: pass the base of the target that declares it"
        )
    );
}

#[test]
fn a_swift_target_whose_reached_base_names_no_module_is_an_error_naming_the_option() {
    let unnamed = base(BASE_PATH, None, &[(SHARED, STATUS)]);
    let errors = errors(&[(SCREEN, ROW), (SCREEN, ROW_QUERY)], &[unnamed]);
    assert_eq!(errors.len(), 1, "{errors:?}");
    assert_eq!(errors[0].path, BASE_PATH);
    assert_eq!(
        errors[0].message,
        format!(
            "the base `{BASE_PATH}` names no module, and `CharacterStatus_character` is read through the lens its module declares: pass `--module` to the `generate` that writes it"
        )
    );
}

#[test]
fn an_unreached_base_without_a_module_is_not_an_error() {
    let unnamed = base(
        "out/unnamed/fragments.json",
        None,
        &[(
            "Unnamed.graphql",
            "fragment Lonely_character on Character { name }",
        )],
    );
    let plan = plan(
        &[(SCREEN, ROW), (SCREEN, ROW_QUERY)],
        &[status_base(), unnamed],
    );
    assert!(
        plan.fragments
            .iter()
            .all(|fragment| fragment.name != "Lonely_character")
    );
}

/// The errors of `texts`, compiled for Kotlin with the shared file in
/// `package`, spreading the fragments of `bases`.
fn kotlin_errors(package: Option<&str>, texts: &[(&str, &str)], bases: &[Base]) -> Vec<Rendered> {
    let (sdl, path) = schema();
    let documents = documents(texts);
    let text = match package {
        Some(package) => format!("{{\"kotlin\": {{\"package\": {package:?}}}}}"),
        None => "{}".to_string(),
    };
    let mut config: Config = serde_json::from_str(&text).expect("the configuration parses");
    config.path = PathBuf::from("baton.json");
    config.language = crate::config::Language::Kotlin;
    match compile_with_bases(&one_file(&sdl, &path), &documents, &config, bases) {
        Ok(_) => panic!("the documents do not compile"),
        Err(errors) => errors
            .iter()
            .map(|error| crate::diagnostics::render(error, &documents))
            .collect(),
    }
}

#[test]
fn a_kotlin_base_whose_shared_file_is_in_the_target_s_package_is_an_error_at_the_configuration_even_unreached()
 {
    let clashing = base(BASE_PATH, Some("app.generated"), &[(SHARED, STATUS)]);
    let errors = kotlin_errors(
        Some("app.generated"),
        &[(
            SCREEN,
            "query NameQuery { character(id: \"1\") { id name } }",
        )],
        &[clashing],
    );
    assert_eq!(errors.len(), 1, "{errors:?}");
    assert_eq!(errors[0].path, "baton.json");
    assert_eq!(
        errors[0].message,
        format!(
            "the base `{BASE_PATH}` declares its shared file in the Kotlin package `app.generated`, and so does this target: an app cannot hold both, so name another `kotlin.package` for one of them"
        )
    );
}

#[test]
fn two_kotlin_bases_whose_shared_files_are_in_one_package_are_an_error_at_the_second_naming_both() {
    let first = base(BASE_PATH, Some("app.base"), &[(SHARED, STATUS)]);
    let second = base(
        "out/other/fragments.json",
        Some("app.base"),
        &[(
            "Other.graphql",
            "fragment Lonely_character on Character { name }",
        )],
    );
    let errors = kotlin_errors(
        Some("app.generated"),
        &[(SCREEN, ROW), (SCREEN, ROW_QUERY)],
        &[first, second],
    );
    assert_eq!(errors.len(), 1, "{errors:?}");
    assert_eq!(errors[0].path, "out/other/fragments.json");
    assert_eq!(
        errors[0].message,
        format!(
            "the bases `{BASE_PATH}` and `out/other/fragments.json` both declare their shared file in the Kotlin package `app.base`: an app cannot hold both, so name another `kotlin.package` for one of them"
        )
    );
}

#[test]
fn kotlin_bases_in_the_default_package_are_an_error_that_spells_it_as_kotlin_s_default_package() {
    let first = base(BASE_PATH, None, &[(SHARED, STATUS)]);
    let second = base(
        "out/other/fragments.json",
        None,
        &[(
            "Other.graphql",
            "fragment Lonely_character on Character { name }",
        )],
    );
    let errors = kotlin_errors(
        Some("app.generated"),
        &[(SCREEN, ROW), (SCREEN, ROW_QUERY)],
        &[first, second],
    );
    assert_eq!(errors.len(), 1, "{errors:?}");
    assert_eq!(
        errors[0].message,
        format!(
            "the bases `{BASE_PATH}` and `out/other/fragments.json` both declare their shared file in Kotlin's default package: an app cannot hold both, so name another `kotlin.package` for one of them"
        )
    );
    let own = base(BASE_PATH, None, &[(SHARED, STATUS)]);
    let errors = kotlin_errors(None, &[(SCREEN, ROW), (SCREEN, ROW_QUERY)], &[own]);
    assert_eq!(errors.len(), 1, "{errors:?}");
    assert_eq!(
        errors[0].message,
        format!(
            "the base `{BASE_PATH}` declares its shared file in Kotlin's default package, and so does this target: an app cannot hold both, so name another `kotlin.package` for one of them"
        )
    );
}

#[test]
fn a_swift_target_is_not_checked_for_bases_that_share_a_module() {
    let other = base(
        "out/other/fragments.json",
        Some("Shared"),
        &[(
            "Other.graphql",
            "fragment Lonely_character on Character { name }",
        )],
    );
    let plan = plan(
        &[(SCREEN, ROW), (SCREEN, ROW_QUERY)],
        &[status_base(), other],
    );
    assert!(
        plan.fragments
            .iter()
            .any(|fragment| fragment.name == "CharacterStatus_character")
    );
}

#[test]
fn a_base_fragment_with_argument_definitions_binds_at_a_site_of_the_spreading_target() {
    let shared = base(
        BASE_PATH,
        Some("Shared"),
        &[(
            SHARED,
            "fragment CharacterStatus_character on Character @argumentDefinitions(full: {type: \"Boolean\", defaultValue: false}) { status species origin @include(if: $full) { name } }",
        )],
    );
    let plan = plan(
        &[
            (
                SCREEN,
                "fragment CharacterRow_character on Character { name ...CharacterStatus_character @arguments(full: true) }",
            ),
            (SCREEN, ROW_QUERY),
        ],
        &[shared],
    );
    let output = swift(&plan);
    let text = file(&output, SCREEN);
    assert!(
        text.contains(
            "@MainActor public var characterStatus: CharacterStatus_character {\n        let bound = anchor.binding(Sites.CharacterRow_character_characterStatus) { () -> [String: Baton.Variable?] in [\"full\": .bool(true)] }\n        return .init(anchor: bound.entering())\n    }"
        ),
        "{text}"
    );
    assert!(!text.contains("struct CharacterStatus_character"), "{text}");
    assert!(
        output
            .shared
            .contains("CharacterRow_character_characterStatus"),
        "{}",
        output.shared
    );

    // Relay prints the spread with its arguments as a clone of the fragment
    // named with a hash of them, which is what the server is sent.
    let operation = &plan.operations[0];
    let clone = operation
        .text
        .split("fragment ")
        .find(|definition| definition.starts_with("CharacterStatus_character_"))
        .unwrap_or_else(|| panic!("no clone of the base fragment in {}", operation.text));
    assert!(
        clone.ends_with("on Character{status,species,origin{name,id}}"),
        "{clone}"
    );
    assert!(
        operation.text.contains(&format!(
            "...{}",
            clone.split(' ').next().unwrap_or_default()
        )),
        "{}",
        operation.text
    );
    assert!(!operation.text.contains("@argumentDefinitions"));
}

#[test]
fn a_base_fragment_whose_required_child_can_null_it_makes_the_spread_optional() {
    let shared = base(
        BASE_PATH,
        Some("Shared"),
        &[(
            SHARED,
            "fragment Named_character on Character { name @required(action: NONE) }",
        )],
    );
    let plan = plan(
        &[
            (
                SCREEN,
                "fragment Row_character on Character { ...Named_character }",
            ),
            (
                SCREEN,
                "query RowQuery { character(id: \"1\") { id ...Row_character } }",
            ),
        ],
        &[shared],
    );
    let output = swift(&plan);
    let text = file(&output, SCREEN);
    assert!(
        text.contains(
            "@MainActor public var named: Named_character? {\n        typealias Fragment = Named_character\n        guard Fragment.satisfied(anchor) else { return nil }\n        return .init(anchor: anchor.entering())\n    }"
        ),
        "{text}"
    );
}

#[test]
fn a_base_fragment_that_throws_on_field_error_makes_the_spread_throwing() {
    let shared = base(
        BASE_PATH,
        Some("Shared"),
        &[(
            SHARED,
            "fragment Strict_character on Character @throwOnFieldError { name }",
        )],
    );
    let plan = plan(
        &[
            (
                SCREEN,
                "fragment Row_character on Character { ...Strict_character }",
            ),
            (
                SCREEN,
                "query RowQuery { character(id: \"1\") { id ...Row_character } }",
            ),
        ],
        &[shared],
    );
    let output = swift(&plan);
    let text = file(&output, SCREEN);
    assert!(
        text.contains(
            "@MainActor public var strict: Strict_character { get throws { try .throwing(anchor.entering()) } }"
        ),
        "{text}"
    );
}

/// The base of the refusals: a lens and a value.
fn refusal_base() -> Base {
    base(
        BASE_PATH,
        Some("Shared"),
        &[
            (SHARED, "fragment Named_character on Character { name }"),
            (
                SHARED,
                "fragment Value_character on Character @inline { name }",
            ),
        ],
    )
}

/// The refusals of `texts` over the refusal base.
fn refusals(texts: &[(&str, &str)]) -> Vec<String> {
    crate::decide::unbuilt_base_spreads(&plan(texts, &[refusal_base()]))
        .into_iter()
        .map(|spread| spread.message)
        .collect()
}

#[test]
fn a_base_fragment_spread_under_defer_is_refused_naming_it() {
    let refused = refusals(&[(
        SCREEN,
        "query DeferQuery { character(id: \"1\") { id ...Named_character @defer } }",
    )]);
    assert_eq!(
        refused,
        [
            "`...Named_character` under `@defer`: `Named_character` is a base's fragment, and the check that its part arrived is generated only where its own target asks for it; a base fragment under `@defer` is not built yet"
        ]
    );
}

#[test]
fn a_base_fragment_spread_under_an_aliased_catch_is_refused_naming_it() {
    let refused = refusals(&[(
        SCREEN,
        "query CatchQuery { character(id: \"1\") { id ... @alias(as: \"named\") @catch { ...Named_character } } }",
    )]);
    assert_eq!(
        refused,
        [
            "`...Named_character` under `@catch`: `Named_character` is a base's fragment, and the read of its field errors is generated only where its own target asks for it; a base fragment under `@catch` is not built yet"
        ]
    );
}

#[test]
fn a_base_value_spread_inside_a_value_that_reads_its_field_errors_is_refused_naming_it() {
    let refused = refusals(&[
        (
            SCREEN,
            "fragment Own_character on Character @inline @throwOnFieldError { ...Value_character }",
        ),
        (
            SCREEN,
            "query OwnQuery { character(id: \"1\") { id ...Own_character } }",
        ),
    ]);
    assert_eq!(
        refused,
        [
            "`Own_character` reads its field errors and spreads `Value_character`, a base's value, whose errors are read only where its own target asks for them; not built yet"
        ]
    );
}

#[test]
fn a_base_value_spread_where_no_errors_are_asked_compiles() {
    let texts = [
        (
            SCREEN,
            "fragment Own_character on Character @inline { ...Value_character }",
        ),
        (
            SCREEN,
            "query OwnQuery { character(id: \"1\") { id ...Own_character } }",
        ),
    ];
    assert!(refusals(&texts).is_empty());
    let output = swift(&plan(&texts, &[refusal_base()]));
    let text = file(&output, SCREEN);
    assert!(
        text.contains("public let value: Value_character\n"),
        "{text}"
    );
    assert!(!text.contains("struct Value_character"), "{text}");
}

const EPISODE_STATUS: &str = "fragment EpisodeStatus_episode on Episode { status }";
const EPISODE_QUERY: &str =
    "query EpisodeQuery { episode(id: \"1\") { id ...EpisodeStatus_episode } }";

#[test]
fn an_enum_only_a_base_fragment_reads_is_not_generated_by_the_dependent() {
    let shared = base(BASE_PATH, Some("Shared"), &[(SHARED, EPISODE_STATUS)]);
    let plan = plan(&[(SCREEN, EPISODE_QUERY)], &[shared]);
    assert!(
        !plan.enums.contains_key("EpisodeStatus"),
        "{:?}",
        plan.enums
    );
    let output = swift(&plan);
    assert!(
        !output.shared.contains("enum EpisodeStatus"),
        "{}",
        output.shared
    );
}

#[test]
fn an_enum_the_dependent_s_own_fragment_also_reads_is_generated_by_it() {
    let shared = base(BASE_PATH, Some("Shared"), &[(SHARED, EPISODE_STATUS)]);
    let plan = plan(
        &[
            (SCREEN, "fragment Own_episode on Episode { status }"),
            (
                SCREEN,
                "query EpisodeQuery { episode(id: \"1\") { id ...EpisodeStatus_episode ...Own_episode } }",
            ),
        ],
        &[shared],
    );
    assert!(plan.enums.contains_key("EpisodeStatus"), "{:?}", plan.enums);
    let output = swift(&plan);
    assert!(
        output.shared.contains("enum EpisodeStatus"),
        "{}",
        output.shared
    );
}

const COUNT: &str = "fragment Count_query on Query @argumentDefinitions(filter: {type: \"FilterCharacter\"}) { characters(filter: $filter) { info { count } } }";

#[test]
fn an_input_object_only_a_base_fragment_s_argument_names_is_not_generated_by_the_dependent() {
    let shared = base(BASE_PATH, Some("Shared"), &[(SHARED, COUNT)]);
    let plan = plan(
        &[(
            SCREEN,
            "query CountQuery { ...Count_query @arguments(filter: {name: \"Rick\"}) }",
        )],
        &[shared],
    );
    assert!(
        !plan.inputs.contains_key("FilterCharacter"),
        "{:?}",
        plan.inputs.keys()
    );
}

#[test]
fn an_input_object_the_dependent_s_own_operation_names_is_generated_by_it() {
    let shared = base(BASE_PATH, Some("Shared"), &[(SHARED, COUNT)]);
    let plan = plan(
        &[(
            SCREEN,
            "query CountQuery($filter: FilterCharacter) { ...Count_query @arguments(filter: $filter) }",
        )],
        &[shared],
    );
    assert!(
        plan.inputs.contains_key("FilterCharacter"),
        "{:?}",
        plan.inputs.keys()
    );
}

#[test]
fn a_base_s_refetchable_fragment_derives_no_refetch_query_in_the_dependent() {
    let shared = base(
        BASE_PATH,
        Some("Shared"),
        &[(
            SHARED,
            "fragment Refetch_character on Character @refetchable(queryName: \"RefetchCharacterQuery\") { name }",
        )],
    );
    let plan = plan(
        &[(
            SCREEN,
            "query RowQuery { character(id: \"1\") { id ...Refetch_character } }",
        )],
        &[shared],
    );
    let names: Vec<&str> = plan
        .operations
        .iter()
        .map(|operation| operation.name.as_str())
        .collect();
    assert_eq!(names, ["RowQuery"]);
    let output = swift(&plan);
    let text = file(&output, SCREEN);
    assert!(!text.contains("RefetchCharacterQuery"), "{text}");
    assert!(
        !output.shared.contains("RefetchCharacterQuery"),
        "{}",
        output.shared
    );
}

/// The report `generate --report` writes for `plan`, in `home`.
fn report_json(plan: &Plan, home: &Home) -> (String, serde_json::Value) {
    let program = crate::decide::program(plan, &crate::names::SwiftNaming::default().into())
        .unwrap_or_else(|errors| panic!("{errors:?}"));
    let text = crate::report::text(plan, Path::new("/nowhere"), &program, home);
    let value = serde_json::from_str(&text).expect("the report is JSON");
    (text, value)
}

/// The keys of a JSON object, in the order written.
fn keys(text: &str) -> Vec<String> {
    let value: serde_json::Value = serde_json::from_str(text).expect("the text is JSON");
    let object = value.as_object().expect("the text is an object");
    let mut keys: Vec<(usize, String)> = object
        .keys()
        .map(|key| {
            let at = text
                .find(&format!("\n  \"{key}\":"))
                .unwrap_or_else(|| panic!("`{key}` is a key of the head"));
            (at, key.clone())
        })
        .collect();
    keys.sort();
    keys.into_iter().map(|(_, key)| key).collect()
}

#[test]
fn a_dependent_s_report_lists_its_own_fragments_and_its_operations_reach_the_base_s() {
    let plan = plan(&[(SCREEN, ROW), (SCREEN, ROW_QUERY)], &[status_base()]);
    let home = Home {
        module: Some("Screens".to_string()),
        ..Home::default()
    };
    let (text, report) = report_json(&plan, &home);
    assert!(text.starts_with("{\n  \"format\": 1,\n"), "{text}");
    assert_eq!(
        keys(&text),
        [
            "format",
            "schemaDigest",
            "module",
            "operations",
            "fragments"
        ]
    );
    assert_eq!(report["module"], "Screens");
    assert_eq!(report["schemaDigest"], plan.schema_digest.as_str());
    let fragments: Vec<&str> = report["fragments"]
        .as_array()
        .expect("the fragments are a list")
        .iter()
        .filter_map(|fragment| fragment["name"].as_str())
        .collect();
    assert_eq!(fragments, ["CharacterRow_character"]);
    assert_eq!(
        report["operations"][0]["fragments"],
        serde_json::json!(["CharacterRow_character", "CharacterStatus_character"])
    );
}

#[test]
fn a_report_without_a_module_has_no_module_in_its_head() {
    let plan = plan(&[(SCREEN, ROW), (SCREEN, ROW_QUERY)], &[status_base()]);
    let (text, _) = report_json(&plan, &Home::default());
    assert_eq!(
        keys(&text),
        ["format", "schemaDigest", "operations", "fragments"]
    );
}

#[test]
fn the_fragments_file_holds_the_head_and_what_a_dependent_reads_of_each_fragment() {
    let texts = [(SHARED, STATUS), (SHARED, ROW), (SHARED, ROW_QUERY)];
    let text = fragments_file(Some("Shared"), &texts);
    assert_eq!(
        keys(&text),
        ["format", "schemaDigest", "module", "fragments"]
    );
    let file: serde_json::Value = serde_json::from_str(&text).expect("the file is JSON");
    assert_eq!(file["format"], FORMAT);
    assert_eq!(file["module"], "Shared");
    assert_eq!(
        file["schemaDigest"],
        plan(&texts, &[]).schema_digest.as_str()
    );
    let fragments = file["fragments"]
        .as_array()
        .expect("the fragments are a list");
    let names: Vec<&str> = fragments
        .iter()
        .filter_map(|fragment| fragment["name"].as_str())
        .collect();
    assert_eq!(
        names,
        ["CharacterRow_character", "CharacterStatus_character"]
    );
    for fragment in fragments {
        let mut fields: Vec<&str> = fragment
            .as_object()
            .expect("a fragment is an object")
            .keys()
            .map(String::as_str)
            .collect();
        fields.sort();
        assert_eq!(fields, ["name", "source", "text", "type"]);
    }
    assert_eq!(
        fragments[1],
        serde_json::json!({
            "name": "CharacterStatus_character",
            "type": "Character",
            "source": SHARED,
            "text": "fragment CharacterStatus_character on Character {\n  status\n  species\n}",
        })
    );
    assert!(!text.contains("RowQuery"), "{text}");
}

#[test]
fn a_report_and_a_fragments_file_read_as_the_same_base() {
    let texts = [(SHARED, STATUS), (SHARED, ROW), (SHARED, ROW_QUERY)];
    let plan = plan(&texts, &[]);
    let home = Home {
        module: Some("Shared".to_string()),
        ..Home::default()
    };
    let (report, _) = report_json(&plan, &home);
    let fragments = crate::report::fragments_text(&plan, Path::new("/nowhere"), &home);
    let from_report = Base::parse(BASE_PATH, &report).unwrap_or_else(|error| panic!("{error}"));
    let from_fragments =
        Base::parse(BASE_PATH, &fragments).unwrap_or_else(|error| panic!("{error}"));
    assert_eq!(from_report, from_fragments);
    assert_eq!(from_report.module.as_deref(), Some("Shared"));
    assert_eq!(from_report.fragments.len(), 2);
}

#[test]
fn a_base_of_another_format_is_refused_naming_both_formats() {
    let text = fragments_file(Some("Shared"), &[(SHARED, STATUS)]).replacen(
        "\"format\": 1,",
        "\"format\": 2,",
        1,
    );
    let refused = Base::parse(BASE_PATH, &text).expect_err("another format is refused");
    assert!(matches!(refused, BaseError::Format { .. }));
    assert_eq!(
        refused.to_string(),
        format!(
            "{BASE_PATH}:1:1: error: the base's report is of format 2, and this `batonc` reads format 1: generate the base with the `batonc` that compiles this target"
        )
    );
}

#[test]
fn a_base_of_no_format_is_refused_naming_both_formats() {
    let text =
        fragments_file(Some("Shared"), &[(SHARED, STATUS)]).replacen("\"format\": 1,", "", 1);
    let refused = Base::parse(BASE_PATH, &text).expect_err("no format is refused");
    assert_eq!(
        refused.to_string(),
        format!(
            "{BASE_PATH}:1:1: error: the base's report is of format none, and this `batonc` reads format 1: generate the base with the `batonc` that compiles this target"
        )
    );
}

#[test]
fn a_file_that_is_not_a_report_is_refused() {
    let refused = Base::parse(BASE_PATH, "[]").expect_err("a list is no report");
    assert!(matches!(refused, BaseError::Json { .. }));
    assert!(
        refused.to_string().starts_with(&format!(
            "{BASE_PATH}:1:1: error: the base is not a report `batonc generate` wrote: "
        )),
        "{refused}"
    );
}

#[path = "support.rs"]
#[allow(
    clippy::duplicate_mod,
    reason = "no test module is the whole crate's, so each that needs the helpers includes them"
)]
mod support;
