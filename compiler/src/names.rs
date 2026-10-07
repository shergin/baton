//! Names in generated Swift: the identifiers a document's names become, the
//! names Swift keeps or the generated code spells, and `SwiftNaming`, the
//! answers the decide pass asks of a language, given for Swift.
//!
//! Swift resolves an unqualified name to the nearest declaration, so a nested
//! type named like a type the generated code spells unqualified shadows it
//! for everything nested in the scope. The lists below are what each kind of
//! scope keeps; the allocator in `naming` holds a scope's declarations to
//! them.

use std::collections::BTreeMap;

use crate::config::Config;
use crate::naming::{Naming, Position, Spelled, numbered};

/// Every type and attribute name the emitter writes unqualified inside a
/// lens, and the names Swift keeps for itself. A nested lens of one of
/// these names would shadow it for the lens and everything nested in it, or
/// not compile; an identifier a lens comes to spell unqualified joins the
/// list in the same change.
pub const RESERVED_TYPE_NAMES: [&str; 18] = [
    // Swift lets no type member take these names.
    "Type",
    "Self",
    "Protocol",
    "Any",
    // The attribute on every accessor and check.
    "MainActor",
    // The standard library's module, which an `@inline` fragment's value
    // conforms through, the runtime's module and the module's shared enums.
    "Swift",
    "Baton",
    "Types",
    "Slots",
    "AbstractSlots",
    "Sites",
    "Guards",
    // What the accessors return: a `@catch` field's `Result`, the
    // `Optional` every optional accessor's type stands for, and the
    // scalars.
    "Result",
    "Optional",
    "String",
    "Int",
    "Double",
    "Bool",
];

/// What an optimistic-response builder writes unqualified, and the names
/// Swift keeps for itself: a nested builder of one of these names would
/// shadow it, or conform to itself.
pub const BUILDER_RESERVED_NAMES: [&str; 10] = [
    "Type", "Self", "Protocol", "Any", "Sendable", "Baton", "String", "Int", "Double", "Bool",
];

/// What goes after a nested lens's name a lens keeps.
const LENS_SUFFIX: &str = "Lens";

/// What goes after a nested builder's name a builder keeps.
const RESPONSE_SUFFIX: &str = "Response";

/// What the generated code spells unqualified from the standard library,
/// in any file and at any depth: the attribute on every accessor, the types
/// accessors return and variables take, the `Hasher` an operation value
/// hashes with and the `Sendable` a builder conforms to. A fragment or an
/// operation, which the module declares at its top level, of one of these
/// names would hide it from all of the module's code; one that the
/// generated code comes to spell joins the list in the same change.
pub const STANDARD_LIBRARY_NAMES: [&str; 9] = [
    "MainActor",
    "Result",
    "Optional",
    "String",
    "Int",
    "Double",
    "Bool",
    "Hasher",
    "Sendable",
];

pub fn lower_camel(text: &str) -> String {
    let mut characters = text.chars();
    match characters.next() {
        Some(first) => first.to_lowercase().collect::<String>() + characters.as_str(),
        None => String::new(),
    }
}

/// A type's or a field's name in `Slots` and `AbstractSlots`. Swift reads
/// `Type` and `Protocol` after a dot as metatypes, takes `Any` as no
/// member's name, and a scope or a member named `Types` or `Baton` hides the
/// enum or the module the slots are built from, so these names take an
/// underscore.
pub fn slot_name(name: &str) -> String {
    underscored(name, &["Type", "Protocol", "Any", "Types", "Baton"])
}

/// A schema type's constant in `Types`, as every reference spells it.
/// Swift reads `Types.Type` and `Types.Protocol` as metatypes and takes
/// `Any` as no member's name, and a member named `Baton` refers to itself
/// in its own initializer and hides the module from every other, so these
/// names take an underscore, as in `slot_name`. A member named `Types`
/// hides nothing: inside the enum the members are named bare.
pub fn type_constant(name: &str) -> String {
    underscored(name, &["Type", "Protocol", "Any", "Baton"])
}

/// The names the module's top level keeps for itself, which a schema enum
/// of the same name would hide from every file: the shared enums, the
/// modules, Swift's keywords and what the generated code spells from the
/// standard library.
pub const MODULE_RESERVED_NAMES: [&str; 15] = [
    "Swift",
    "Foundation",
    "Baton",
    "Types",
    "Slots",
    "Sites",
    "Guards",
    "AbstractSlots",
    "Self",
    "Any",
    "Type",
    "Protocol",
    // The types every operation nests, which an enum of the name would be
    // hidden by inside the operation.
    "Data",
    "Action",
    "OptimisticResponse",
];

/// A schema enum's Swift type, declared at the module's top level: its own
/// name, escaped, with `Enum` after it where the name is one the module
/// keeps or the standard library's, as a nested lens takes `Lens`.
pub fn enum_type_name(name: &str) -> String {
    module_type_name(name, ENUM_SUFFIX)
}

/// A schema input object's Swift struct, declared at the module's top level,
/// named as an enum's is.
pub fn input_type_name(name: &str) -> String {
    module_type_name(name, INPUT_SUFFIX)
}

/// What goes after a schema enum's name the module keeps.
const ENUM_SUFFIX: &str = "Enum";

/// What goes after a schema input object's name the module keeps.
const INPUT_SUFFIX: &str = "Input";

/// A type the module's top level declares for the schema's `name`: the name
/// escaped, or with `suffix` after it where the module keeps the name.
fn module_type_name(name: &str, suffix: &str) -> String {
    if MODULE_RESERVED_NAMES.contains(&name) || STANDARD_LIBRARY_NAMES.contains(&name) {
        return format!("{name}{suffix}");
    }
    escape(name)
}

/// An input object's field as a property of its struct: its own name,
/// escaped; `variable` takes an underscore, since the struct's own member
/// has it.
pub fn input_field_name(name: &str) -> String {
    underscored(name, &["variable"])
}

/// A schema enum's value as a case of its Swift enum: the value's own
/// spelling, escaped where Swift reads it as a keyword; `unknown` takes an
/// underscore, since the case for a value the build does not know has it.
pub fn enum_case_name(value: &str) -> String {
    underscored(value, &["unknown"])
}

/// The constant in `Types` of the types that satisfy `condition`.
pub fn possible_types(condition: &str) -> String {
    format!("{condition}_possible")
}

/// The constant in `Types` of the members of an abstract type that one
/// value keys, which a lookup without a type probes: `Node_keyed`.
pub fn keyed_types(condition: &str) -> String {
    format!("{condition}_keyed")
}

/// The constant in `Guards` of a condition: the variable and the value of
/// it that selects, `withOrigin_true`.
pub fn guard_name(variable: &str, passing: bool) -> String {
    format!("{variable}_{passing}")
}

/// `name` with an underscore after it when it is one of `hidden`, escaped
/// otherwise. One of them followed by underscores takes one more, so no two
/// names meet.
fn underscored(name: &str, hidden: &[&str]) -> String {
    if hidden.contains(&name.trim_end_matches('_')) {
        return format!("{name}_");
    }
    escape(name)
}

/// An argument label at a call site. Swift takes every keyword there
/// without backticks but `inout`, reads a bare `_` as no label at all, and
/// warns about any other escaped one, `var` and `let` among them, which a
/// build with warnings as errors refuses. Swift 6.2, the oldest the
/// package supports, reads labels the same way.
pub fn call_label(name: &str) -> String {
    if matches!(name, "inout" | "_") {
        format!("`{name}`")
    } else {
        name.to_string()
    }
}

/// Escapes a name that Swift would read as a keyword where the generated
/// code declares or reads it.
pub fn escape(name: &str) -> String {
    const KEYWORDS: &[&str] = &[
        "Type",
        "Protocol",
        "Any",
        "self",
        "Self",
        "init",
        "deinit",
        "subscript",
        "class",
        "struct",
        "enum",
        "func",
        "var",
        "let",
        "import",
        "extension",
        "operator",
        "static",
        "default",
        "case",
        "switch",
        "if",
        "else",
        "for",
        "in",
        "while",
        "repeat",
        "return",
        "break",
        "continue",
        "where",
        "is",
        "as",
        "try",
        "throw",
        "throws",
        "guard",
        "defer",
        "do",
        "catch",
        "true",
        "false",
        "nil",
        "super",
        "internal",
        "private",
        "public",
        "fileprivate",
        "open",
        "inout",
        "typealias",
        "associatedtype",
        "protocol",
        "some",
        "any",
        "rethrows",
        "fallthrough",
        "precedencegroup",
        "_",
        // A contextual keyword that starts an expression, where a name is
        // read: `self.await = await` awaits nothing.
        "await",
        // Ones that start a type, where a fragment or an operation is
        // named: `typealias Query = each` expects a pack, and
        // `typealias Fragment = borrowing` the type it borrows.
        "each",
        "borrowing",
        "consuming",
        "isolated",
        "sending",
    ];
    if KEYWORDS.contains(&name) {
        format!("`{name}`")
    } else {
        name.to_string()
    }
}

/// The name a property's value goes by as a parameter or a local: the
/// property's own, escaped, except for `self`, which as a parameter or a
/// local would hide the instance. It goes by `selfValue`, numbered past the
/// names in `taken`.
pub fn local_name(property: &str, taken: &[&str]) -> String {
    if property != "self" {
        return escape(property);
    }
    numbered("selfValue", taken)
}

/// Swift's answers to what the decide pass asks of a language, and the
/// Swift type each mapped custom scalar reads as, by the scalar's name.
#[derive(Clone, Debug, Default)]
pub struct SwiftNaming {
    host_types: BTreeMap<String, String>,
}

impl SwiftNaming {
    /// Swift's names, with the Swift type `config` names for each mapped
    /// scalar.
    pub fn new(config: &Config) -> SwiftNaming {
        SwiftNaming::with_host_types(config.swift_types())
    }

    /// Swift's names, with `host_types` the Swift type of each mapped
    /// scalar, by the scalar's name.
    pub fn with_host_types(host_types: BTreeMap<String, String>) -> SwiftNaming {
        SwiftNaming { host_types }
    }
}

impl Naming for SwiftNaming {
    fn language(&self) -> &'static str {
        "Swift"
    }

    fn accessor(&self, name: &str) -> String {
        lower_camel(name)
    }

    fn local(&self, property: &str, taken: &[&str]) -> String {
        local_name(property, taken)
    }

    fn reserved(&self, position: Position) -> Vec<&'static str> {
        match position {
            Position::Lens => RESERVED_TYPE_NAMES.to_vec(),
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
            Spelled::Runtime => "Baton",
            Spelled::OwnType => "Self",
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
            | Spelled::Guards => format!("the shared enum `{name}`"),
            Spelled::Runtime => format!("the runtime's module `{name}`"),
            Spelled::OwnType => format!("Swift's keyword `{name}`"),
            Spelled::Data => format!("the operation's root lens `{name}`"),
            Spelled::Action | Spelled::OptimisticResponse => format!("the mutation's `{name}`"),
        }
    }

    fn module_names(&self) -> Vec<(&'static str, String)> {
        // The shared file qualifies its sets of types by the standard
        // library's module, and Swift lets no type be named `Self` or `Any`.
        let mut names = vec![("Swift", "the standard library's module `Swift`".to_string())];
        for name in STANDARD_LIBRARY_NAMES {
            names.push((name, format!("the standard library's `{name}`")));
        }
        for name in ["Self", "Any"] {
            names.push((name, format!("Swift's keyword `{name}`")));
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
        slot_name(name).trim_matches('`').to_string()
    }

    fn type_constant(&self, name: &str) -> String {
        type_constant(name).trim_matches('`').to_string()
    }

    fn possible_types(&self, condition: &str) -> String {
        possible_types(condition)
    }

    fn keyed_types(&self, condition: &str) -> String {
        keyed_types(condition)
    }

    fn host_type(&self, scalar: &str) -> Option<&str> {
        self.host_types.get(scalar).map(String::as_str)
    }
}

#[cfg(test)]
#[path = "tests/names_tests.rs"]
mod tests;
