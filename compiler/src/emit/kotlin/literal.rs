//! Kotlin as every Kotlin printer writes it: the literals, the references
//! into the shared objects, the types variables take and the expressions
//! that make a variable's value.

use std::collections::BTreeMap;

use crate::decide::{KeyPart, ListShape, Primitive, SlotRef};
use crate::kotlin_names::{enum_type_name, input_type_name, slot_name, type_constant};
use crate::pipeline::ConstantPlan;

/// A Kotlin string literal of `text`: the escapes Kotlin reads, and `$`
/// escaped, since it opens a template.
pub(super) fn string_literal(text: &str) -> String {
    let mut output = String::with_capacity(text.len() + 2);
    output.push('"');
    for character in text.chars() {
        match character {
            '"' => output.push_str("\\\""),
            '\\' => output.push_str("\\\\"),
            '$' => output.push_str("\\$"),
            '\n' => output.push_str("\\n"),
            '\r' => output.push_str("\\r"),
            '\t' => output.push_str("\\t"),
            '\u{8}' => output.push_str("\\b"),
            other if (other as u32) < 0x20 => {
                output.push_str(&format!("\\u{:04x}", other as u32));
            }
            other => output.push(other),
        }
    }
    output.push('"');
    output
}

/// A schema type's constant, `Types.Character`.
pub(super) fn type_reference(type_name: &str) -> String {
    format!("Types.{}", type_constant(type_name))
}

/// The constant of the members one value keys, `Types.Node_keyed`.
pub(super) fn keyed_types_reference(condition: &str) -> String {
    format!("Types.{}", crate::names::keyed_types(condition))
}

/// A slot's constant among its type's in `Slots`.
pub(super) fn slot_member(slot: &SlotRef) -> String {
    slot.member(&slot_name)
}

/// A slot's constant by its path, `Slots.Character.name`.
pub(super) fn slot_path(slot: &SlotRef) -> String {
    format!("Slots.{}.{}", slot_name(&slot.type_name), slot_member(slot))
}

/// The parts of a storage key's argument, as `KeyPart` values.
pub(super) fn key_parts(parts: &[KeyPart]) -> String {
    let parts: Vec<String> = parts
        .iter()
        .map(|part| match part {
            KeyPart::Literal(text) => format!("KeyPart.Literal({})", string_literal(text)),
            KeyPart::Variable(name) => format!("KeyPart.Variable({})", string_literal(name)),
        })
        .collect();
    format!("listOf({})", parts.join(", "))
}

/// A `Variable` expression for a constant: a variable's declared default.
pub(super) fn variable_literal(constant: &ConstantPlan) -> String {
    match constant {
        ConstantPlan::Null => "Variable.Null".to_string(),
        ConstantPlan::Bool(boolean) => format!("Variable.Bool({boolean})"),
        ConstantPlan::Int(int) => format!("Variable.Int({int})"),
        ConstantPlan::Float(float) => format!("Variable.Double({float:?})"),
        ConstantPlan::String(text) => format!("Variable.String({})", string_literal(text)),
        ConstantPlan::List(items) => format!(
            "Variable.List(listOf({}))",
            items
                .iter()
                .map(variable_literal)
                .collect::<Vec<_>>()
                .join(", ")
        ),
        ConstantPlan::Object(fields) => format!(
            "Variable.Object(mapOf({}))",
            fields
                .iter()
                .map(|(name, value)| format!(
                    "{} to {}",
                    string_literal(name),
                    variable_literal(value)
                ))
                .collect::<Vec<_>>()
                .join(", ")
        ),
    }
}

/// What a variable or an input object's field holds, in Kotlin: its base,
/// a list of it, and whether it may be null.
pub(super) struct ValueShape<'a> {
    pub base: Base<'a>,
    pub list: Option<ListShape>,
    pub non_null: bool,
}

/// The base of a value: a scalar as the accessors read it, or an input
/// object by its schema name.
pub(super) enum Base<'a> {
    Scalar(&'a Primitive),
    Input(&'a str),
}

/// The Kotlin type of each mapped scalar's converter, by the converter, as
/// `baton.json` names them.
pub(super) struct Converters<'a> {
    pub types: &'a BTreeMap<String, String>,
}

impl Converters<'_> {
    /// The base's Kotlin type: a mapped scalar's is the type the
    /// configuration names beside its converter.
    fn base_type(&self, base: &Base) -> String {
        match base {
            Base::Input(name) => input_type_name(name),
            Base::Scalar(Primitive::String) => "String".to_string(),
            Base::Scalar(Primitive::Int) => "Int".to_string(),
            Base::Scalar(Primitive::Double) => "Double".to_string(),
            Base::Scalar(Primitive::Bool) => "Boolean".to_string(),
            Base::Scalar(Primitive::Enum(name)) => enum_type_name(name),
            Base::Scalar(Primitive::Mapped(converter)) => self
                .types
                .get(converter)
                .cloned()
                .unwrap_or_else(|| panic!("the configuration names a type for `{converter}`")),
        }
    }

    /// The value's Kotlin type: `String`, `List<Int?>?`.
    pub(super) fn value_type(&self, shape: &ValueShape) -> String {
        let base = self.base_type(&shape.base);
        let element = match shape.list {
            Some(list) => {
                let nullable = if list.non_null { "" } else { "?" };
                format!("List<{base}{nullable}>")
            }
            None => base,
        };
        if shape.non_null {
            element
        } else {
            format!("{element}?")
        }
    }

    /// The `Variable` that `read`, a value of `shape` known not to be null
    /// where it is a list, is sent as.
    pub(super) fn value_expression(&self, read: &str, shape: &ValueShape) -> String {
        match shape.list {
            Some(_) => format!(
                "Variable.List({read}.map {{ {} }})",
                Self::element_expression("it", &shape.base)
            ),
            None => Self::element_expression(read, &shape.base),
        }
    }

    /// The `Variable` of one element: `Variable.of` takes every scalar, enum
    /// and input object, null among them, and a mapped scalar with its
    /// converter.
    fn element_expression(read: &str, base: &Base) -> String {
        match base {
            Base::Scalar(Primitive::Mapped(converter)) => {
                format!("Variable.of({read}, {converter})")
            }
            _ => format!("Variable.of({read})"),
        }
    }
}

/// The getter the JVM names a property `name` by: the name itself for
/// `isX`, else `get` and the name capitalized.
fn jvm_getter(name: &str) -> String {
    let mut characters = name.chars();
    if name.starts_with("is") && characters.nth(2).is_some_and(|third| !third.is_lowercase()) {
        return name.to_string();
    }
    format!("get{}", crate::naming::capitalize(name))
}

/// The JVM name each of the properties `names` declares in one class
/// needs beside its own: `None` for the first of a getter's name, and a
/// numbered one, past `taken` and every other, for each property after it
/// whose getter the JVM names alike, as `$Any` and `$any` both read as
/// `getAny()`.
pub(super) fn jvm_getters(names: &[&str], taken: &[&str]) -> Vec<Option<String>> {
    let getters: Vec<String> = names.iter().map(|name| jvm_getter(name)).collect();
    let mut used: Vec<String> = taken.iter().map(|name| name.to_string()).collect();
    used.extend(getters.iter().cloned());
    let mut seen: Vec<&str> = taken.to_vec();
    getters
        .iter()
        .map(|getter| {
            if !seen.contains(&getter.as_str()) {
                seen.push(getter);
                return None;
            }
            let mut number = 2;
            let mut renamed = format!("{getter}{number}");
            while used.contains(&renamed) {
                number += 1;
                renamed = format!("{getter}{number}");
            }
            used.push(renamed.clone());
            Some(renamed)
        })
        .collect()
}

/// A property of the class, `property` as Kotlin spells it, read inside
/// one of its getters: through `this` when it is named `field`, which a
/// getter reads as its own backing field.
pub(super) fn property_read(property: &str) -> String {
    if property == "field" {
        return format!("this.{property}");
    }
    property.to_string()
}

/// The `Variable` of a value that may be null, `read`, of `shape`: null
/// when it is, so `Variables.of` leaves the entry out.
pub(super) fn optional_value_expression(
    converters: &Converters,
    read: &str,
    shape: &ValueShape,
) -> String {
    format!(
        "{read}?.let {{ {} }}",
        converters.value_expression("it", shape)
    )
}
