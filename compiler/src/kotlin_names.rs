//! Names in generated Kotlin: the identifiers a document's names become, the
//! names Kotlin keeps or the generated code spells, and `KotlinNaming`, the
//! answers the decide pass asks of a language, given for Kotlin.
//!
//! A name keeps the author's spelling; a hard keyword is written in
//! backticks, and a soft keyword is an identifier like any other. Inside the
//! shared objects, whose members the compiler names, a name the object
//! spells or a keyword takes an underscore instead, as Swift's `Any_` does.
//! A Kotlin expression reads an unqualified name as the nearest property
//! before it reads a class, so a member named like a class the code spells in
//! an expression hides it: the lists below are what each scope keeps.

use std::collections::{BTreeMap, BTreeSet};

use crate::config::{Config, ConvertedType};
use crate::naming::{Declared, Kind, Naming, Position, Spelled, ValueNames};
use crate::pipeline::{OperationKind, OperationPlan};

/// Kotlin's hard keywords, which no declaration takes unescaped.
pub const KEYWORDS: [&str; 28] = [
    "as",
    "break",
    "class",
    "continue",
    "do",
    "else",
    "false",
    "for",
    "fun",
    "if",
    "in",
    "interface",
    "is",
    "null",
    "object",
    "package",
    "return",
    "super",
    "this",
    "throw",
    "true",
    "try",
    "typealias",
    "typeof",
    "val",
    "var",
    "when",
    "while",
];

/// The runtime's declarations generated code imports by name and spells
/// unqualified. A fragment or an operation of one of these names would
/// conflict with the import in its own file; one the generated code comes to
/// spell joins the list in the same change.
pub const RUNTIME_NAMES: [&str; 36] = [
    "Anchor",
    "ConnectionCursor",
    "ConnectionPlan",
    "ConnectionSlots",
    "Document",
    "DynamicKey",
    "Edit",
    "ErrorBehavior",
    "GeneratedEnum",
    "Guard",
    "InputObject",
    "KeyArgument",
    "KeyPart",
    "Lens",
    "Lookup",
    "Members",
    "MutationOperation",
    "OperationHandle",
    "OperationKind",
    "OperationType",
    "Plan",
    "PlanField",
    "QueryOperation",
    "Registry",
    "Resolution",
    "ScalarKind",
    "Selection",
    "Slot",
    "StorageKey",
    "SubscriptionHandle",
    "SubscriptionOperation",
    "Transient",
    "TypeID",
    "Variable",
    "Variables",
    "Format1",
];

/// What the generated code spells from the standard library: the types
/// variables take and lenses return, and `Any` an `equals` takes. A
/// fragment or an operation of one of these names, declared in the
/// package, would hide it from every file of the package.
pub const STANDARD_LIBRARY_NAMES: [&str; 10] = [
    "Any", "Boolean", "Double", "Int", "List", "Long", "Map", "Pair", "Result", "String",
];

/// What a nested lens may not be named: the companion every class may
/// have, the runtime's and the standard library's types a lens spells, and
/// the shared objects.
pub const LENS_RESERVED_NAMES: [&str; 14] = [
    "Companion",
    "Lens",
    "Anchor",
    "Types",
    "Slots",
    "String",
    "Int",
    "Long",
    "Double",
    "Boolean",
    "Any",
    "List",
    "Result",
    "Unit",
];

/// What a nested optimistic-response builder may not be named.
pub const BUILDER_RESERVED_NAMES: [&str; 8] = [
    "Companion",
    "Payload",
    "String",
    "Int",
    "Double",
    "Boolean",
    "Any",
    "List",
];

/// What `object Types` declares or spells beside the schema's types: a type
/// of one of these names takes an underscore.
const TYPES_SPELLED: [&str; 8] = [
    "schemaDigest",
    "format",
    "transient",
    "Registry",
    "TypeID",
    "Transient",
    "Members",
    "baton",
];

/// What `object Slots` and its objects spell: a type or a field of one of
/// these names takes an underscore.
const SLOTS_SPELLED: [&str; 8] = [
    "Types",
    "Registry",
    "Slot",
    "DynamicKey",
    "KeyArgument",
    "KeyPart",
    "ConnectionSlots",
    "baton",
];

/// What an input object's data class declares or spells: its own
/// `variable`, the `copy` a data class has, and the runtime's `Variable` its
/// body names. A `componentN` is kept as well, by `input_field_name`.
const INPUT_SPELLED: [&str; 3] = ["variable", "copy", "Variable"];

/// What a generated enum declares or spells: the case for a value the build
/// does not know, the companion, and the types its members name.
const ENUM_SPELLED: [&str; 5] = [
    "Unknown",
    "Companion",
    "String",
    "GeneratedEnum",
    "MappedScalar",
];

/// What goes after a nested lens's name a lens keeps.
const LENS_SUFFIX: &str = "Lens";

/// What goes after a nested builder's name a builder keeps.
const RESPONSE_SUFFIX: &str = "Response";

/// What goes after a schema enum's name the package keeps.
const ENUM_SUFFIX: &str = "Enum";

/// What goes after a schema input object's name the package keeps.
const INPUT_SUFFIX: &str = "Input";

/// Whether `name` is one Kotlin reads as other than an identifier: a hard
/// keyword, or a name of underscores alone, which Kotlin keeps.
fn is_keyword(name: &str) -> bool {
    KEYWORDS.contains(&name) || (!name.is_empty() && name.chars().all(|character| character == '_'))
}

/// `name` as an identifier: in backticks where Kotlin reads it as a keyword.
pub fn escape(name: &str) -> String {
    if is_keyword(name) {
        format!("`{name}`")
    } else {
        name.to_string()
    }
}

/// `name` with an underscore after it when it is a keyword or one of
/// `hidden`. One of them followed by underscores takes one more, so no two
/// names meet.
fn underscored(name: &str, hidden: &[&str]) -> String {
    let bare = name.trim_end_matches('_');
    if is_keyword(name) || is_keyword(bare) || hidden.contains(&bare) {
        return format!("{name}_");
    }
    name.to_string()
}

/// A schema type's constant in `Types`, as every reference spells it.
pub fn type_constant(name: &str) -> String {
    underscored(name, &TYPES_SPELLED)
}

/// A type's object or a field's constant in `Slots`.
pub fn slot_name(name: &str) -> String {
    underscored(name, &SLOTS_SPELLED)
}

/// An input object's field as a property of its data class: its own name,
/// escaped; a name the class declares or spells takes an underscore.
pub fn input_field_name(name: &str) -> String {
    let bare = name.trim_end_matches('_');
    let component = bare
        .strip_prefix("component")
        .is_some_and(|number| !number.is_empty() && number.chars().all(|c| c.is_ascii_digit()));
    if component || INPUT_SPELLED.contains(&bare) {
        return format!("{name}_");
    }
    escape(name)
}

/// A schema enum's value as an object of its sealed interface: the value's
/// own spelling, escaped; a name the interface declares or spells, and its
/// own, take an underscore.
pub fn enum_value_name(value: &str, enum_type: &str) -> String {
    let bare = value.trim_end_matches('_');
    if ENUM_SPELLED.contains(&bare) || bare == enum_type.trim_matches('`') {
        return format!("{value}_");
    }
    escape(value)
}

/// A type the package declares for the schema's `name`: the name escaped,
/// or with `suffix` after it where the package keeps the name.
fn package_type_name(name: &str, suffix: &str) -> String {
    let kept = ["Types", "Slots", "Data"];
    if kept.contains(&name)
        || RUNTIME_NAMES.contains(&name)
        || STANDARD_LIBRARY_NAMES.contains(&name)
    {
        return format!("{name}{suffix}");
    }
    escape(name)
}

/// A schema enum's sealed interface.
pub fn enum_type_name(name: &str) -> String {
    package_type_name(name, ENUM_SUFFIX)
}

/// A schema input object's data class.
pub fn input_type_name(name: &str) -> String {
    package_type_name(name, INPUT_SUFFIX)
}

/// Kotlin's answers to what the decide pass asks of a language, and the
/// converter of each mapped custom scalar, by the scalar's name.
#[derive(Clone, Debug, Default)]
pub struct KotlinNaming {
    converters: BTreeMap<String, String>,
}

impl KotlinNaming {
    /// Kotlin's names, with the converter `config` names for each mapped
    /// scalar.
    pub fn new(config: &Config) -> KotlinNaming {
        KotlinNaming::with_converters(&config.kotlin_types())
    }

    /// Kotlin's names, with `types` the Kotlin type and converter of each
    /// mapped scalar, by the scalar's name.
    pub fn with_converters(types: &BTreeMap<String, ConvertedType>) -> KotlinNaming {
        KotlinNaming {
            converters: types
                .iter()
                .map(|(scalar, converted)| (scalar.clone(), converted.converter.clone()))
                .collect(),
        }
    }
}

impl Naming for KotlinNaming {
    fn language(&self) -> &'static str {
        "Kotlin"
    }

    fn accessor(&self, name: &str) -> String {
        crate::names::lower_camel(name)
    }

    /// A Kotlin parameter is the property it sets, so it keeps the
    /// property's name, escaped; `this` is a hard keyword and escapes.
    fn local(&self, property: &str, _taken: &[&str]) -> String {
        escape(property)
    }

    fn reserved(&self, position: Position) -> Vec<&'static str> {
        match position {
            Position::Lens => LENS_RESERVED_NAMES.to_vec(),
            Position::Builder => BUILDER_RESERVED_NAMES.to_vec(),
        }
    }

    fn suffix(&self, position: Position) -> &'static str {
        match position {
            Position::Lens => LENS_SUFFIX,
            Position::Builder => RESPONSE_SUFFIX,
        }
    }

    fn spelling(&self, spelled: Spelled) -> &'static str {
        match spelled {
            Spelled::Types => "Types",
            Spelled::Slots => "Slots",
            Spelled::AbstractSlots => "AbstractSlots",
            Spelled::Sites => "Sites",
            Spelled::Guards => "Guards",
            Spelled::Runtime => "baton",
            Spelled::OwnType => "Companion",
            Spelled::Data => "Data",
            Spelled::Action => "Action",
            Spelled::OptimisticResponse => "OptimisticResponse",
        }
    }

    fn description(&self, spelled: Spelled) -> String {
        let name = self.spelling(spelled);
        match spelled {
            Spelled::Types
            | Spelled::Slots
            | Spelled::AbstractSlots
            | Spelled::Sites
            | Spelled::Guards => format!("the shared object `{name}`"),
            Spelled::Runtime => format!("the runtime's package `{name}`"),
            Spelled::OwnType => format!("the companion object `{name}`"),
            Spelled::Data => format!("the operation's root lens `{name}`"),
            Spelled::Action | Spelled::OptimisticResponse => format!("the mutation's `{name}`"),
        }
    }

    fn module_names(&self) -> Vec<(&'static str, String)> {
        let mut names = Vec::new();
        for name in STANDARD_LIBRARY_NAMES {
            names.push((name, format!("the standard library's `{name}`")));
        }
        for name in RUNTIME_NAMES {
            names.push((name, format!("the runtime's `{name}`")));
        }
        names
    }

    fn enum_type(&self, name: &str) -> String {
        enum_type_name(name)
    }

    fn input_type(&self, name: &str) -> String {
        input_type_name(name)
    }

    fn slot_name(&self, name: &str) -> String {
        slot_name(name)
    }

    fn type_constant(&self, name: &str) -> String {
        type_constant(name)
    }

    fn possible_types(&self, condition: &str) -> String {
        crate::names::possible_types(condition)
    }

    fn keyed_types(&self, condition: &str) -> String {
        crate::names::keyed_types(condition)
    }

    /// The converter's object: a Kotlin read converts the scalar's text
    /// through it, and its type is the configuration's.
    fn host_type(&self, scalar: &str) -> Option<&str> {
        self.converters.get(scalar).map(String::as_str)
    }

    /// An operation's class declares its `variables`, its `type`, a query's
    /// and a subscription's `resolution`, the `equals`, `hashCode` and
    /// `toString` every class has, its nested `Data` and its `Companion`,
    /// and spells the runtime's `Variable` and `Resolution` in expressions,
    /// where a property of the name would be read instead. Its static data
    /// lives in the companion, where no variable reaches.
    fn value_names(&self, operation: &OperationPlan, _spelled: &BTreeSet<Spelled>) -> ValueNames {
        let mut after = vec![
            Declared::new("variables", Kind::Instance, "the operation's `variables`"),
            Declared::new("type", Kind::Instance, "the operation's `type`"),
        ];
        if operation.kind != OperationKind::Mutation {
            after.push(Declared::new(
                "resolution",
                Kind::Instance,
                "the operation's `resolution`",
            ));
            after.push(Declared::new(
                "Resolution",
                Kind::Type,
                "the runtime's `Resolution`",
            ));
        }
        after.push(Declared::new(
            "Variable",
            Kind::Type,
            "the runtime's `Variable`",
        ));
        for name in ["equals", "hashCode", "toString"] {
            after.push(Declared::new(
                name,
                Kind::Instance,
                format!("the `{name}` every class has"),
            ));
        }
        for spelled in self.value_types(operation.kind) {
            after.push(Declared::spelled(self, spelled));
        }
        after.push(Declared::new(
            "Companion",
            Kind::Type,
            "the operation's companion object `Companion`",
        ));
        ValueNames {
            before: Vec::new(),
            after,
        }
    }

    fn value_types(&self, kind: OperationKind) -> Vec<Spelled> {
        match kind {
            OperationKind::Mutation => vec![Spelled::Data, Spelled::OptimisticResponse],
            OperationKind::Query | OperationKind::Subscription => vec![Spelled::Data],
        }
    }

    fn lens_members(&self) -> Vec<(&'static str, String)> {
        let mut members = vec![
            ("anchor", "the `anchor` every lens has".to_string()),
            ("recordID", "the `recordID` every lens has".to_string()),
        ];
        for name in ["equals", "hashCode", "toString"] {
            members.push((name, format!("the `{name}` every class has")));
        }
        members
    }
}

#[cfg(test)]
#[path = "tests/kotlin_names_tests.rs"]
mod tests;
