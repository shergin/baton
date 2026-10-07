//! Tests of the Swift pieces every printer writes through: a type as a
//! structure, a scalar's type and reader, a variable's type, a computed
//! property in each of its forms, the local alias a body names a type by,
//! and the head of a check.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use super::*;
use crate::config::Config;
use crate::documents::Document;
use crate::pipeline::{self, TypeKind, TypePlan};

/// The line `property` writes when it reads `expression` under `condition`.
fn one_line(property: Computed, expression: &str, condition: Option<&str>) -> String {
    let mut writer = Writer::new();
    property.reads(&mut writer, expression, condition);
    writer.finish()
}

/// The variables of the one operation in `text`, compiled against the test
/// schema and decided.
fn decided_variables(text: &str) -> Vec<VariableValue> {
    let schema_path = Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("the compiler sits one level below the repository root")
        .join("spec/tests/schema.graphql");
    let schema = std::fs::read_to_string(&schema_path).expect("the test schema is readable");
    let document = Document {
        path: PathBuf::from("Probe.swift"),
        index: 0,
        start: crate::swift::Position { line: 1, column: 1 },
        text: text.to_string(),
        embedded: None,
    };
    let compiled = pipeline::compile(
        &schema,
        &schema_path.to_string_lossy(),
        &[],
        &[document],
        &Config::default(),
    )
    .unwrap_or_else(|errors| panic!("the document does not compile: {errors:?}"));
    let program = crate::decide::program(&compiled.plan, &BTreeMap::new())
        .unwrap_or_else(|errors| panic!("the document declares names twice: {errors:?}"));
    program
        .operations
        .into_iter()
        .next()
        .expect("the document is an operation")
        .variables
}

#[test]
fn a_type_made_optional_twice_is_one_optional() {
    let twice = SwiftType::named("String").optional().optional();
    assert_eq!(twice, SwiftType::named("String").optional());
    assert_eq!(twice.to_string(), "String?");
}

#[test]
fn a_type_is_made_optional_only_when_the_condition_holds() {
    assert_eq!(
        SwiftType::named("Bool").optional_if(false).to_string(),
        "Bool"
    );
    assert_eq!(
        SwiftType::named("Bool").optional_if(true).to_string(),
        "Bool?"
    );
    assert_eq!(
        SwiftType::named("Bool")
            .optional()
            .optional_if(true)
            .to_string(),
        "Bool?"
    );
}

#[test]
fn a_type_prints_as_swift_writes_it_however_it_is_nested() {
    let lens = || SwiftType::named("Friends");
    assert_eq!(
        lens().list().optional().caught().to_string(),
        "Result<Baton.List<Friends>?, Baton.FieldErrors>"
    );
    assert_eq!(
        lens().caught().optional().to_string(),
        "Result<Friends, Baton.FieldErrors>?"
    );
    assert_eq!(
        SwiftType::named("String").optional().caught().to_string(),
        "Result<String?, Baton.FieldErrors>"
    );
    assert_eq!(lens().array().to_string(), "[Friends]");
}

#[test]
fn a_type_a_document_named_like_a_swift_keyword_is_spelled_in_backticks() {
    assert_eq!(SwiftType::named("class").to_string(), "`class`");
    assert_eq!(SwiftType::named("each").optional().to_string(), "`each`?");
    assert_eq!(SwiftType::named("Friends").to_string(), "Friends");
    assert_eq!(
        SwiftType::named("Edges").nested("Node").array().to_string(),
        "[Edges.Node]"
    );
    assert_eq!(
        SwiftType::named("some").nested("_").to_string(),
        "`some`.`_`"
    );
    // The type a declaration is in is Swift's `Self`, never an identifier
    // of that name.
    assert_eq!(
        SwiftType::own().caught().to_string(),
        "Result<Self, Baton.FieldErrors>"
    );
}

#[test]
fn the_runtime_is_named_by_its_module_in_a_type_and_in_an_expression() {
    assert_eq!(SwiftType::runtime("Anchor").to_string(), "Baton.Anchor");
    assert_eq!(
        SwiftType::runtime("FieldError").array().to_string(),
        "[Baton.FieldError]"
    );
    assert_eq!(runtime_value("Variables"), "Baton.Variables");
}

/// The scalar shape of a nullable `primitive`, or of a nullable list of it
/// whose elements are non-null or not.
fn shape_of(primitive: Primitive, elements_non_null: Option<bool>) -> ScalarShape {
    // A mapped scalar is named for the Swift type it reads as, and mapped
    // to that type.
    let (kind, name) = match &primitive {
        Primitive::String => (TypeKind::String, None),
        Primitive::Int => (TypeKind::Int, None),
        Primitive::Double => (TypeKind::Float, None),
        Primitive::Bool => (TypeKind::Boolean, None),
        Primitive::Mapped(name) => (TypeKind::CustomScalar, Some(name.clone())),
        Primitive::Enum(name) => (TypeKind::Enum, Some(name.clone())),
    };
    let name = name.unwrap_or_else(|| format!("{kind:?}"));
    let host_types: BTreeMap<String, String> = match &primitive {
        Primitive::Mapped(_) => BTreeMap::from([(name.clone(), name.clone())]),
        _ => BTreeMap::new(),
    };
    let element = TypePlan::Named {
        name,
        kind,
        non_null: elements_non_null.unwrap_or(false),
        mapped: primitive.is_mapped(),
    };
    let type_ = match elements_non_null {
        None => element,
        Some(_) => TypePlan::List {
            element: Box::new(element),
            non_null: false,
        },
    };
    ScalarShape::of(&type_, &host_types)
}

#[test]
fn a_scalar_shape_is_spelled_as_swift_writes_it_and_read_by_its_matching_reader() {
    let shapes = [
        (Primitive::String, None, "String", "string"),
        (Primitive::Int, None, "Int", "int"),
        (Primitive::Double, None, "Double", "double"),
        (Primitive::Bool, None, "Bool", "bool"),
        (Primitive::String, Some(true), "[String]", "strings"),
        (Primitive::Int, Some(true), "[Int]", "ints"),
        (Primitive::Double, Some(true), "[Double]", "doubles"),
        (Primitive::Bool, Some(true), "[Bool]", "bools"),
        (
            Primitive::String,
            Some(false),
            "[String?]",
            "nullableStrings",
        ),
        (Primitive::Int, Some(false), "[Int?]", "nullableInts"),
        (
            Primitive::Double,
            Some(false),
            "[Double?]",
            "nullableDoubles",
        ),
        (Primitive::Bool, Some(false), "[Bool?]", "nullableBools"),
        (
            Primitive::Mapped("Foundation.Decimal".to_string()),
            None,
            "Foundation.Decimal",
            "mapped",
        ),
        (
            Primitive::Mapped("Foundation.Decimal".to_string()),
            Some(true),
            "[Foundation.Decimal]",
            "mappedList",
        ),
        (
            Primitive::Mapped("Foundation.Decimal".to_string()),
            Some(false),
            "[Foundation.Decimal?]",
            "nullableMappedList",
        ),
        (
            Primitive::Enum("Status".to_string()),
            None,
            "Status",
            "enumValue",
        ),
        (
            Primitive::Enum("Status".to_string()),
            Some(true),
            "[Status]",
            "enumValues",
        ),
        (
            Primitive::Enum("Status".to_string()),
            Some(false),
            "[Status?]",
            "nullableEnumValues",
        ),
        (
            Primitive::Enum("Result".to_string()),
            None,
            "ResultEnum",
            "enumValue",
        ),
    ];
    for (primitive, elements_non_null, swift_type, reader) in shapes {
        let shape = shape_of(primitive, elements_non_null);
        assert_eq!(
            scalar_type(&shape).to_string(),
            swift_type,
            "the type of {shape:?}"
        );
        assert_eq!(scalar_reader(&shape), reader, "the reader of {shape:?}");
    }
}

#[test]
fn a_variable_is_typed_by_its_shape_and_is_optional_when_it_may_be_null() {
    // The schema has no nullable list argument, and GraphQL lets a nullable
    // variable stand for a non-null argument only when it has a default, so
    // `$someIds` has one.
    let variables = decided_variables(
        r#"query Probe(
            $id: ID!
            $shown: Boolean!
            $page: Int
            $ids: [ID!]!
            $someIds: [ID!] = ["1"]
            $required: FilterCharacter!
            $filter: FilterCharacter
            $filters: [FilterCharacter!]!
        ) {
            node(id: $id) @include(if: $shown) { id }
            charactersByIds(ids: $ids) { id }
            some: charactersByIds(ids: $someIds) { id }
            required: characters(filter: $required) { results { id } }
            characters(page: $page, filter: $filter) { results { id } }
            charactersMatching(filters: $filters) { id }
        }"#,
    );
    let declared: Vec<String> = variables
        .iter()
        .map(|variable| format!("{}: {}", variable.name, variable_type(variable)))
        .collect();
    assert_eq!(
        declared,
        [
            "id: String",
            "shown: Bool",
            "page: Int?",
            "ids: [String]",
            "someIds: [String]?",
            "required: FilterCharacter",
            "filter: FilterCharacter?",
            "filters: [FilterCharacter]",
        ]
    );
}

#[test]
fn a_computed_property_reads_its_expression_in_one_line() {
    let property = Computed::new("name", SwiftType::named("String").optional());
    assert_eq!(
        one_line(property, "anchor.string(Slots.Character.name)", None),
        "@MainActor public var name: String? { anchor.string(Slots.Character.name) }\n"
    );
}

#[test]
fn a_throwing_computed_property_reads_its_expression_inside_get_throws() {
    let property = Computed::new("strict", SwiftType::named("TestStrict_character")).throwing(true);
    assert_eq!(
        one_line(property, "try .throwing(anchor)", None),
        "@MainActor public var strict: TestStrict_character { get throws { try .throwing(anchor) } }\n"
    );
}

#[test]
fn a_computed_property_under_a_condition_is_optional_and_nil_when_the_condition_fails() {
    let property = Computed::new("asDroid", SwiftType::named("AsDroid"));
    assert_eq!(
        one_line(
            property,
            "AsDroid(anchor: anchor)",
            Some("anchor.record.is(Types.Droid)")
        ),
        "@MainActor public var asDroid: AsDroid? { anchor.record.is(Types.Droid) ? AsDroid(anchor: anchor) : nil }\n"
    );
}

#[test]
fn a_throwing_computed_property_under_a_condition_returns_nil_before_it_reads() {
    let property = Computed::new("strict", SwiftType::named("TestStrict_character")).throwing(true);
    assert_eq!(
        one_line(
            property,
            "try .throwing(anchor)",
            Some("anchor.owner.selects(Guards.withStrict_true)")
        ),
        "@MainActor public var strict: TestStrict_character? { get throws { guard anchor.owner.selects(Guards.withStrict_true) else { return nil }; return try .throwing(anchor) } }\n"
    );
}

#[test]
fn a_computed_property_already_optional_is_not_made_optional_again_under_a_condition() {
    let property = Computed::new("name", SwiftType::named("String").optional());
    assert_eq!(
        one_line(
            property,
            "anchor.string(Slots.Character.name)",
            Some("anchor.owner.selects(Guards.withName_true)")
        ),
        "@MainActor public var name: String? { anchor.owner.selects(Guards.withName_true) ? anchor.string(Slots.Character.name) : nil }\n"
    );
}

#[test]
fn a_computed_property_named_like_a_swift_keyword_is_declared_in_backticks() {
    let string = || SwiftType::named("String").optional();
    assert_eq!(
        one_line(
            Computed::new("class", string()),
            "anchor.string(Slots.Character.`class`)",
            None
        ),
        "@MainActor public var `class`: String? { anchor.string(Slots.Character.`class`) }\n"
    );
    assert_eq!(
        one_line(
            Computed::new("self", SwiftType::named("SelfLens").optional()),
            "anchor.linked(Slots.Mutation.setFavorite_e62d42).map(SelfLens.init(anchor:))",
            None
        ),
        "@MainActor public var `self`: SelfLens? { anchor.linked(Slots.Mutation.setFavorite_e62d42).map(SelfLens.init(anchor:)) }\n"
    );
    assert_eq!(
        one_line(
            Computed::new("name", string()),
            "anchor.string(Slots.Character.name)",
            None
        ),
        "@MainActor public var name: String? { anchor.string(Slots.Character.name) }\n"
    );
}

#[test]
fn a_stored_property_named_like_a_swift_keyword_is_spelled_in_backticks() {
    assert_eq!(member("class"), "`class`");
    assert_eq!(member("self"), "`self`");
    assert_eq!(member("name"), "name");
}

#[test]
fn a_computed_property_with_a_body_writes_its_statements_one_level_deeper() {
    let mut writer = Writer::new();
    Computed::new(
        "testNotes",
        SwiftType::named("TestNotes_character").optional(),
    )
    .body(&mut writer, |writer| {
        writer.line("guard anchor.record.is(Types.Character) else { return nil }");
        writer.line("return .init(anchor: anchor)");
    });
    assert_eq!(
        writer.finish(),
        concat!(
            "@MainActor public var testNotes: TestNotes_character? {\n",
            "    guard anchor.record.is(Types.Character) else { return nil }\n",
            "    return .init(anchor: anchor)\n",
            "}\n",
        )
    );
}

#[test]
fn a_throwing_computed_property_with_a_body_writes_its_statements_inside_get_throws() {
    let mut writer = Writer::new();
    Computed::new(
        "testNotes",
        SwiftType::named("TestNotes_character").optional(),
    )
    .throwing(true)
    .body(&mut writer, |writer| {
        writer.line("guard anchor.record.is(Types.Character) else { return nil }");
        writer.line("return try .throwing(anchor)");
    });
    assert_eq!(
        writer.finish(),
        concat!(
            "@MainActor public var testNotes: TestNotes_character? {\n",
            "    get throws {\n",
            "        guard anchor.record.is(Types.Character) else { return nil }\n",
            "        return try .throwing(anchor)\n",
            "    }\n",
            "}\n",
        )
    );
}

#[test]
fn a_fragment_alias_is_never_named_like_a_type_its_body_aliases() {
    let alias = LocalAlias::fragment("TestNotes_character", &["TestNotes_character"]);
    assert_eq!(alias.to_string(), "Fragment");
    let alias = LocalAlias::fragment("Fragment", &["Fragment"]);
    assert_eq!(alias.to_string(), "Spread");
    // Every type the body aliases is kept off, a query's name as well as
    // the fragment's own.
    let alias = LocalAlias::fragment("TestNotes_character", &["Fragment", "TestNotes_character"]);
    assert_eq!(alias.to_string(), "Spread");
    let alias = LocalAlias::fragment("Spread", &["Fragment", "Spread"]);
    assert_eq!(alias.to_string(), "Owner");
}

#[test]
fn a_query_alias_is_never_named_like_a_type_its_body_aliases() {
    let alias = LocalAlias::query("TestNotesRefetchQuery", &["TestNotesRefetchQuery"]);
    assert_eq!(alias.to_string(), "Query");
    let alias = LocalAlias::query("Query", &["Query"]);
    assert_eq!(alias.to_string(), "Operation");
    let alias = LocalAlias::query("Operation", &["Query", "Operation"]);
    assert_eq!(alias.to_string(), "RefetchQuery");
}

#[test]
fn a_local_alias_names_a_type_named_like_a_swift_keyword_in_backticks() {
    let query = LocalAlias::query("class", &["class"]);
    let mut writer = Writer::new();
    query.declare(&mut writer);
    assert_eq!(writer.finish(), "typealias Query = `class`\n");
}

#[test]
fn a_local_alias_is_declared_at_the_depth_of_the_body_it_opens() {
    let query = LocalAlias::query("TestNotesRefetchQuery", &["TestNotesRefetchQuery"]);
    let mut writer = Writer::new();
    writer.block("@MainActor public func refetch() async throws", |writer| {
        query.declare(writer);
        writer.line(format!(
            "try await anchor.refetch({query}.self, Self.refetchable)"
        ));
    });
    assert_eq!(
        writer.finish(),
        concat!(
            "@MainActor public func refetch() async throws {\n",
            "    typealias Query = TestNotesRefetchQuery\n",
            "    try await anchor.refetch(Query.self, Self.refetchable)\n",
            "}\n",
        )
    );
}

#[test]
fn a_check_is_a_static_function_of_the_anchor_that_throws_only_when_asked() {
    assert_eq!(
        check_head("satisfied", &SwiftType::named("Bool"), false),
        "@_spi(Generated) @MainActor public static func satisfied(_ anchor: Baton.Anchor) -> Bool"
    );
    assert_eq!(
        check_head("throwing", &SwiftType::own(), true),
        "@_spi(Generated) @MainActor public static func throwing(_ anchor: Baton.Anchor) throws -> Self"
    );
    assert_eq!(
        check_head("caught", &SwiftType::own().caught(), false),
        "@_spi(Generated) @MainActor public static func caught(_ anchor: Baton.Anchor) -> Result<Self, Baton.FieldErrors>"
    );
}

#[test]
fn a_spread_argument_defaults_to_null_only_the_variables_inside_a_list_or_an_object() {
    let variable = |name: &str| ArgumentValuePlan::Variable(name.to_string());
    let text = |text: &str| ArgumentValuePlan::Constant(ConstantPlan::String(text.to_string()));
    assert_eq!(
        argument_expression(&variable("id")),
        "anchor.variables[\"id\"]"
    );
    assert_eq!(
        argument_expression(&ArgumentValuePlan::List(vec![variable("id"), text("2")])),
        ".list([anchor.variables[\"id\"] ?? .null, .string(\"2\")])"
    );
    assert_eq!(
        argument_expression(&ArgumentValuePlan::Object(vec![
            ("status".to_string(), text("Alive")),
            ("name".to_string(), variable("name")),
            (
                "ids".to_string(),
                ArgumentValuePlan::List(vec![variable("id")])
            ),
        ])),
        ".object([\"status\": .string(\"Alive\"), \"name\": anchor.variables[\"name\"] ?? .null, \"ids\": .list([anchor.variables[\"id\"] ?? .null])])"
    );
}
