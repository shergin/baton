//! Storage keys as the runtime builds them, and the slots generated code
//! names them by. The text decided here must match the runtime's byte for
//! byte: a key the compiler writes and a key the runtime renders from a
//! variable name one slot.

use crate::pipeline::{ArgumentValuePlan, ConstantPlan, StorageKeyPlan};

/// A part of an argument's value as the runtime builds it: text, or an
/// operation variable rendered as JSON.
#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub enum KeyPart {
    Literal(String),
    Variable(String),
}

/// An argument of a storage key: its name and the parts of its value. One
/// whose value is a variable that is null is left out of the key, as Relay
/// leaves a null argument out; one whose constant is null is left out here.
#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub struct KeyArgument {
    pub name: String,
    pub value: Vec<KeyPart>,
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
    pub arguments: Vec<KeyArgument>,
}

impl SlotRef {
    pub fn new(type_name: &str, key: &StorageKeyPlan) -> SlotRef {
        let arguments = key_arguments(key);
        SlotRef {
            type_name: type_name.to_string(),
            template: template(&key.name, &arguments),
            field: key.name.clone(),
            has_arguments: !arguments.is_empty(),
            arguments,
        }
    }

    pub fn has_variables(&self) -> bool {
        self.arguments.iter().any(|argument| {
            argument
                .value
                .iter()
                .any(|part| matches!(part, KeyPart::Variable(_)))
        })
    }

    /// The slot's name among its type's: `name` as `slot_name` spells a
    /// field's, or `characters_1a2b3c` when the key has arguments. Slots are
    /// nested per type, so a type's name and a field's never run together
    /// into another pair's.
    pub fn member(&self, slot_name: &dyn Fn(&str) -> String) -> String {
        if !self.has_arguments {
            return slot_name(&self.field);
        }
        let digest = format!("{:x}", md5::compute(self.template.as_bytes()));
        format!("{}_{}", self.field, &digest[..6])
    }
}

/// A storage key's arguments as the runtime joins them after the name,
/// `name:value` in order, each value written as JSON the way the runtime
/// renders a variable (object keys sorted, floats as Swift prints them),
/// each variable left as a part of its own. An argument whose constant is
/// null is left out, as Relay's storage key leaves it.
fn key_arguments(key: &StorageKeyPlan) -> Vec<KeyArgument> {
    key.arguments
        .iter()
        .filter(|argument| {
            !matches!(
                argument.value,
                ArgumentValuePlan::Constant(ConstantPlan::Null)
            )
        })
        .map(|argument| {
            let mut literal = String::new();
            let mut parts = Vec::new();
            value_parts(&argument.value, &mut literal, &mut parts);
            if !literal.is_empty() {
                parts.push(KeyPart::Literal(literal));
            }
            KeyArgument {
                name: argument.name.clone(),
                value: parts,
            }
        })
        .collect()
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

/// The key with `$name` for each variable, for naming its slot; the key's
/// text itself when it has no variable.
fn template(name: &str, arguments: &[KeyArgument]) -> String {
    if arguments.is_empty() {
        return name.to_string();
    }
    let rendered: Vec<String> = arguments
        .iter()
        .map(|argument| {
            let value: String = argument
                .value
                .iter()
                .map(|part| match part {
                    KeyPart::Literal(text) => text.clone(),
                    KeyPart::Variable(variable) => format!("${variable}"),
                })
                .collect();
            format!("{}:{value}", argument.name)
        })
        .collect();
    format!("{name}({})", rendered.join(","))
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
