//! The shared file in Kotlin: `object Types`, `object Slots` with each
//! connection type's `ConnectionSlots`, the schema's enums as sealed
//! interfaces and its input objects as data classes, as the decide pass
//! collected them.

use std::collections::BTreeMap;

use super::super::writer::Writer;
use super::literal::{
    Base, Converters, ValueShape, jvm_getters, key_parts, property_read, slot_member,
    string_literal, type_reference,
};
use super::{FORMAT, header};
use crate::decide::{InputField, ListShape, Shared, SlotRef};
use crate::kotlin_names::{
    enum_type_name, enum_value_name, input_field_name, input_type_name, slot_name, type_constant,
};
use crate::names::{keyed_types, possible_types};
use crate::pipeline::TypeKind;

/// A connection type's cells: its edge and page info types.
pub(super) struct ConnectionTypes {
    pub edge: String,
    pub page_info: String,
}

/// The name of a connection type's `ConnectionSlots` in its slots' object:
/// `connection`, past a slot of the type's of that name.
pub(super) fn connection_member(type_name: &str, shared: &Shared) -> String {
    let taken: Vec<String> = shared
        .slots
        .iter()
        .filter(|slot| slot.type_name == type_name)
        .map(slot_member)
        .collect();
    let mut name = "connection".to_string();
    while taken.contains(&name) {
        name.push('_');
    }
    name
}

/// The shared file of `package`: `Types`, `Slots`, the enums and the input
/// objects.
pub(super) fn shared_text(
    shared: &Shared,
    connections: &BTreeMap<String, ConnectionTypes>,
    converters: &Converters,
    package: Option<&str>,
) -> String {
    let mut writer = Writer::new();
    writer.line("/** Interned schema types used by this module's documents. */");
    writer.block("object Types", |writer| {
        writer.line("/** The schema's digest: pass it as the image's `version`, so an image written under another schema starts again. */");
        writer.line(format!(
            "val schemaDigest = {}",
            string_literal(&shared.schema_digest)
        ));
        writer.line("/** The format of this generated code, which the runtime that reads it declares; a runtime of another format fails to compile this line. */");
        writer.line(format!("val format = baton.Format{FORMAT}"));
        for type_name in &shared.types {
            // A root type is interned by the name the store's root record
            // has, so its slots are numbered where the root's values are.
            let interned = shared.root_names.get(type_name).unwrap_or(type_name);
            let transient = if shared.transient_types.contains(type_name) {
                ", transient = true"
            } else {
                ""
            };
            writer.line(format!(
                "val {}: TypeID = Registry.type({}{transient})",
                type_constant(type_name),
                string_literal(interned)
            ));
        }
        if !shared.transient_types.is_empty() || !shared.transient_fields.is_empty() {
            let types: Vec<String> = shared
                .transient_types
                .iter()
                .map(|name| type_constant(name))
                .collect();
            let fields: Vec<String> = shared
                .transient_fields
                .iter()
                .map(|(type_name, field)| {
                    format!("{} to {}", type_constant(type_name), string_literal(field))
                })
                .collect();
            writer.line("/** What never reaches the image: the types whose records are not written, and the root fields whose cells, keys and operations are not. */");
            writer.line(format!(
                "val transient = Transient(types = listOf({}), fields = listOf({}))",
                types.join(", "),
                fields.join(", ")
            ));
        }
        for (condition, types) in &shared.possible_sets {
            let members: Vec<String> = types.iter().map(|name| type_constant(name)).collect();
            writer.line(format!(
                "/** The types that satisfy `... on {condition}`, as the build knows them. */"
            ));
            writer.line(format!(
                "val {} = Members({}, listOf({}))",
                possible_types(condition),
                type_constant(condition),
                members.join(", ")
            ));
        }
        for (condition, types) in &shared.keyed_sets {
            let members: Vec<String> = types.iter().map(|name| type_constant(name)).collect();
            writer.line(format!(
                "/** The types that satisfy `... on {condition}` that one value keys, which a lookup without a type probes. */"
            ));
            writer.line(format!(
                "val {} = Members({}, listOf({}))",
                keyed_types(condition),
                type_constant(condition),
                members.join(", ")
            ));
        }
    });
    writer.blank();
    writer.line("/** Interned storage keys used by this module's documents. */");
    writer.block("object Slots", |writer| {
        let mut runs = by_type(&shared.slots);
        for type_name in connections.keys() {
            if !runs.iter().any(|(name, _)| name == type_name) {
                runs.push((type_name.as_str(), Vec::new()));
            }
        }
        runs.sort_by(|left, right| left.0.cmp(right.0));
        for (type_name, slots) in runs {
            writer.block(format!("object {}", slot_name(type_name)), |writer| {
                for slot in slots {
                    writer.line(slot_declaration(slot, shared));
                }
                if let Some(connection) = connections.get(type_name) {
                    writer.line(format!(
                        "val {} = ConnectionSlots({}, {}, {})",
                        connection_member(type_name, shared),
                        type_reference(type_name),
                        type_reference(&connection.edge),
                        type_reference(&connection.page_info)
                    ));
                }
            });
        }
    });
    for (name, values) in &shared.enums {
        writer.blank();
        enum_text(&mut writer, name, values);
    }
    for (name, fields) in &shared.inputs {
        writer.blank();
        let type_name = input_type_name(name);
        writer.line(format!(
            "/** The schema's input object `{name}`. A field left null is absent from the request, as GraphQL distinguishes absent from null. */"
        ));
        let names: Vec<&str> = fields.iter().map(|field| field.name.as_str()).collect();
        let getters = jvm_getters(&names, &["getVariable"]);
        let parameters: Vec<String> = fields
            .iter()
            .zip(getters)
            .map(|(field, getter)| {
                let shape = field_shape(field);
                let default = if shape.non_null { "" } else { " = null" };
                let annotation = getter
                    .map(|getter| format!("@get:JvmName({}) ", string_literal(&getter)))
                    .unwrap_or_default();
                format!(
                    "{annotation}val {}: {}{default}",
                    input_field_name(&field.name),
                    converters.value_type(&shape)
                )
            })
            .collect();
        writer.block(
            format!(
                "data class {type_name}({}) : InputObject",
                parameters.join(", ")
            ),
            |writer| {
                writer.line("override val variable: Variable");
                writer.closed_block(
                    "    get() = Variable.Object(buildMap {",
                    "    })",
                    |writer| {
                        for field in fields {
                            let shape = field_shape(field);
                            let read = property_read(&type_name, &input_field_name(&field.name));
                            let key = string_literal(&field.name);
                            let value = converters.value_expression(&read, &shape);
                            if shape.non_null {
                                writer.line(format!("    put({key}, {value})"));
                            } else {
                                writer.line(format!("    if ({read} != null) put({key}, {value})"));
                            }
                        }
                    },
                );
            },
        );
    }
    let body = writer.finish();
    format!("{}{body}", header(package, &body, &[]))
}

/// A slot's declaration in its type's object: a constant key interned, a
/// schema extension's as the client's, or a key with variables to render.
fn slot_declaration(slot: &SlotRef, shared: &Shared) -> String {
    let member = slot_member(slot);
    if slot.has_variables() {
        let arguments: Vec<String> = slot
            .arguments
            .iter()
            .map(|argument| {
                format!(
                    "KeyArgument({}, {})",
                    string_literal(&argument.name),
                    key_parts(&argument.value)
                )
            })
            .collect();
        return format!(
            "val {member} = DynamicKey({}, {}, listOf({}))",
            type_reference(&slot.type_name),
            string_literal(&slot.field),
            arguments.join(", ")
        );
    }
    // A schema extension's slot is the client's: the registry marks it, so
    // a read of it absent reports nothing missing and heals nothing.
    let intern = if shared.client_slots.contains(slot) {
        "clientSlot"
    } else {
        "slot"
    };
    format!(
        "val {member}: Slot = Registry.{intern}({}, {})",
        type_reference(&slot.type_name),
        string_literal(&slot.template)
    )
}

/// A schema enum as a sealed interface: an object per value, keeping the
/// schema's spelling, and `Unknown` for a value this build does not know.
fn enum_text(writer: &mut Writer, name: &str, values: &[String]) {
    let type_name = enum_type_name(name);
    writer.line(format!(
        "/** The schema's enum `{name}`. A value this build does not know reads as `Unknown`, with its text. */"
    ));
    writer.block(
        format!("sealed interface {type_name} : GeneratedEnum"),
        |writer| {
            for value in values {
                writer.line(format!(
                    "data object {} : {type_name} {{ override val scalarText: String get() = {} }}",
                    enum_value_name(value, &type_name),
                    string_literal(value)
                ));
            }
            writer.line(format!(
                "data class Unknown(override val scalarText: String) : {type_name}"
            ));
            writer.blank();
            writer.block("companion object", |writer| {
                writer.line("/** The value `text` names, or `Unknown` with it. */");
                writer.block(
                    format!("fun of(text: String): {type_name} = when (text)"),
                    |writer| {
                        for value in values {
                            writer.line(format!(
                                "{} -> {}",
                                string_literal(value),
                                enum_value_name(value, &type_name)
                            ));
                        }
                        writer.line("else -> Unknown(text)");
                    },
                );
            });
        },
    );
}

/// The slots in runs of one type, in the order they come: each run is one
/// nested object.
fn by_type<'a>(slots: impl IntoIterator<Item = &'a SlotRef>) -> Vec<(&'a str, Vec<&'a SlotRef>)> {
    let mut runs: Vec<(&str, Vec<&SlotRef>)> = Vec::new();
    for slot in slots {
        match runs.last_mut() {
            Some((type_name, run)) if *type_name == slot.type_name => run.push(slot),
            _ => runs.push((slot.type_name.as_str(), vec![slot])),
        }
    }
    runs
}

/// What an input object's field holds.
fn field_shape(field: &InputField) -> ValueShape<'_> {
    let base = match field.type_.base_kind() {
        TypeKind::InputObject => Base::Input(field.type_.base_name()),
        _ => Base::Scalar(&field.primitive),
    };
    ValueShape {
        base,
        list: ListShape::of(&field.type_),
        non_null: field.type_.non_null(),
    }
}
