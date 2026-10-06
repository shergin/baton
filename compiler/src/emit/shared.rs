//! The shared file: `Types`, `Slots` and, when the module has any, `Sites`
//! and `AbstractSlots`, as the decide pass collected them.
//!
//! The shared enums name the runtime's module in expressions, which is safe
//! here alone: their members are spelled off its name, as `names` decides.

use super::swift::{runtime_value, swift_literal, type_reference};
use super::writer::Writer;
use super::{FORMAT, HEADER};
use crate::decide::{KeyPart, Shared, SlotRef};
use crate::names::{
    enum_case_name, enum_type_name, guard_name, keyed_types, possible_types, slot_name,
    type_constant,
};

/// `Types`, `Slots` and, when the module has any, `Sites` and
/// `AbstractSlots`.
pub(super) fn shared_text(shared: &Shared) -> String {
    let mut writer = Writer::new();
    writer.doc("Interned schema types used by this module's documents.");
    writer.block("nonisolated enum Types", |writer| {
        writer.doc("The schema's digest: pass it as the image's `version`, so an image");
        writer.doc("written under another schema starts again.");
        writer.line(format!(
            "static let schemaDigest = {}",
            swift_literal(&shared.schema_digest)
        ));
        writer.doc("The format of this generated code, which the runtime that reads it");
        writer.doc("declares; a runtime of another format fails to compile this line.");
        writer.line(format!(
            "static let format = {}.self",
            runtime_value(&format!("Format{FORMAT}"))
        ));
        for type_name in &shared.types {
            // A root type is interned by the name the store's root record
            // has, so its slots are numbered where the root's values are.
            let interned = shared.root_names.get(type_name).unwrap_or(type_name);
            writer.line(format!(
                "static let {} = {}({})",
                type_constant(type_name),
                runtime_value("Registry.type"),
                swift_literal(interned)
            ));
        }
        // Inside `Types` the members are named bare: a schema type named
        // `Types` is a member that hides the enum's own name. `Set` is
        // qualified, as a type of the module may take its name.
        for (condition, types) in &shared.possible_sets {
            let members: Vec<String> = types.iter().map(|name| type_constant(name)).collect();
            writer.doc(format!(
                "The types that satisfy `... on {condition}`, as the build knows them."
            ));
            writer.line(format!(
                "static let {} = {}({}, [{}])",
                possible_types(condition),
                runtime_value("Members"),
                type_constant(condition),
                members.join(", ")
            ));
        }
        for (condition, types) in &shared.keyed_sets {
            let members: Vec<String> = types.iter().map(|name| type_constant(name)).collect();
            writer.doc(format!(
                "The types that satisfy `... on {condition}` that one value keys, which a lookup without a type probes."
            ));
            writer.line(format!(
                "static let {} = {}({}, [{}])",
                keyed_types(condition),
                runtime_value("Members"),
                type_constant(condition),
                members.join(", ")
            ));
        }
    });
    writer.blank();
    writer.doc("Interned storage keys used by this module's documents.");
    writer.block("nonisolated enum Slots", |writer| {
        for (type_name, slots) in by_type(&shared.slots) {
            writer.block(
                format!("nonisolated enum {}", slot_name(type_name)),
                |writer| {
                    for slot in slots {
                        let initializer = if slot.has_variables() {
                            format!(
                                "{}({}, {})",
                                runtime_value("DynamicKey"),
                                type_reference(&slot.type_name),
                                parts_literal(slot)
                            )
                        } else {
                            // A schema extension's slot is the client's: the
                            // registry marks it, so a read of it absent
                            // reports nothing missing and heals nothing.
                            let intern = if shared.client_slots.contains(slot) {
                                "Registry.clientSlot"
                            } else {
                                "Registry.slot"
                            };
                            format!(
                                "{}({}, {})",
                                runtime_value(intern),
                                type_reference(&slot.type_name),
                                swift_literal(&slot.template)
                            )
                        };
                        writer.line(format!("static let {} = {initializer}", slot.member()));
                    }
                },
            );
        }
    });
    if !shared.guards.is_empty() {
        writer.blank();
        writer.doc("The conditions `@include` and `@skip` put on selections, which an owner settles once each.");
        writer.block("nonisolated enum Guards", |writer| {
            for guard in &shared.guards {
                writer.line(format!(
                    "static let {} = {}({}, passing: {})",
                    guard_name(&guard.variable, guard.passing),
                    runtime_value("Guard"),
                    swift_literal(&guard.variable),
                    guard.passing
                ));
            }
        });
    }
    if !shared.sites.is_empty() {
        writer.blank();
        writer.doc("The spreads with `@arguments`, where an owner binds a fragment's scope once.");
        writer.block("nonisolated enum Sites", |writer| {
            for site in &shared.sites {
                writer.line(format!(
                    "static let {site} = {}()",
                    runtime_value("ArgumentSite")
                ));
            }
        });
    }
    for (name, values) in &shared.enums {
        writer.blank();
        writer.doc(format!(
            "The schema's enum `{name}`. A value this build does not know reads as `unknown`, with its text."
        ));
        writer.block(
            format!(
                "nonisolated public enum {}: {}",
                enum_type_name(name),
                runtime_value("GeneratedEnum")
            ),
            |writer| {
                for value in values {
                    writer.line(format!("case {}", enum_case_name(value)));
                }
                writer.line("case unknown(String)");
                writer.blank();
                writer.block("public init(enumText: String)", |writer| {
                    writer.block("self = switch enumText", |writer| {
                        for value in values {
                            writer.line(format!(
                                "case {}: .{}",
                                swift_literal(value),
                                enum_case_name(value)
                            ));
                        }
                        writer.line("default: .unknown(enumText)");
                    });
                });
                writer.blank();
                writer.block("public var scalarText: String", |writer| {
                    writer.block("switch self", |writer| {
                        for value in values {
                            writer.line(format!(
                                "case .{}: {}",
                                enum_case_name(value),
                                swift_literal(value)
                            ));
                        }
                        writer.line("case .unknown(let text): text");
                    });
                });
            },
        );
    }
    if !shared.abstract_slots.is_empty() {
        writer.blank();
        writer.doc(
            "Storage keys read on interfaces and unions, each resolved once per concrete type.",
        );
        writer.block("nonisolated enum AbstractSlots", |writer| {
            for (type_name, slots) in by_type(&shared.abstract_slots) {
                writer.block(
                    format!("nonisolated enum {}", slot_name(type_name)),
                    |writer| {
                        for slot in slots {
                            writer.line(format!(
                                "static let {} = {}({})",
                                slot.member(),
                                runtime_value("AbstractSlot"),
                                swift_literal(&slot.template)
                            ));
                        }
                    },
                );
            }
        });
    }
    format!("{HEADER}\n{}", writer.finish())
}

/// The slots in runs of one type, in the order they come: each run is one
/// nested enum.
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

/// The parts of a key with variables, as `Baton.KeyPart` literals.
fn parts_literal(slot: &SlotRef) -> String {
    let arguments: Vec<String> = slot
        .arguments
        .iter()
        .map(|argument| {
            let parts: Vec<String> = argument
                .value
                .iter()
                .map(|part| match part {
                    KeyPart::Literal(text) => format!(".literal({})", swift_literal(text)),
                    KeyPart::Variable(name) => format!(".variable({})", swift_literal(name)),
                })
                .collect();
            format!(
                "{}({}, [{}])",
                runtime_value("KeyArgument"),
                swift_literal(&argument.name),
                parts.join(", ")
            )
        })
        .collect();
    format!("{}, [{}]", swift_literal(&slot.field), arguments.join(", "))
}
