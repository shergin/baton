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
fn equality_and_hash_read_the_variables_and_never_the_resolution() {
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
fn a_mutation_carries_no_resolution_and_a_subscription_its_own_handle() {
    let mutation = emitted(
        "Screen.kt",
        Some("app.generated"),
        "mutation Probe($id: ID!) { setFavorite(id: $id, favorite: true) { character { id } } }",
    );
    let text = file(&mutation);
    assert!(text.contains(": MutationOperation<Probe.Data>"));
    assert!(!text.contains("resolution"));
    assert!(text.contains("override val kind = OperationKind.MUTATION"));
    let subscription = emitted(
        "Screen.kt",
        Some("app.generated"),
        "subscription Probe($id: ID!) { noteAdded(characterId: $id) { character { id } } }",
    );
    assert!(file(&subscription).contains(
        "override var resolution: Resolution<SubscriptionHandle<Data>> = Resolution.Unresolved"
    ));
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
fn every_selection_is_its_own_lazy_declaration() {
    let output = emitted(
        "Screen.kt",
        Some("app.generated"),
        "query Probe { characters { info { count } } }",
    );
    let text = file(&output);
    assert!(text.contains("override val plan: Plan by lazy { Plan(root = selection0) }"));
    for number in 0..3 {
        assert!(text.contains(&format!(
            "private val selection{number}: Selection by lazy {{"
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
