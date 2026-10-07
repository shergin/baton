//! Values: an `@inline` fragment's value and every value nested in it,
//! printed from the same `ReaderPlan` a lens is. A value is a `Sendable`,
//! `Hashable` struct with one stored property per accessor the lens would
//! have, a public initializer that takes them, so a test builds one, and
//! the initializer generated code calls, `init(anchor:)`, which reads every
//! property out of the record once, on the main actor, at the call. The
//! reads are the lens's: a property is assigned the expression the
//! accessor would compute, so what a read registers and reports is the
//! same (`docs/decisions/a-fragment-has-one-reading.md`).
//!
//! A read that needs statements, a spread with arguments or guards, is a
//! closure called where it stands, so its locals and alias stay its own.

use super::lens::{
    Piece, aliased_piece, condition_piece, field_errors_function, guard_condition,
    is_present_function, linked_piece, scalar_piece, spread_piece,
};
use super::swift::SwiftType;
use super::writer::Writer;
use crate::decide::{Accessor, FragmentLens, Read, ReaderPlan, local_name};
use crate::names::escape;

pub(super) fn fragment_text(fragment: &FragmentLens) -> String {
    let mut writer = Writer::new();
    writer.doc(format!(
        "Value of `fragment {} on {} @inline`.",
        fragment.name, fragment.type_condition
    ));
    value(&mut writer, &fragment.lens);
    writer.blank();
    writer.finish()
}

/// A stored property of a value: its name, escaped, its type, and how
/// `init(anchor:)` reads it.
struct Property {
    name: String,
    /// The accessor's name as the document spells it, unescaped.
    field: String,
    swift_type: SwiftType,
    read: Assignment,
}

enum Assignment {
    Expression(String),
    /// The statements of a closure called where it stands.
    Closure(Vec<String>),
}

/// A value struct and the values nested in it.
fn value(writer: &mut Writer, plan: &ReaderPlan) {
    debug_assert!(
        plan.refetch.is_none() && plan.connection.is_none() && plan.satisfied.is_none(),
        "an inline fragment is neither refetchable nor a connection and has no required field"
    );
    let head = format!(
        "nonisolated public struct {}: Swift.Sendable, Swift.Hashable",
        SwiftType::named(&plan.name)
    );
    writer.block(head, |writer| {
        let properties: Vec<Property> = plan.accessors.iter().map(property).collect();
        for property in &properties {
            writer.line(format!(
                "public let {}: {}",
                property.name, property.swift_type
            ));
        }
        memberwise_initializer(writer, &properties);
        reading_initializer(writer, &properties);
        if let Some(checks) = &plan.field_errors {
            field_errors_function(writer, checks, "value");
        }
        if let Some(checks) = &plan.is_present {
            is_present_function(writer, checks);
        }
        for child in &plan.nested {
            writer.blank();
            value(writer, child);
        }
    });
}

/// The initializer that takes every property, for code that builds a
/// value without a record. A parameter is labeled by its property and
/// named like it, but for `self`, whose local would hide the instance.
fn memberwise_initializer(writer: &mut Writer, properties: &[Property]) {
    if properties.is_empty() {
        writer.line("public init() {}");
        return;
    }
    let fields: Vec<&str> = properties
        .iter()
        .map(|property| property.field.as_str())
        .collect();
    let locals: Vec<String> = properties
        .iter()
        .map(|property| local_name(&property.field, &fields))
        .collect();
    let parameters: Vec<String> = properties
        .iter()
        .zip(&locals)
        .map(|(property, local)| {
            if *local == property.name {
                format!("{}: {}", property.name, property.swift_type)
            } else {
                format!("{} {local}: {}", property.name, property.swift_type)
            }
        })
        .collect();
    writer.block(
        format!("public init({})", parameters.join(", ")),
        |writer| {
            for (property, local) in properties.iter().zip(&locals) {
                writer.line(format!("self.{} = {local}", property.name));
            }
        },
    );
}

/// The initializer generated code calls: every property read out of the
/// record, once, as the lens's accessor would read it.
fn reading_initializer(writer: &mut Writer, properties: &[Property]) {
    writer.doc("Reads the fragment's fields out of the record, once, at the call.");
    let head = format!(
        "@_spi(Generated) @MainActor public init(anchor: {})",
        SwiftType::runtime("Anchor")
    );
    writer.block(head, |writer| {
        for property in properties {
            match &property.read {
                Assignment::Expression(expression) => {
                    writer.line(format!("self.{} = {expression}", property.name));
                }
                Assignment::Closure(statements) => {
                    // The closure states its type, which its returns are
                    // read against.
                    writer.closed_block(
                        format!(
                            "self.{} = {{ () -> {} in",
                            property.name, property.swift_type
                        ),
                        "}()",
                        |writer| {
                            for statement in statements {
                                writer.line(statement);
                            }
                        },
                    );
                }
            }
        }
    });
}

/// A property from an accessor: the accessor's read, optional and nil
/// without a read when the member's conditions fail, as the accessor is.
fn property(accessor: &Accessor) -> Property {
    let condition = guard_condition(&accessor.guards);
    let name = escape(&accessor.name);
    let (piece, condition) = match &accessor.read {
        Read::Scalar(read) => (scalar_piece(read), condition),
        Read::Linked(read) => (linked_piece(read, true), condition),
        Read::Aliased(read) => aliased_piece(read),
        Read::Condition(read) => {
            let (piece, test) = condition_piece(read, condition.as_deref());
            (piece, Some(test))
        }
        Read::Spread(read) => {
            let piece = spread_piece(read);
            debug_assert!(!piece.throws, "a value's spread reads without throwing");
            return Property {
                name,
                field: accessor.name.clone(),
                swift_type: piece.swift_type,
                read: match piece.expression {
                    Some(expression) => Assignment::Expression(expression),
                    None => Assignment::Closure(piece.statements),
                },
            };
        }
    };
    let Piece {
        swift_type,
        expression,
        throws,
    } = piece;
    debug_assert!(!throws, "a value's property reads without throwing");
    match condition {
        Some(condition) => Property {
            name,
            field: accessor.name.clone(),
            swift_type: swift_type.optional(),
            read: Assignment::Expression(format!("{condition} ? {expression} : nil")),
        },
        None => Property {
            name,
            field: accessor.name.clone(),
            swift_type,
            read: Assignment::Expression(expression),
        },
    }
}
