//! Swift literals and parameters, as every printer writes them.

use crate::names::escape;
use crate::pipeline::{ArgumentValuePlan, ConstantPlan};

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

/// A raw multi-line Swift string literal holding `text` as it is. Its
/// delimiter takes one `#` more than the longest run of them in the text,
/// so no backslash in the text starts an escape and no `"""` ends the
/// literal.
pub(super) fn raw_multiline_literal(text: &str) -> String {
    let longest = text
        .split(|character| character != '#')
        .map(str::len)
        .max()
        .unwrap_or(0);
    let hashes = "#".repeat(longest + 1);
    format!("{hashes}\"\"\"\n{text}\n\"\"\"{hashes}")
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
                .map(|item| format!("{} ?? .null", argument_expression(item)))
                .collect::<Vec<_>>()
                .join(", ")
        ),
        ArgumentValuePlan::Object(fields) => format!(
            ".object([{}])",
            fields
                .iter()
                .map(|(name, field)| format!(
                    "{}: {} ?? .null",
                    swift_literal(name),
                    argument_expression(field)
                ))
                .collect::<Vec<_>>()
                .join(", ")
        ),
    }
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
