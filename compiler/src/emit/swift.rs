//! Swift as every printer writes it: the pieces that carry a rule, and the
//! literals.
//!
//! A name a document chose is escaped where its declaration or its type is
//! made. A type is a structure, so no printer asks a string whether it is
//! optional. The runtime's module is named by one function for each
//! position it can stand in. A type a member could hide from an expression
//! is named through an alias its body declares. A computed property says
//! whether it throws and what it reads under, and is laid out in one place.

use std::fmt;

use super::writer::Writer;
use crate::decide::{InputField, Primitive, ScalarShape, VariableBase, VariableValue};
use crate::names::{
    enum_type_name, escape, input_type_name, keyed_types, possible_types, type_constant,
};
use crate::pipeline::{ArgumentValuePlan, ConstantPlan, TypeKind};

/// The runtime's module.
pub(super) const RUNTIME: &str = "Baton";

/// A type as Swift writes it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) enum SwiftType {
    /// A type by its name, as Swift spells it: a lens, a builder, an
    /// operation, a scalar.
    Named(String),
    /// The type a declaration is in: `Self`.
    Own,
    /// A type nested in another, as `Edges.Node`.
    Nested(Box<SwiftType>, String),
    Optional(Box<SwiftType>),
    /// A `Result` whose failure is the runtime's field errors: what a
    /// `@catch` reads as.
    Caught(Box<SwiftType>),
    /// The runtime's list of lenses.
    List(Box<SwiftType>),
    Array(Box<SwiftType>),
}

impl SwiftType {
    /// The type `name`, escaped where Swift would read the name as a
    /// keyword: a document can name a fragment or an operation `class`.
    pub(super) fn named(name: &str) -> SwiftType {
        SwiftType::Named(escape(name))
    }

    /// The type a declaration is in, which a type position reads as Swift's
    /// `Self` whatever a member is named.
    pub(super) fn own() -> SwiftType {
        SwiftType::Own
    }

    /// The type named `name` nested in this one.
    pub(super) fn nested(self, name: &str) -> SwiftType {
        SwiftType::Nested(Box::new(self), escape(name))
    }

    /// A type of the runtime, qualified by its module. A type is the one
    /// place a lens or a builder names the module: Swift looks up types
    /// alone there, so a member named `Baton` hides it from nothing.
    pub(super) fn runtime(name: &str) -> SwiftType {
        SwiftType::Named(format!("{RUNTIME}.{name}"))
    }

    /// The type made optional, once: an optional stays as it is.
    pub(super) fn optional(self) -> SwiftType {
        match self {
            SwiftType::Optional(_) => self,
            other => SwiftType::Optional(Box::new(other)),
        }
    }

    /// The type made optional when `condition` holds.
    pub(super) fn optional_if(self, condition: bool) -> SwiftType {
        if condition { self.optional() } else { self }
    }

    pub(super) fn caught(self) -> SwiftType {
        SwiftType::Caught(Box::new(self))
    }

    pub(super) fn list(self) -> SwiftType {
        SwiftType::List(Box::new(self))
    }

    pub(super) fn array(self) -> SwiftType {
        SwiftType::Array(Box::new(self))
    }
}

impl fmt::Display for SwiftType {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            SwiftType::Named(name) => formatter.write_str(name),
            SwiftType::Own => formatter.write_str("Self"),
            SwiftType::Nested(outer, name) => write!(formatter, "{outer}.{name}"),
            SwiftType::Optional(wrapped) => write!(formatter, "{wrapped}?"),
            SwiftType::Caught(success) => {
                write!(
                    formatter,
                    "Result<{success}, {}>",
                    SwiftType::runtime("FieldErrors")
                )
            }
            SwiftType::List(element) => write!(formatter, "{RUNTIME}.List<{element}>"),
            SwiftType::Array(element) => write!(formatter, "[{element}]"),
        }
    }
}

/// A scalar's type: the primitive, or an array of it, of optionals when the
/// schema types the elements nullable.
pub(super) fn scalar_type(shape: &ScalarShape) -> SwiftType {
    let primitive = primitive_type(&shape.primitive);
    match shape.list {
        Some(list) => primitive.optional_if(!list.non_null).array(),
        None => primitive,
    }
}

/// A primitive's type. A mapped scalar's is the type `baton.json` names,
/// as written, qualified or not: the configuration spells Swift.
fn primitive_type(primitive: &Primitive) -> SwiftType {
    match primitive {
        Primitive::String => SwiftType::named("String"),
        Primitive::Int => SwiftType::named("Int"),
        Primitive::Double => SwiftType::named("Double"),
        Primitive::Bool => SwiftType::named("Bool"),
        Primitive::Mapped(name) => SwiftType::Named(name.clone()),
        Primitive::Enum(name) => SwiftType::Named(enum_type_name(name)),
    }
}

/// An input object's field as its struct types it: a scalar, an enum or a
/// mapped scalar as an accessor reads it, a nested input as its struct, a
/// list as an array, optional unless the schema types it non-null.
pub(super) fn input_field_type(field: &InputField) -> SwiftType {
    let type_ = &field.type_;
    let base = match type_.base_kind() {
        TypeKind::InputObject => SwiftType::Named(input_type_name(type_.base_name())),
        _ => primitive_type(&field.primitive),
    };
    let shape = match type_.element() {
        Some(element) => base.optional_if(!element.non_null()).array(),
        None => base,
    };
    shape.optional_if(!type_.non_null())
}

/// The anchor's reader for a scalar: `string`, `ints`, `nullableInts` for a
/// list whose elements the schema types nullable; `mapped` and its lists
/// for a scalar converted at the read.
pub(super) fn scalar_reader(shape: &ScalarShape) -> &'static str {
    match (&shape.primitive, shape.list.map(|list| list.non_null)) {
        (Primitive::String, None) => "string",
        (Primitive::Int, None) => "int",
        (Primitive::Double, None) => "double",
        (Primitive::Bool, None) => "bool",
        (Primitive::Mapped(_), None) => "mapped",
        (Primitive::Enum(_), None) => "enumValue",
        (Primitive::String, Some(true)) => "strings",
        (Primitive::Int, Some(true)) => "ints",
        (Primitive::Double, Some(true)) => "doubles",
        (Primitive::Bool, Some(true)) => "bools",
        (Primitive::Mapped(_), Some(true)) => "mappedList",
        (Primitive::Enum(_), Some(true)) => "enumValues",
        (Primitive::String, Some(false)) => "nullableStrings",
        (Primitive::Int, Some(false)) => "nullableInts",
        (Primitive::Double, Some(false)) => "nullableDoubles",
        (Primitive::Bool, Some(false)) => "nullableBools",
        (Primitive::Mapped(_), Some(false)) => "nullableMappedList",
        (Primitive::Enum(_), Some(false)) => "nullableEnumValues",
    }
}

/// A variable's type as the operation value stores it: a scalar as the
/// accessors read it, an input object as the runtime's variable value,
/// optional when the variable may be null.
pub(super) fn variable_type(variable: &VariableValue) -> SwiftType {
    let base = match &variable.shape.base {
        VariableBase::Scalar(primitive) => primitive_type(primitive),
        VariableBase::Input(name) => SwiftType::Named(input_type_name(name)),
    };
    let shape = match variable.shape.list {
        Some(list) => base.optional_if(!list.non_null).array(),
        None => base,
    };
    shape.optional_if(!variable.non_null)
}

/// The runtime's module named in an expression, as `Baton.Variables`. Only
/// where no member can hide it: in the shared enums, whose members are
/// spelled off its name, and in an operation value, which refuses a
/// variable of its name. A lens and a builder take a runtime type from the
/// context instead, as `.init(errors)` does.
pub(super) fn runtime_value(name: &str) -> String {
    format!("{RUNTIME}.{name}")
}

/// A type a body names in an expression: a fragment or a query, which a
/// member of the lens, or of a lens or an operation it is nested in, could
/// hide. The body declares an alias for it, which names the type in a type
/// position, and spells the alias. The alias is the first of its kind's
/// names that is none of the types the body aliases, since an alias named
/// like one of them would refer to itself or to another alias.
pub(super) struct LocalAlias {
    name: &'static str,
    target: SwiftType,
}

/// The names a body gives a fragment's type: one more than the types a
/// body aliases, so one is always free.
const FRAGMENT_ALIASES: [&str; 3] = ["Fragment", "Spread", "Owner"];

/// The names a body gives a query's type.
const QUERY_ALIASES: [&str; 3] = ["Query", "Operation", "RefetchQuery"];

impl LocalAlias {
    /// The alias for the fragment `target` in a body that aliases `named`.
    pub(super) fn fragment(target: &str, named: &[&str]) -> LocalAlias {
        LocalAlias::among(&FRAGMENT_ALIASES, target, named)
    }

    /// The alias for the query `target` in a body that aliases `named`.
    pub(super) fn query(target: &str, named: &[&str]) -> LocalAlias {
        LocalAlias::among(&QUERY_ALIASES, target, named)
    }

    fn among(candidates: &[&'static str], target: &str, named: &[&str]) -> LocalAlias {
        let name = candidates
            .iter()
            .copied()
            .find(|candidate| !named.contains(candidate))
            .expect("an alias has more candidates than the types a body aliases");
        LocalAlias {
            name,
            target: SwiftType::named(target),
        }
    }

    /// The declaration a body opens with.
    pub(super) fn declare(&self, writer: &mut Writer) {
        writer.line(self.declaration());
    }

    pub(super) fn declaration(&self) -> String {
        format!("typealias {} = {}", self.name, self.target)
    }
}

impl fmt::Display for LocalAlias {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(self.name)
    }
}

/// A computed property read on the main actor: an accessor of a lens.
pub(super) struct Computed {
    name: String,
    swift_type: SwiftType,
    throws: bool,
}

impl Computed {
    /// The property `name`, as the document or the compiler chose it: it is
    /// escaped here, where it is declared.
    pub(super) fn new(name: &str, swift_type: SwiftType) -> Computed {
        Computed {
            name: escape(name),
            swift_type,
            throws: false,
        }
    }

    /// The property as one whose getter throws when `throws` holds.
    pub(super) fn throwing(mut self, throws: bool) -> Computed {
        self.throws = throws;
        self
    }

    fn head(&self, swift_type: &SwiftType) -> String {
        format!("@MainActor public var {}: {swift_type}", self.name)
    }

    /// Writes the property as one line that reads `expression`. Under a
    /// `condition` the property is optional and reads nil, without a read,
    /// when the condition fails, so a field a condition left out reports
    /// nothing missing.
    pub(super) fn reads(self, writer: &mut Writer, expression: &str, condition: Option<&str>) {
        let Some(condition) = condition else {
            let head = self.head(&self.swift_type);
            if self.throws {
                writer.line(format!("{head} {{ get throws {{ {expression} }} }}"));
            } else {
                writer.line(format!("{head} {{ {expression} }}"));
            }
            return;
        };
        let head = self.head(&self.swift_type.clone().optional());
        if self.throws {
            writer.line(format!(
                "{head} {{ get throws {{ guard {condition} else {{ return nil }}; return {expression} }} }}"
            ));
        } else {
            writer.line(format!("{head} {{ {condition} ? {expression} : nil }}"));
        }
    }

    /// Writes the property with the statements `body` writes, inside
    /// `get throws` when it throws.
    pub(super) fn body(self, writer: &mut Writer, body: impl FnOnce(&mut Writer)) {
        let head = self.head(&self.swift_type);
        let throws = self.throws;
        writer.block(head, |writer| {
            if throws {
                writer.block("get throws", body);
            } else {
                body(writer);
            }
        });
    }
}

/// The head of a check every lens may have: a static function of an
/// anchor, on the main actor, for generated code alone.
pub(super) fn check_head(name: &str, returns: &SwiftType, throws: bool) -> String {
    let effect = if throws { " throws" } else { "" };
    format!(
        "@_spi(Generated) @MainActor public static func {name}(_ anchor: {}){effect} -> {returns}",
        SwiftType::runtime("Anchor")
    )
}

/// A schema type's constant, `Types.Character`.
pub(super) fn type_reference(type_name: &str) -> String {
    format!("Types.{}", type_constant(type_name))
}

/// The constant of the types that satisfy `condition`,
/// `Types.Node_possible`.
pub(super) fn possible_types_reference(condition: &str) -> String {
    format!("Types.{}", possible_types(condition))
}

/// `Types.Node_keyed`: the members one value keys, for a lookup without a
/// type.
pub(super) fn keyed_types_reference(condition: &str) -> String {
    format!("Types.{}", keyed_types(condition))
}

/// A Swift string literal for text that may contain quotes or backslashes
/// (storage keys carry JSON-rendered arguments).
pub(super) fn swift_literal(text: &str) -> String {
    let mut output = String::with_capacity(text.len() + 2);
    output.push('"');
    for character in text.chars() {
        match character {
            '"' => output.push_str("\\\""),
            '\\' => output.push_str("\\\\"),
            '\n' => output.push_str("\\n"),
            other => output.push(other),
        }
    }
    output.push('"');
    output
}

/// A raw Swift string literal holding `text` as it is, on one line unless
/// the text has a newline, as compact GraphQL has not. Its delimiter takes
/// one `#` more than the longest run of them in the text, so no backslash
/// in the text starts an escape and no quote ends the literal.
pub(super) fn raw_literal(text: &str) -> String {
    let longest = text
        .split(|character| character != '#')
        .map(str::len)
        .max()
        .unwrap_or(0);
    let hashes = "#".repeat(longest + 1);
    if text.contains('\n') {
        return format!("{hashes}\"\"\"\n{text}\n\"\"\"{hashes}");
    }
    format!("{hashes}\"{text}\"{hashes}")
}

/// A `Baton.Variable` expression for a constant.
pub(super) fn variable_literal(constant: &ConstantPlan) -> String {
    match constant {
        ConstantPlan::Null => ".null".to_string(),
        ConstantPlan::Bool(boolean) => format!(".bool({boolean})"),
        ConstantPlan::Int(int) => format!(".int({int})"),
        ConstantPlan::Float(float) => format!(".double({float:?})"),
        ConstantPlan::String(text) => format!(".string({})", swift_literal(text)),
        ConstantPlan::List(items) => format!(
            ".list([{}])",
            items
                .iter()
                .map(variable_literal)
                .collect::<Vec<_>>()
                .join(", ")
        ),
        ConstantPlan::Object(fields) if fields.is_empty() => ".object([:])".to_string(),
        ConstantPlan::Object(fields) => format!(
            ".object([{}])",
            fields
                .iter()
                .map(|(name, value)| format!(
                    "{}: {}",
                    swift_literal(name),
                    variable_literal(value)
                ))
                .collect::<Vec<_>>()
                .join(", ")
        ),
    }
}

/// A constant's text, for the rare constant list of connection ids.
pub(super) fn constant_text(constant: &ConstantPlan) -> String {
    match constant {
        ConstantPlan::Null => "null".to_string(),
        ConstantPlan::Bool(boolean) => boolean.to_string(),
        ConstantPlan::Int(int) => int.to_string(),
        ConstantPlan::Float(float) => float.to_string(),
        ConstantPlan::String(text) => text.clone(),
        ConstantPlan::List(items) => format!(
            "[{}]",
            items
                .iter()
                .map(constant_text)
                .collect::<Vec<_>>()
                .join(",")
        ),
        ConstantPlan::Object(fields) => format!(
            "{{{}}}",
            fields
                .iter()
                .map(|(name, value)| format!("{name}:{}", constant_text(value)))
                .collect::<Vec<_>>()
                .join(",")
        ),
    }
}

/// A spread argument as the parent lens binds it: the parent's variable, or
/// a constant.
pub(super) fn argument_expression(value: &ArgumentValuePlan) -> String {
    match value {
        ArgumentValuePlan::Variable(name) => format!("anchor.variables[{}]", swift_literal(name)),
        ArgumentValuePlan::Constant(constant) => variable_literal(constant),
        ArgumentValuePlan::List(items) => format!(
            ".list([{}])",
            items
                .iter()
                .map(argument_element)
                .collect::<Vec<_>>()
                .join(", ")
        ),
        ArgumentValuePlan::Object(fields) => format!(
            ".object([{}])",
            fields
                .iter()
                .map(|(name, field)| format!(
                    "{}: {}",
                    swift_literal(name),
                    argument_element(field)
                ))
                .collect::<Vec<_>>()
                .join(", ")
        ),
    }
}

/// An item of a list or a field of an object a spread argument holds. A
/// variable the parent's scope lacks is null there; anything else is a
/// value already, which Swift would warn to see defaulted.
fn argument_element(value: &ArgumentValuePlan) -> String {
    match value {
        ArgumentValuePlan::Variable(_) => format!("{} ?? .null", argument_expression(value)),
        _ => argument_expression(value),
    }
}

/// A stored property where it is declared or read as a member: the name
/// the document chose, escaped.
pub(super) fn member(property: &str) -> String {
    escape(property)
}

/// A parameter labelled by `property` whose value goes by `local`.
pub(super) fn parameter(property: &str, local: &str) -> String {
    let label = escape(property);
    if label == local {
        label
    } else {
        format!("{label} {local}")
    }
}

#[cfg(test)]
#[path = "../tests/emit_swift_tests.rs"]
mod tests;
