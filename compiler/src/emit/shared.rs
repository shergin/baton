//! The shared file: `Types`, `Slots` and, when the module has any, `Sites`
//! and `AbstractSlots`, as the decide pass collected them.

use std::fmt::Write as _;

use super::HEADER;
use super::swift::swift_literal;
use crate::decide::{KeyPart, Shared, SlotRef};
use crate::names::slot_name;

/// `Types`, `Slots` and, when the module has any, `Sites` and
/// `AbstractSlots`.
pub(super) fn shared_text(shared: &Shared) -> String {
    let mut output = String::new();
    output.push_str(HEADER);
    output.push('\n');
    output.push_str(
        "/// Interned schema types used by this module's documents.\nnonisolated enum Types {\n",
    );
    let _ = writeln!(
        output,
        "    /// The schema's digest: pass it as the image's `version`, so an image\n    /// written under another schema starts again.\n    static let schemaDigest = \"{}\"",
        shared.schema_digest
    );
    for type_name in &shared.types {
        // A root type is interned by the name the store's root record
        // has, so its slots are numbered where the root's values are.
        let interned = shared.root_names.get(type_name).unwrap_or(type_name);
        let _ = writeln!(
            output,
            "    static let {type_name} = Baton.Registry.type(\"{interned}\")"
        );
    }
    // Inside `Types` the members are named bare: a schema type named
    // `Types` is a member that hides the enum's own name.
    for (condition, types) in &shared.possible_sets {
        let members: Vec<&str> = types.iter().map(String::as_str).collect();
        let _ = writeln!(
            output,
            "    /// The types that satisfy `... on {condition}`.\n    static let {condition}_possible: Set<Baton.TypeID> = [{}]",
            members.join(", ")
        );
    }
    output.push_str(
        "}\n\n/// Interned storage keys used by this module's documents.\nnonisolated enum Slots {\n",
    );
    let mut current: Option<&str> = None;
    for slot in &shared.slots {
        if current != Some(slot.type_name.as_str()) {
            if current.is_some() {
                output.push_str("    }\n");
            }
            let _ = writeln!(
                output,
                "    nonisolated enum {} {{",
                slot_name(&slot.type_name)
            );
            current = Some(&slot.type_name);
        }
        if slot.has_variables() {
            let _ = writeln!(
                output,
                "        static let {} = Baton.DynamicKey(Types.{}, {})",
                slot.member(),
                slot.type_name,
                parts_literal(slot)
            );
        } else {
            let _ = writeln!(
                output,
                "        static let {} = Baton.Registry.slot(Types.{}, {})",
                slot.member(),
                slot.type_name,
                swift_literal(&slot.template)
            );
        }
    }
    if current.is_some() {
        output.push_str("    }\n");
    }
    output.push_str("}\n");
    if !shared.sites.is_empty() {
        output.push_str(
            "\n/// The spreads with `@arguments`, where an owner binds a fragment's scope once.\nnonisolated enum Sites {\n",
        );
        for site in &shared.sites {
            let _ = writeln!(output, "    static let {site} = Baton.ArgumentSite()");
        }
        output.push_str("}\n");
    }
    if !shared.abstract_slots.is_empty() {
        output.push_str(
            "\n/// Storage keys read on interfaces and unions, each resolved once per concrete type.\nnonisolated enum AbstractSlots {\n",
        );
        let mut current: Option<&str> = None;
        for slot in &shared.abstract_slots {
            if current != Some(slot.type_name.as_str()) {
                if current.is_some() {
                    output.push_str("    }\n");
                }
                let _ = writeln!(
                    output,
                    "    nonisolated enum {} {{",
                    slot_name(&slot.type_name)
                );
                current = Some(&slot.type_name);
            }
            let _ = writeln!(
                output,
                "        static let {} = Baton.AbstractSlot({})",
                slot.member(),
                swift_literal(&slot.template)
            );
        }
        output.push_str("    }\n}\n");
    }
    output
}

/// The parts of a key with variables, as `Baton.KeyPart` literals.
fn parts_literal(slot: &SlotRef) -> String {
    let parts: Vec<String> = slot
        .parts
        .iter()
        .map(|part| match part {
            KeyPart::Literal(text) => format!(".literal({})", swift_literal(text)),
            KeyPart::Variable(name) => format!(".variable({})", swift_literal(name)),
        })
        .collect();
    format!("[{}]", parts.join(", "))
}
