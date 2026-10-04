//! Storage keys as the runtime builds them, and the slots generated code
//! names them by. The text decided here must match the runtime's byte for
//! byte: a key the compiler writes and a key the runtime renders from a
//! variable name one slot.

use crate::names::slot_name;
use crate::pipeline::{ArgumentValuePlan, ConstantPlan, StorageKeyPlan};

/// A part of a storage key as the runtime builds it: text, or an operation
/// variable rendered as JSON.
#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub enum KeyPart {
    Literal(String),
    Variable(String),
}

/// A slot the generated code refers to: a parent type and a storage key.
#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub struct SlotRef {
    pub type_name: String,
    /// The key with `$name` in place of each variable: what names the slot
    /// in this module.
    pub template: String,
    pub field: String,
    pub has_arguments: bool,
    pub parts: Vec<KeyPart>,
}

impl SlotRef {
    pub fn new(type_name: &str, key: &StorageKeyPlan) -> SlotRef {
        let parts = key_parts(key);
        SlotRef {
            type_name: type_name.to_string(),
            template: template(&parts),
            field: key.name.clone(),
            has_arguments: !key.arguments.is_empty(),
            parts,
        }
    }

    pub fn has_variables(&self) -> bool {
        self.parts
            .iter()
            .any(|part| matches!(part, KeyPart::Variable(_)))
    }

    /// The slot's name among its type's: `name`, or `characters_1a2b3c` when
    /// the key has arguments. Slots are nested per type, so a type's name
    /// and a field's never run together into another pair's.
    pub fn member(&self) -> String {
        if !self.has_arguments {
            return slot_name(&self.field);
        }
        let digest = format!("{:x}", md5::compute(self.template.as_bytes()));
        format!("{}_{}", self.field, &digest[..6])
    }

    /// The constant's path in one of the shared enums: `Slots.Character.name`.
    pub fn path(&self, family: &str) -> String {
        format!("{family}.{}.{}", slot_name(&self.type_name), self.member())
    }
}

/// A storage key as the parts the runtime joins: the name, then the
/// arguments as `name:value` in order, each value written as JSON the way the
/// runtime renders a variable (object keys sorted, floats as Swift prints
/// them), and each variable left as a part of its own.
fn key_parts(key: &StorageKeyPlan) -> Vec<KeyPart> {
    let mut parts = Vec::new();
    let mut literal = key.name.clone();
    if !key.arguments.is_empty() {
        literal.push('(');
        for (index, argument) in key.arguments.iter().enumerate() {
            if index > 0 {
                literal.push(',');
            }
            literal.push_str(&argument.name);
            literal.push(':');
            value_parts(&argument.value, &mut literal, &mut parts);
        }
        literal.push(')');
    }
    if !literal.is_empty() {
        parts.push(KeyPart::Literal(literal));
    }
    parts
}

fn value_parts(value: &ArgumentValuePlan, literal: &mut String, parts: &mut Vec<KeyPart>) {
    match value {
        ArgumentValuePlan::Variable(name) => {
            if !literal.is_empty() {
                parts.push(KeyPart::Literal(std::mem::take(literal)));
            }
            parts.push(KeyPart::Variable(name.clone()));
        }
        ArgumentValuePlan::Constant(constant) => literal.push_str(&constant_json(constant)),
        ArgumentValuePlan::List(items) => {
            literal.push('[');
            for (index, item) in items.iter().enumerate() {
                if index > 0 {
                    literal.push(',');
                }
                value_parts(item, literal, parts);
            }
            literal.push(']');
        }
        ArgumentValuePlan::Object(fields) => {
            let mut sorted: Vec<&(String, ArgumentValuePlan)> = fields.iter().collect();
            sorted.sort_by(|left, right| left.0.cmp(&right.0));
            literal.push('{');
            for (index, (name, field)) in sorted.into_iter().enumerate() {
                if index > 0 {
                    literal.push(',');
                }
                literal.push_str(&json_string(name));
                literal.push(':');
                value_parts(field, literal, parts);
            }
            literal.push('}');
        }
    }
}

/// The key with `$name` for each variable, for naming its slot.
fn template(parts: &[KeyPart]) -> String {
    parts
        .iter()
        .map(|part| match part {
            KeyPart::Literal(text) => text.clone(),
            KeyPart::Variable(name) => format!("${name}"),
        })
        .collect()
}

/// A constant as JSON, as the runtime renders the same value given as a
/// variable: `Variable.json`.
pub fn constant_json(constant: &ConstantPlan) -> String {
    match constant {
        ConstantPlan::Null => "null".to_string(),
        ConstantPlan::Bool(boolean) => boolean.to_string(),
        ConstantPlan::Int(int) => int.to_string(),
        ConstantPlan::Float(float) => swift_double(*float),
        ConstantPlan::String(text) => json_string(text),
        ConstantPlan::List(items) => format!(
            "[{}]",
            items
                .iter()
                .map(constant_json)
                .collect::<Vec<_>>()
                .join(",")
        ),
        ConstantPlan::Object(fields) => {
            let mut sorted: Vec<&(String, ConstantPlan)> = fields.iter().collect();
            sorted.sort_by(|left, right| left.0.cmp(&right.0));
            format!(
                "{{{}}}",
                sorted
                    .into_iter()
                    .map(|(name, value)| format!("{}:{}", json_string(name), constant_json(value)))
                    .collect::<Vec<_>>()
                    .join(",")
            )
        }
    }
}

/// A double as Swift's `description` prints it: the shortest digits that
/// read back, in exponent form when the exponent is 16 or more or below -4,
/// with `.0` on a whole number otherwise.
pub fn swift_double(value: f64) -> String {
    let scientific = format!("{value:e}");
    let (mantissa, exponent) = scientific
        .split_once('e')
        .expect("Rust writes an exponent in `{:e}`");
    let exponent: i32 = exponent.parse().expect("the exponent is an integer");
    if !(-4..16).contains(&exponent) {
        let sign = if exponent < 0 { '-' } else { '+' };
        return format!("{mantissa}e{sign}{:02}", exponent.abs());
    }
    let decimal = format!("{value}");
    if decimal.contains('.') {
        decimal
    } else {
        format!("{decimal}.0")
    }
}

/// A JSON string literal, escaped as `Variable.quote` escapes one.
fn json_string(text: &str) -> String {
    let mut output = String::with_capacity(text.len() + 2);
    output.push('"');
    for character in text.chars() {
        match character {
            '"' => output.push_str("\\\""),
            '\\' => output.push_str("\\\\"),
            '\n' => output.push_str("\\n"),
            '\r' => output.push_str("\\r"),
            '\t' => output.push_str("\\t"),
            other if (other as u32) < 0x20 => output.push_str(&format!("\\u{:04x}", other as u32)),
            other => output.push(other),
        }
    }
    output.push('"');
    output
}
