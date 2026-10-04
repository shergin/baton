//! Operation values: the variables, the static data, the plan, the root lens
//! and, for a mutation, the action and its optimistic builder.

use std::fmt::Write as _;

use super::builder::builder;
use super::lens::lens;
use super::plan::selection_plan;
use super::swift::{parameter, raw_multiline_literal};
use crate::decide::{OperationValue, VariableValue};
use crate::names::{call_label, escape};
use crate::pipeline::OperationKind;

pub(super) fn operation_text(operation: &OperationValue) -> String {
    let mut output = String::new();
    let _ = writeln!(
        output,
        "/// Operation value for `{} {}`.",
        operation.kind, operation.name
    );
    // Each kind is its own protocol: a query and a subscription value
    // carry the handle a view resolves them to, a mutation's is called.
    let (protocol, resolution) = match operation.kind {
        OperationKind::Mutation => ("Mutation", None),
        OperationKind::Subscription => ("Subscription", Some("SubscriptionHandle")),
        OperationKind::Query => ("Query", Some("OperationHandle")),
    };
    let _ = writeln!(
        output,
        "nonisolated public struct {}: Baton.{protocol} {{",
        operation.name
    );
    for variable in &operation.variables {
        let _ = writeln!(
            output,
            "    public var {}: {}",
            escape(&variable.name),
            variable.swift_type
        );
    }
    match resolution {
        Some(handle) => {
            let _ = writeln!(
                output,
                "    public var resolution: Baton.{handle}<Self>? = nil\n"
            );
        }
        None => output.push('\n'),
    }
    let parameters = parameter_list(&operation.variables);
    let _ = writeln!(output, "    public init({parameters}) {{");
    for variable in &operation.variables {
        let _ = writeln!(
            output,
            "        self.{} = {}",
            escape(&variable.name),
            variable.local
        );
    }
    output.push_str("    }\n\n");
    let _ = writeln!(
        output,
        "    public static let name = \"{}\"",
        operation.name
    );
    let _ = writeln!(
        output,
        "    public static let persistedID = \"{}\"",
        operation.id
    );
    if let Some(behavior) = &operation.error_behavior {
        let _ = writeln!(
            output,
            "    public static let errorBehavior: Baton.ErrorBehavior? = .{behavior}"
        );
    }
    if operation.throws_on_field_error {
        output.push_str("    public static let throwsOnFieldError = true\n");
    }
    if operation.bubbles {
        output.push_str("    public static let bubbles = true\n");
    }
    if operation.has_deferred {
        output.push_str("    public static let hasDeferred = true\n");
    }
    let _ = writeln!(
        output,
        "    public static let text = {}\n",
        raw_multiline_literal(&operation.text)
    );
    output.push_str("    public var variables: Baton.Variables {\n        Baton.Variables([");
    if operation.variables.is_empty() {
        output.push(':');
    } else {
        let entries: Vec<String> = operation
            .variables
            .iter()
            .map(|variable| {
                format!(
                    "\"{}\": Baton.Variable({})",
                    variable.name,
                    stored(&variable.name)
                )
            })
            .collect();
        output.push_str(&entries.join(", "));
    }
    output.push_str("])\n    }\n\n");
    output.push_str("    public static func == (lhs: Self, rhs: Self) -> Bool {\n");
    if operation.variables.is_empty() {
        output.push_str("        true\n");
    } else {
        let comparisons: Vec<String> = operation
            .variables
            .iter()
            .map(|variable| format!("lhs.{0} == rhs.{0}", escape(&variable.name)))
            .collect();
        let _ = writeln!(output, "        {}", comparisons.join(" && "));
    }
    output.push_str("    }\n\n    public func hash(into hasher: inout Hasher) {\n");
    for variable in &operation.variables {
        let _ = writeln!(output, "        hasher.combine({})", stored(&variable.name));
    }
    output.push_str("    }\n\n");

    // The normalization plan, as static data.
    output.push_str("    public static let plan = Baton.Plan(root: ");
    selection_plan(&mut output, &operation.normalization, 2);
    output.push_str(")\n\n");

    // The root lens.
    lens(&mut output, &operation.data, "    ");

    if let Some(optimistic) = &operation.optimistic {
        output.push('\n');
        output.push_str("    public typealias Action = Baton.MutationAction<Self>\n\n");
        builder(&mut output, optimistic, "    ");
    }
    output.push_str("}\n\n");

    if operation.kind == OperationKind::Mutation {
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
        let _ = writeln!(
            output,
            "extension Baton.MutationAction where Op == {name} {{\n    /// Commits the mutation; the optimistic response, if any, shows at once and rebases until the server answers.\n    @MainActor @discardableResult\n    public func callAsFunction({parameters}{separator}optimistic: {name}.OptimisticResponse? = nil) async throws -> {name}.Data {{\n        try await commit({name}({args}), optimistic: optimistic?.variable)\n    }}\n}}\n",
            name = operation.name,
            args = arguments.join(", ")
        );
    }
    output
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

/// A stored property read inside the value's own methods: by its name, or
/// through `self` for `self`, which alone would name the instance.
fn stored(property: &str) -> String {
    if property == "self" {
        "self.`self`".to_string()
    } else {
        escape(property)
    }
}
