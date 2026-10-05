//! Operation values: the variables, the static data, the plan, the root lens
//! and, for a mutation, the action and its optimistic builder.
//!
//! An operation value names the runtime's module in expressions too, which
//! is safe here alone: the decide pass refuses a variable named like the
//! module or like a shared enum the value spells.

use super::builder::builder;
use super::lens::lens;
use super::plan::selection_plan;
use super::swift::{
    SwiftType, member, parameter, raw_multiline_literal, runtime_value, swift_literal,
};
use super::writer::Writer;
use crate::decide::{OperationValue, VariableValue};
use crate::names::call_label;
use crate::pipeline::OperationKind;

pub(super) fn operation_text(operation: &OperationValue) -> String {
    let mut writer = Writer::new();
    writer.doc(format!(
        "Operation value for `{} {}`.",
        operation.kind, operation.name
    ));
    // Each kind is its own protocol: a query and a subscription value
    // carry the handle a view resolves them to, a mutation's is called.
    let (protocol, resolution) = match operation.kind {
        OperationKind::Mutation => ("Mutation", None),
        OperationKind::Subscription => ("Subscription", Some("SubscriptionHandle")),
        OperationKind::Query => ("Query", Some("OperationHandle")),
    };
    let head = format!(
        "nonisolated public struct {}: {}",
        operation.name,
        SwiftType::runtime(protocol)
    );
    writer.block(head, |writer| value_members(writer, operation, resolution));
    writer.blank();

    if operation.kind == OperationKind::Mutation {
        action(&mut writer, operation);
    }
    writer.finish()
}

/// What an operation value declares: its variables, its static data, its
/// plan, its root lens and a mutation's builder.
fn value_members(writer: &mut Writer, operation: &OperationValue, resolution: Option<&str>) {
    for variable in &operation.variables {
        writer.line(format!(
            "public var {}: {}",
            member(&variable.name),
            variable.swift_type
        ));
    }
    if let Some(handle) = resolution {
        writer.line(format!(
            "public var resolution: {}<Self>? = nil",
            SwiftType::runtime(handle)
        ));
    }
    writer.blank();
    writer.block(
        format!("public init({})", parameter_list(&operation.variables)),
        |writer| {
            for variable in &operation.variables {
                writer.line(format!(
                    "self.{} = {}",
                    member(&variable.name),
                    variable.local
                ));
            }
        },
    );
    writer.blank();
    writer.line(format!(
        "public static let name = {}",
        swift_literal(&operation.name)
    ));
    writer.line(format!(
        "public static let persistedID = {}",
        swift_literal(&operation.id)
    ));
    if let Some(behavior) = &operation.error_behavior {
        writer.line(format!(
            "@_spi(Generated) public static let errorBehavior: {} = .{behavior}",
            SwiftType::runtime("ErrorBehavior").optional()
        ));
    }
    let flags = [
        ("throwsOnFieldError", operation.throws_on_field_error),
        ("bubbles", operation.bubbles),
        ("hasDeferred", operation.has_deferred),
    ];
    for (flag, set) in flags {
        if set {
            writer.line(format!("@_spi(Generated) public static let {flag} = true"));
        }
    }
    writer.line(format!(
        "public static let text = {}",
        raw_multiline_literal(&operation.text)
    ));
    writer.blank();
    let variables = SwiftType::runtime("Variables");
    writer.block(format!("public var variables: {variables}"), |writer| {
        let entries: Vec<String> = operation
            .variables
            .iter()
            .map(|variable| {
                format!(
                    "{}: {}({})",
                    swift_literal(&variable.name),
                    runtime_value("Variable"),
                    stored(&variable.name)
                )
            })
            .collect();
        let entries = if entries.is_empty() {
            ":".to_string()
        } else {
            entries.join(", ")
        };
        writer.line(format!("{}([{entries}])", runtime_value("Variables")));
    });
    writer.blank();
    writer.block(
        "public static func == (lhs: Self, rhs: Self) -> Bool",
        |writer| {
            if operation.variables.is_empty() {
                writer.line("true");
            } else {
                let comparisons: Vec<String> = operation
                    .variables
                    .iter()
                    .map(|variable| format!("lhs.{0} == rhs.{0}", member(&variable.name)))
                    .collect();
                writer.line(comparisons.join(" && "));
            }
        },
    );
    writer.blank();
    writer.block("public func hash(into hasher: inout Hasher)", |writer| {
        for variable in &operation.variables {
            writer.line(format!("hasher.combine({})", stored(&variable.name)));
        }
    });
    writer.blank();

    // The normalization plan, as static data. The plan's printer lays its
    // expression out over the lines below this one.
    writer.line(format!(
        "@_spi(Generated) public static let plan = {}(root: {})",
        runtime_value("Plan"),
        selection_plan(&operation.normalization, writer.depth() + 1)
    ));
    writer.blank();

    // The root lens.
    lens(writer, &operation.data);

    if let Some(optimistic) = &operation.optimistic {
        writer.blank();
        writer.line(format!(
            "public typealias Action = {}<Self>",
            SwiftType::runtime("MutationAction")
        ));
        writer.blank();
        builder(writer, optimistic);
    }
}

/// A mutation's action as a function: one labelled parameter per variable
/// and the optimistic response.
fn action(writer: &mut Writer, operation: &OperationValue) {
    let name = &operation.name;
    let parameters = parameter_list(&operation.variables);
    let separator = if operation.variables.is_empty() {
        ""
    } else {
        ", "
    };
    let arguments: Vec<String> = operation
        .variables
        .iter()
        .map(|variable| format!("{}: {}", call_label(&variable.name), variable.local))
        .collect();
    let head = format!(
        "extension {} where Op == {name}",
        SwiftType::runtime("MutationAction")
    );
    writer.block(head, |writer| {
        writer.doc(
            "Commits the mutation; the optimistic response, if any, shows at once and rebases until the server answers.",
        );
        writer.line("@MainActor @discardableResult");
        let function = format!(
            "public func callAsFunction({parameters}{separator}optimistic: {name}.OptimisticResponse? = nil) async throws -> {name}.Data"
        );
        // The action calls its `commit` through `self`, as a parameter for
        // a variable named `$commit` would take its place.
        writer.block(function, |writer| {
            writer.line(format!(
                "try await self.commit({name}({}), optimistic: optimistic?.variable)",
                arguments.join(", ")
            ));
        });
    });
    writer.blank();
}

fn parameter_list(variables: &[VariableValue]) -> String {
    variables
        .iter()
        .map(|variable| {
            let default = if variable.non_null { "" } else { " = nil" };
            format!(
                "{}: {}{}",
                parameter(&variable.name, &variable.local),
                variable.swift_type,
                default
            )
        })
        .collect::<Vec<_>>()
        .join(", ")
}

/// A stored property read inside the value's own methods, through `self`,
/// so neither a parameter such as `hash(into:)`'s `hasher` nor the instance
/// itself, for a property named `self`, takes its place.
fn stored(property: &str) -> String {
    format!("self.{}", member(property))
}
