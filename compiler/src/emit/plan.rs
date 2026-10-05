//! The normalization plan as `Baton.Plan` static data.

use std::fmt::Write as _;

use super::swift::{constant_text, possible_types_reference, swift_literal, type_reference};
use crate::decide::{
    self, Guard, NormalizationField, NormalizationKind, NormalizationSelection, SlotRef,
};
use crate::pipeline::{
    ArgumentValuePlan, ConnectionPlan, ConstantPlan, EditPlan, LookupPlan, StorageKeyPlan, TypeKind,
};

/// The `Baton.Selection(...)` expression of a normalization plan, laid out
/// over several lines for a declaration written at `depth`.
pub(super) fn selection_plan(selection: &NormalizationSelection, depth: usize) -> String {
    let mut output = String::new();
    write_selection(&mut output, selection, depth);
    output
}

/// Writes a selection: its fields when every type reads the same, else its
/// variants.
fn write_selection(output: &mut String, selection: &NormalizationSelection, depth: usize) {
    let type_name = &selection.type_name;
    let pad = "    ".repeat(depth);
    let _ = write!(
        output,
        "Baton.Selection(type: {}, hasID: {}, abstract: {}",
        type_reference(type_name),
        selection.has_id,
        selection.is_abstract
    );
    if let [only] = selection.variants.as_slice()
        && only.types.is_none()
    {
        output.push_str(", fields: [");
        plan_fields(output, only.slot_type(selection), &only.fields, depth);
        output.push_str("])");
        return;
    }
    output.push_str(", variants: [");
    for variant in &selection.variants {
        let types = match &variant.types {
            Some(types) => {
                let names: Vec<String> = types.iter().map(|name| type_reference(name)).collect();
                format!("[{}]", names.join(", "))
            }
            None => "nil".to_string(),
        };
        let _ = write!(output, "\n{pad}    .init(types: {types}, fields: [");
        plan_fields(
            output,
            variant.slot_type(selection),
            &variant.fields,
            depth + 1,
        );
        output.push_str("]),");
    }
    let _ = write!(output, "\n{pad}])");
}

/// The fields of one variant, their slots on `type_name`.
fn plan_fields(output: &mut String, type_name: &str, fields: &[NormalizationField], depth: usize) {
    let pad = "    ".repeat(depth);
    for field in fields {
        let _ = write!(output, "\n{pad}    ");
        let slot = plan_key(type_name, &field.key);
        let edit_argument = field
            .edit
            .as_ref()
            .map(|edit| format!(", edit: {}", edit_expression(edit)))
            .unwrap_or_default();
        let deferred_argument = field
            .deferred
            .as_ref()
            .map(|label| format!(", deferred: {}", swift_literal(label)))
            .unwrap_or_default();
        let caught_argument = if field.caught { ", caught: true" } else { "" };
        let guards_argument = guards_expression(&field.guards);
        match &field.kind {
            NormalizationKind::Scalar { base_kind, list } => {
                let kind = match base_kind {
                    TypeKind::Int => "int",
                    TypeKind::Float => "double",
                    TypeKind::Boolean => "bool",
                    TypeKind::String | TypeKind::Id | TypeKind::Enum => "string",
                    _ => "custom",
                };
                let _ = write!(
                    output,
                    ".scalar({}, key: {slot}, kind: .{kind}, list: {list}{edit_argument}{deferred_argument}{caught_argument}{guards_argument}),",
                    swift_literal(&field.response_key)
                );
            }
            NormalizationKind::Linked {
                plural,
                lookup,
                connection,
                selection,
            } => {
                let lookup_argument = match lookup {
                    Some(lookup) => format!(
                        ", lookup: {}",
                        lookup_expression(lookup, &selection.type_name)
                    ),
                    None => String::new(),
                };
                let connection_argument = connection
                    .as_ref()
                    .map(|connection| {
                        format!(
                            ", connection: {}",
                            connection_expression(type_name, &selection.type_name, connection)
                        )
                    })
                    .unwrap_or_default();
                let _ = write!(
                    output,
                    ".linked({}, key: {slot}, plural: {plural}{lookup_argument}{connection_argument}{edit_argument}{deferred_argument}{caught_argument}{guards_argument}, selection: ",
                    swift_literal(&field.response_key)
                );
                write_selection(output, selection, depth + 1);
                output.push_str("),");
            }
        }
    }
    if !fields.is_empty() {
        let _ = write!(output, "\n{pad}");
    }
}

/// The key expression inside a plan: a fixed slot, or the key with
/// variables an owner renders.
fn plan_key(type_name: &str, storage_key: &StorageKeyPlan) -> String {
    let slot = SlotRef::new(type_name, storage_key);
    if slot.has_variables() {
        format!(".dynamic({})", slot.path("Slots"))
    } else {
        format!(".fixed({})", slot.path("Slots"))
    }
}

/// The lookup: the entity type, or for a field that returns an interface
/// or union the set of its possible types, and the argument's value, a
/// variable or a constant written as a record key writes it: a string as
/// itself, anything else as JSON.
fn lookup_expression(lookup: &LookupPlan, base_type: &str) -> String {
    let types = match &lookup.type_name {
        Some(type_name) => format!("type: {}", type_reference(type_name)),
        None => format!(
            "type: nil, possibleTypes: {}",
            possible_types_reference(base_type)
        ),
    };
    let key = match &lookup.value {
        ArgumentValuePlan::Variable(name) => format!(".variable({})", swift_literal(name)),
        ArgumentValuePlan::Constant(ConstantPlan::String(text)) => {
            format!(".literal({})", swift_literal(text))
        }
        ArgumentValuePlan::Constant(constant) => {
            format!(
                ".literal({})",
                swift_literal(&decide::constant_json(constant))
            )
        }
        ArgumentValuePlan::List(_) | ArgumentValuePlan::Object(_) => {
            unreachable!("lowering rejects a lookup argument that is a list or an object")
        }
    };
    format!("Baton.Lookup({types}, key: {key})")
}

/// The plan's description of a connection: the client key on the parent
/// type, the slots of the connection, edge and page info types, and the
/// cursor arguments that pick the merge mode.
fn connection_expression(
    parent_type: &str,
    connection_type: &str,
    connection: &ConnectionPlan,
) -> String {
    let key = plan_key(parent_type, &connection.storage_key);
    let cursor = |value: &Option<ArgumentValuePlan>, label: &str| match value {
        Some(ArgumentValuePlan::Variable(name)) => {
            format!(", {label}: .variable({})", swift_literal(name))
        }
        Some(_) => format!(", {label}: .literal"),
        None => String::new(),
    };
    format!(
        "Baton.ConnectionPlan(key: {key}, slots: Baton.ConnectionSlots(connection: {}, edge: {}, pageInfo: {}){}{})",
        type_reference(connection_type),
        type_reference(&connection.edge_type),
        type_reference(&connection.page_info_type),
        cursor(&connection.after, "after"),
        cursor(&connection.before, "before")
    )
}

/// The plan's description of an edge directive.
fn edit_expression(edit: &EditPlan) -> String {
    let connections = match &edit.connections {
        Some(ArgumentValuePlan::Variable(name)) => {
            format!(", connections: .variable({})", swift_literal(name))
        }
        Some(ArgumentValuePlan::Constant(ConstantPlan::List(items))) => format!(
            ", connections: .literal([{}])",
            items
                .iter()
                .map(|item| match item {
                    ConstantPlan::String(text) => swift_literal(text),
                    other => swift_literal(&constant_text(other)),
                })
                .collect::<Vec<_>>()
                .join(", ")
        ),
        Some(ArgumentValuePlan::Constant(other)) => {
            format!(
                ", connections: .literal([{}])",
                swift_literal(&constant_text(other))
            )
        }
        Some(ArgumentValuePlan::List(_) | ArgumentValuePlan::Object(_)) => {
            unreachable!("lowering rejects connections given as a list with variables")
        }
        None => String::new(),
    };
    let edge_type = match &edit.edge_type_name {
        Some(name) => format!(", edgeType: {}", type_reference(name)),
        None => String::new(),
    };
    format!(
        "Baton.Edit(kind: .{}{connections}{edge_type})",
        edit.kind.name()
    )
}

/// The `guards:` argument of a plan field: none when the field is always
/// fetched.
fn guards_expression(guards: &[Vec<Guard>]) -> String {
    if guards.is_empty() {
        return String::new();
    }
    let alternatives: Vec<String> = guards
        .iter()
        .map(|conjunction| {
            let conditions: Vec<String> = conjunction
                .iter()
                .map(|guard| {
                    format!(
                        ".init({}, passing: {})",
                        swift_literal(&guard.variable),
                        guard.passing
                    )
                })
                .collect();
            format!("[{}]", conditions.join(", "))
        })
        .collect();
    format!(", guards: [{}]", alternatives.join(", "))
}
