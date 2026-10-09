//! Tests of the Kotlin emitter on single documents: the variables rule, the
//! equality of an operation value, each kind's interface, a mapped scalar's
//! type and converter, and the package a file takes.

use std::path::{Path, PathBuf};

use super::*;
use crate::config::{ConvertedType, HostType, HostTypes, KotlinConfig, Language};
use crate::documents::Document;
use crate::pipeline;

/// The configuration of a Kotlin run in the package `app.generated`, with
/// `Decimal` read as a `java.math.BigDecimal`.
fn config() -> Config {
    let mut config = Config {
        language: Language::Kotlin,
        kotlin: Some(KotlinConfig {
            package: Some("app.generated".to_string()),
        }),
        ..Config::default()
    };
    config.custom_scalar_types.insert(
        "Decimal".to_string(),
        HostTypes::ByLanguage(BTreeMap::from([(
            "kotlin".to_string(),
            HostType::Converted(ConvertedType {
                type_name: "java.math.BigDecimal".to_string(),
                converter: "app.Decimals".to_string(),
            }),
        )])),
    );
    config
}

/// The Kotlin of `text`, the documents of the host `path` in `package`,
/// compiled against the test schema.
fn emitted(path: &str, package: Option<&str>, text: &str) -> Output {
    let schema_path = Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("the compiler sits one level below the repository root")
        .join("spec/tests/schema.graphql");
    let schema = std::fs::read_to_string(&schema_path).expect("the test schema is readable");
    let document = Document {
        path: PathBuf::from(path),
        index: 0,
        start: crate::documents::Position { line: 1, column: 1 },
        text: text.to_string(),
        embedded: None,
    };
    let config = config();
    let compiled = pipeline::compile(
        &schema,
        &schema_path.to_string_lossy(),
        &[],
        &[document],
        &config,
    )
    .unwrap_or_else(|errors| panic!("the document does not compile: {errors:?}"));
    // A Kotlin host declares its package, the default one when none; a
    // `.graphql` source declares none and takes the shared one.
    let mut packages = BTreeMap::new();
    if path.ends_with(".kt") {
        packages.insert(path.to_string(), package.map(str::to_string));
    }
    let target = Kotlin::new(&config, packages);
    let program = crate::decide::program(&compiled.plan, target.naming())
        .unwrap_or_else(|errors| panic!("the document declares names twice: {errors:?}"));
    target.emit(&program)
}

/// The one file `output` writes for a source.
fn file(output: &Output) -> &str {
    output
        .files
        .values()
        .next()
        .expect("the source writes a file")
}

#[test]
fn a_nullable_variable_without_a_default_is_left_out_when_unset() {
    let output = emitted(
        "Screen.kt",
        Some("app.generated"),
        "query Probe($page: Int) { characters(page: $page) { info { count } } }",
    );
    let text = file(&output);
    assert!(text.contains("class Probe(val page: Int? = null) : QueryOperation<Probe.Data>"));
    assert!(
        text.contains("        get() = Variables.of(\"page\" to page?.let { Variable.of(it) })\n")
    );
}

#[test]
fn a_nullable_variable_with_a_default_is_sent_as_its_default_when_null() {
    let output = emitted(
        "Screen.kt",
        Some("app.generated"),
        "query Probe($page: Int = 2, $id: ID!) { characters(page: $page) { info { count } } character(id: $id) { id } }",
    );
    let text = file(&output);
    assert!(text.contains(
        "Variables.of(\"page\" to (if (page == null) Variable.Int(2) else Variable.of(page)), \"id\" to Variable.of(id))"
    ));
}

#[test]
fn equality_and_hash_read_the_variables_and_nothing_else() {
    let output = emitted(
        "Screen.kt",
        Some("app.generated"),
        "query Probe($id: ID!, $other: ID!) { a: character(id: $id) { id } b: character(id: $other) { id } }",
    );
    let text = file(&output);
    assert!(text.contains(
        "override fun equals(other: Any?): Boolean = other is Probe && other.id == id && other.other == this.other"
    ));
    assert!(text.contains("override fun hashCode(): Int = listOf(id, other).hashCode()"));
}

#[test]
fn every_kind_of_operation_value_is_immutable_and_carries_no_resolution() {
    let kinds = [
        (
            "query Probe($id: ID!) { character(id: $id) { id } }",
            "QueryOperation",
        ),
        (
            "mutation Probe($id: ID!) { setFavorite(id: $id, favorite: true) { character { id } } }",
            "MutationOperation",
        ),
        (
            "subscription Probe($id: ID!) { noteAdded(characterId: $id) { character { id } } }",
            "SubscriptionOperation",
        ),
    ];
    for (document, interface) in kinds {
        let output = emitted("Screen.kt", Some("app.generated"), document);
        let text = file(&output);
        assert!(
            text.contains(&format!(
                "\n@Immutable\nclass Probe(val id: String) : {interface}<Probe.Data> {{\n"
            )),
            "{text}"
        );
        assert!(
            text.contains("\nimport androidx.compose.runtime.Immutable\n"),
            "{text}"
        );
        assert!(
            !text.contains("resolution") && !text.contains("Resolution"),
            "{text}"
        );
    }
}

#[test]
fn a_mapped_scalar_variable_takes_its_configured_type_and_converter() {
    let output = emitted(
        "Screen.kt",
        Some("app.generated"),
        "query Probe($price: Decimal!, $among: [Decimal!]) { assetsPricedAbove(price: $price, among: $among) { uuid } }",
    );
    let text = file(&output);
    assert!(text.contains(
        "class Probe(val price: java.math.BigDecimal, val among: List<java.math.BigDecimal>? = null)"
    ));
    assert!(text.contains("\"price\" to Variable.of(price, app.Decimals)"));
    assert!(text.contains(
        "\"among\" to among?.let { Variable.List(it.map { Variable.of(it, app.Decimals) }) }"
    ));
}

#[test]
fn a_host_in_another_package_imports_the_shared_objects() {
    let output = emitted(
        "Screen.kt",
        Some("app.screens"),
        "query Probe($filter: FilterCharacter) { characters(filter: $filter) { info { count } } }",
    );
    let text = file(&output);
    assert!(text.contains("\npackage app.screens\n"));
    assert!(text.contains("\nimport app.generated.FilterCharacter\n"));
    assert!(text.contains("\nimport app.generated.Slots\n"));
    assert!(text.contains("\nimport app.generated.Types\n"));
    assert!(output.shared.contains("\npackage app.generated\n"));
}

#[test]
fn a_host_in_the_shared_package_imports_only_the_runtime() {
    let output = emitted(
        "Screen.kt",
        Some("app.generated"),
        "query Probe { characters { info { count } } }",
    );
    let text = file(&output);
    assert!(!text.contains("import app.generated."));
    assert!(text.contains("override val variables: Variables\n        get() = Variables.none\n"));
    assert!(text.contains("override fun hashCode(): Int = 0"));
}

#[test]
fn a_graphql_source_takes_the_shared_package() {
    let output = emitted(
        "Screen.graphql",
        None,
        "query Probe { characters { info { count } } }",
    );
    assert!(file(&output).contains("\npackage app.generated\n"));
}

#[test]
fn a_value_s_constructor_reads_each_field_through_a_function_of_its_own() {
    let output = emitted(
        "Screen.kt",
        Some("app.generated"),
        "fragment Probe_character on Character @inline { name origin { id } }",
    );
    let text = file(&output);
    assert!(text.contains(
        "    constructor(anchor: Anchor) : this(\n        `read-name`(anchor),\n        `read-origin`(anchor),\n    )\n"
    ));
    assert!(text.contains(
        "\n        private fun `read-name`(anchor: Anchor): String? = anchor.string(Slots.Character.name)\n"
    ));
    assert!(text.contains(
        "\n        private fun `read-origin`(anchor: Anchor): Origin? = anchor.linked(Slots.Character.origin)?.let { Origin(it) }\n"
    ));
}

#[test]
fn every_selection_is_its_own_lazy_declaration_in_an_object_no_lens_sees() {
    let output = emitted(
        "Screen.kt",
        Some("app.generated"),
        "query Probe { characters { info { count } } }",
    );
    let text = file(&output);
    assert!(
        text.contains("override val plan: Plan by lazy { Plan(root = `Probe-plan`.selection0) }")
    );
    assert!(text.contains("\nprivate object `Probe-plan` {\n"));
    for number in 0..3 {
        assert!(text.contains(&format!(
            "\n    val selection{number}: Selection by lazy {{"
        )));
    }
    assert!(!text.contains("selection3"));
}

#[test]
fn two_variables_the_jvm_names_alike_get_getters_of_their_own() {
    let output = emitted(
        "Screen.kt",
        Some("app.generated"),
        "query Probe($Any: ID!, $any: ID!) { a: character(id: $Any) { id } b: character(id: $any) { id } }",
    );
    assert!(
        file(&output)
            .contains("class Probe(val Any: String, @get:JvmName(\"getAny2\") val any: String)")
    );
}

#[test]
fn a_variable_named_like_a_receiver_property_is_read_by_its_own_name() {
    let output = emitted(
        "Screen.kt",
        Some("app.generated"),
        "query Probe($size: Int, $keys: ID!) { characters(page: $size) { info { count } } character(id: $keys) { id } }",
    );
    let text = file(&output);
    assert!(text.contains(
        "Variables.of(\"size\" to size?.let { Variable.of(it) }, \"keys\" to Variable.of(keys))"
    ));
    assert!(!text.contains("this@"));
}

#[test]
fn a_lens_reads_each_field_through_the_reader_the_swift_lens_calls() {
    let output = emitted(
        "Screen.kt",
        Some("app.generated"),
        "query Probe($id: ID!) { character(id: $id) { name favorite origin { name } episode { name } } }",
    );
    let text = file(&output);
    assert!(text.contains("    @Stable\n    class Data(override val anchor: Anchor) : Lens {\n"));
    assert!(text.contains(
        "val character: Character? get() = anchor.linked(anchor.owner.slot(Slots.Query.character_bca4f9))?.let(::Character)"
    ));
    assert!(text.contains("val name: String? get() = anchor.string(Slots.Character.name)"));
    assert!(text.contains("val favorite: Boolean? get() = anchor.bool(Slots.Character.favorite)"));
    assert!(text.contains(
        "val origin: Origin? get() = anchor.linked(Slots.Character.origin)?.let(::Origin)"
    ));
    assert!(text.contains(
        "val episode: List<Episode> get() = anchor.requiredList(Slots.Character.episode, ::Episode)"
    ));
    assert!(text.contains(
        "override fun equals(other: Any?): Boolean = other is Probe.Data.Character && other.anchor == anchor"
    ));
    assert!(text.contains("\nimport androidx.compose.runtime.Stable\n"));
}

#[test]
fn a_required_field_bubbles_through_the_companion_of_its_lens() {
    let output = emitted(
        "Screen.kt",
        Some("app.generated"),
        "query Probe($id: ID!) { character(id: $id) { ...Profile } } fragment Profile on Character { name @required(action: LOG) }",
    );
    let text = file(&output);
    assert!(text.contains("fun satisfied(anchor: Anchor): Boolean {"));
    assert!(text.contains(
        "if (!anchor.hasValue(Slots.Character.name, \"name\", log = true)) return false"
    ));
    assert!(text.contains("if (!Profile.satisfied(anchor)) return null"));
    assert!(text.contains("return Profile(anchor.entering())"));
}

#[test]
fn a_spread_whose_fragment_a_field_hides_reaches_it_through_the_companion() {
    let output = emitted(
        "Screen.kt",
        Some("app.generated"),
        "query Probe($id: ID!) { character(id: $id) { Profile: name ...Profile } } fragment Profile on Character { name @required(action: LOG) }",
    );
    let text = file(&output);
    assert!(text.contains("if (!Companion.Profile_.satisfied(anchor)) return null"));
    assert!(text.contains("private val Profile_ = Profile"));
}

#[test]
fn an_enum_reads_through_the_generated_of() {
    let output = emitted(
        "Screen.kt",
        Some("app.generated"),
        "mutation Probe { setLists { statuses } }",
    );
    assert!(file(&output).contains(
        "val statuses: List<Status?>? get() = anchor.nullableEnumValues(Slots.ListsPayload.statuses, Status::of)"
    ));
}

#[test]
fn a_mutation_is_called_through_an_invoke_on_its_action() {
    let output = emitted(
        "Screen.kt",
        Some("app.generated"),
        "mutation Probe($id: ID!, $name: String!) { rename(id: $id, name: $name) { character { id name } } }",
    );
    let text = file(&output);
    assert!(text.contains(
        "suspend operator fun MutationAction<Probe, Probe.Data>.invoke(id: String, name: String, optimistic: Probe.OptimisticResponse? = null): Probe.Data = this.commit(Probe(id, name), optimistic?.payload)"
    ));
    assert!(text.contains("class OptimisticResponse(val rename: Rename? = null) {"));
    assert!(text.contains("class Character(val id: String? = null, val name: String? = null) {"));
    assert!(text.contains(
        "get() = Variable.Object(Variables.of(\"id\" to this.id?.let { Variable.of(it) }, \"name\" to this.name?.let { Variable.of(it) }).values)"
    ));
    assert!(text.contains("val payload: Payload get() = Payload(data = variable)"));
}

#[test]
fn a_variable_named_optimistic_moves_the_optimistic_parameter_aside() {
    let output = emitted(
        "Screen.kt",
        Some("app.generated"),
        "mutation Probe($optimistic: ID!) { setFavorite(id: $optimistic, favorite: true) { character { id } } }",
    );
    assert!(file(&output).contains(
        ".invoke(optimistic: String, optimistic2: Probe.OptimisticResponse? = null): Probe.Data = this.commit(Probe(optimistic), optimistic2?.payload)"
    ));
}

#[test]
fn an_enum_value_spelled_like_the_undeclared_case_takes_an_underscore() {
    let shared = crate::decide::Shared {
        enums: BTreeMap::from([(
            "Status".to_string(),
            vec![
                "ALIVE".to_string(),
                "UNDECLARED".to_string(),
                "undeclared".to_string(),
            ],
        )]),
        ..crate::decide::Shared::default()
    };
    let types = BTreeMap::new();
    let text = shared::shared_text(
        &shared,
        &BTreeMap::new(),
        &literal::Converters { types: &types },
        Some("app.generated"),
    );
    assert!(text.contains(
        "data object UNDECLARED_ : Status { override val scalarText: String get() = \"UNDECLARED\" }"
    ));
    assert!(text.contains(
        "data object undeclared_ : Status { override val scalarText: String get() = \"undeclared\" }"
    ));
    assert!(text.contains("data class Undeclared(override val scalarText: String) : Status"));
    assert!(text.contains("\"UNDECLARED\" -> UNDECLARED_\n"));
    assert!(text.contains("else -> Undeclared(text)\n"));
}
