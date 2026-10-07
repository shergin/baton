//! Operation values: the variables, the static data, the plan, the root lens
//! and, for a mutation, the action and its optimistic builder.
//!
//! An operation value names the runtime's module in expressions too, which
//! is safe here alone: the decide pass refuses a variable named like the
//! module or like a shared enum the value spells.

use super::builder::builder;
use super::lens::lens;
use super::plan::PlanSelections;
use super::swift::{
    SwiftType, member, parameter, raw_literal, runtime_value, swift_literal, variable_literal,
    variable_type,
};
use super::writer::Writer;
use crate::config::OnError;
use crate::decide::{OperationValue, Shared, VariableValue};
use crate::names::call_label;
use crate::pipeline::OperationKind;

pub(super) fn operation_text(operation: &OperationValue, shared: &Shared) -> String {
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
        SwiftType::named(&operation.name),
        SwiftType::runtime(protocol)
    );
    writer.block(head, |writer| {
        value_members(writer, operation, resolution, shared)
    });
    writer.blank();

    if operation.kind == OperationKind::Mutation {
        action(&mut writer, operation);
    }
    writer.finish()
}

/// The case of `Baton.ErrorBehavior` that names an `onError` value.
fn error_behavior_case(behavior: OnError) -> &'static str {
    match behavior {
        OnError::Propagate => "propagate",
        OnError::Null => "null",
        OnError::Abort => "abort",
    }
}

/// What an operation value declares: its variables, its static data, its
/// plan, its root lens and a mutation's builder.
fn value_members(
    writer: &mut Writer,
    operation: &OperationValue,
    resolution: Option<&str>,
    shared: &Shared,
) {
    for variable in &operation.variables {
        writer.line(format!(
            "public var {}: {}",
            member(&variable.name),
            variable_type(variable)
        ));
    }
    if let Some(handle) = resolution {
        writer.line(format!(
            "@_spi(Generated) public var resolution: {}<{}<Self>> = .unresolved",
            SwiftType::runtime("Resolution"),
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
    // Text or id, never both: the build decided, and the binary holds no
    // text to fall back to under `persistConfig`.
    let document = match &operation.id {
        Some(id) => format!(".id({})", swift_literal(id)),
        None => format!(".text({})", raw_literal(&operation.text)),
    };
    writer.line(format!(
        "public static let document: {} = {document}",
        SwiftType::runtime("Document")
    ));
    if let Some(behavior) = operation.error_behavior {
        writer.line(format!(
            "@_spi(Generated) public static let errorBehavior: {} = .{}",
            SwiftType::runtime("ErrorBehavior").optional(),
            error_behavior_case(behavior)
        ));
    }
    if let Some(seconds) = operation.cache_expiration {
        writer.line(format!(
            "@_spi(Generated) public static let cacheExpiration: Swift.Duration? = .seconds({seconds})"
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
    writer.blank();
    let variables = SwiftType::runtime("Variables");
    writer.block(format!("public var variables: {variables}"), |writer| {
        // A non-null variable always has a value and a nullable one with a
        // default is sent as the default when unset; both go in the literal.
        // A nullable variable without a default is left out when unset, as
        // GraphQL distinguishes absent from null, so it is added only when set.
        let (present, unset): (Vec<&VariableValue>, Vec<&VariableValue>) = operation
            .variables
            .iter()
            .partition(|variable| variable.non_null || variable.default_value.is_some());
        let entries: Vec<String> = present
            .iter()
            .map(|variable| {
                let value = match &variable.default_value {
                    Some(default) if !variable.non_null => format!(
                        "{stored} == nil ? {default} : {variable}({stored})",
                        stored = stored(&variable.name),
                        default = variable_literal(default),
                        variable = runtime_value("Variable"),
                    ),
                    _ => format!("{}({})", runtime_value("Variable"), stored(&variable.name)),
                };
                format!("{}: {value}", swift_literal(&variable.name))
            })
            .collect();
        let entries = if entries.is_empty() {
            ":".to_string()
        } else {
            entries.join(", ")
        };
        if unset.is_empty() {
            writer.line(format!("{}([{entries}])", runtime_value("Variables")));
            return;
        }
        writer.line(format!(
            "var values: [String: {}] = [{entries}]",
            runtime_value("Variable")
        ));
        for variable in unset {
            writer.line(format!(
                "if {stored} != nil {{ values[{name}] = {variable}({stored}) }}",
                stored = stored(&variable.name),
                name = swift_literal(&variable.name),
                variable = runtime_value("Variable"),
            ));
        }
        writer.line(format!("return {}(values)", runtime_value("Variables")));
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

    // The normalization plan, as static data: the root, then each of its
    // selections once, laid out by the plan's printer over the lines below
    // its declaration.
    // A module with transient types or fields has every plan name its rule
    // set, so the registry learns them before any plan writes a row.
    let transient = if shared.transient_types.is_empty() && shared.transient_fields.is_empty() {
        String::new()
    } else {
        ", transient: Types.transient".to_string()
    };
    let selections = PlanSelections::new(&operation.normalization, writer.depth());
    writer.line(format!(
        "@_spi(Generated) public static let plan = {}(root: {}{transient})",
        runtime_value("Plan"),
        selections.root()
    ));
    for (name, initializer) in selections.declarations() {
        writer.line(format!(
            "private static let {name}: {} = {initializer}",
            SwiftType::runtime("Selection")
        ));
    }
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
/// and the optimistic response. It extends the mutation's own `Action`,
/// which names the mutation once, in a type position, where only types are
/// looked up; its body names the mutation as `Op`, the action's type
/// parameter, and builds the value from its context. In an expression, a
/// variable named like the mutation, or the action's own `Op`, `commit`,
/// `callAsFunction` or `optimistic`, would take the name's place.
fn action(writer: &mut Writer, operation: &OperationValue) {
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
        "extension {}",
        SwiftType::named(&operation.name).nested("Action")
    );
    writer.block(head, |writer| {
        writer.doc(
            "Commits the mutation; the optimistic response, if any, shows at once and rebases until the server answers.",
        );
        writer.line("@MainActor @discardableResult");
        let function = format!(
            "public func callAsFunction({parameters}{separator}optimistic: Op.OptimisticResponse? = nil) async throws -> Op.Data"
        );
        // The action calls its `commit` through `self`, as a parameter for
        // a variable named `$commit` would take its place.
        writer.block(function, |writer| {
            writer.line(format!(
                "try await self.commit(.init({}), optimistic: optimistic?.payload)",
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
                variable_type(variable),
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
