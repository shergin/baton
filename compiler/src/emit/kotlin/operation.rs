//! Operation values in Kotlin: a class of the variables, equal by them,
//! whose companion holds what the build knows about the operation, its plan
//! among it, and whose `Data` is the root lens.

use super::super::writer::Writer;
use super::literal::{
    Base, Converters, ValueShape, jvm_getters, property_read, string_literal, variable_literal,
};
use super::plan::PlanSelections;
use crate::config::OnError;
use crate::decide::{OperationValue, Shared, VariableBase, VariableValue};
use crate::kotlin_names::escape;
use crate::pipeline::OperationKind;

/// The operation's class.
pub(super) fn operation_text(
    operation: &OperationValue,
    shared: &Shared,
    converters: &Converters,
) -> String {
    let mut writer = Writer::new();
    let class = escape(&operation.name);
    writer.line(format!(
        "/** Operation value for `{} {}`. */",
        operation.kind, operation.name
    ));
    // Each kind is its own interface: a query's and a subscription's value
    // carry the handle a composable resolves them to, a mutation's is
    // committed.
    let (interface, handle) = match operation.kind {
        OperationKind::Query => ("QueryOperation", Some("OperationHandle")),
        OperationKind::Mutation => ("MutationOperation", None),
        OperationKind::Subscription => ("SubscriptionOperation", Some("SubscriptionHandle")),
    };
    let names: Vec<&str> = operation
        .variables
        .iter()
        .map(|variable| variable.name.as_str())
        .collect();
    let getters = jvm_getters(&names, &["getVariables", "getType", "getResolution"]);
    let parameters: Vec<String> = operation
        .variables
        .iter()
        .zip(getters)
        .map(|(variable, getter)| {
            let default = if variable.non_null { "" } else { " = null" };
            let annotation = getter
                .map(|getter| format!("@get:JvmName({}) ", string_literal(&getter)))
                .unwrap_or_default();
            format!(
                "{annotation}val {}: {}{default}",
                variable.local,
                converters.value_type(&shape(variable))
            )
        })
        .collect();
    let parameters = if parameters.is_empty() {
        String::new()
    } else {
        format!("({})", parameters.join(", "))
    };
    let head = format!("class {class}{parameters} : {interface}<{class}.Data>");
    writer.block(head, |writer| {
        variables(writer, operation, &class, converters);
        if let Some(handle) = handle {
            writer.line(format!(
                "override var resolution: Resolution<{handle}<Data>> = Resolution.Unresolved"
            ));
        }
        writer.line("override val type: OperationType<Data> get() = Companion");
        writer.blank();
        equality(writer, operation, &class);
        writer.blank();
        companion(writer, operation, shared);
        writer.blank();
        writer.line("class Data(override val anchor: Anchor) : Lens");
    });
    writer.finish()
}

/// What a variable holds.
fn shape(variable: &VariableValue) -> ValueShape<'_> {
    let base = match &variable.shape.base {
        VariableBase::Scalar(primitive) => Base::Scalar(primitive),
        VariableBase::Input(name) => Base::Input(name),
    };
    ValueShape {
        base,
        list: variable.shape.list,
        non_null: variable.non_null,
    }
}

/// The `variables` a value is run with: a variable the caller must give, or
/// one with a declared default, always, the default sent when the value is
/// null; any other only when it is set, so the request leaves it absent.
fn variables(
    writer: &mut Writer,
    operation: &OperationValue,
    class: &str,
    converters: &Converters,
) {
    writer.line("override val variables: Variables");
    if operation.variables.is_empty() {
        writer.line("    get() = Variables.none");
        return;
    }
    writer.closed_block("    get() = Variables(buildMap {", "    })", |writer| {
        for variable in &operation.variables {
            let shape = shape(variable);
            let read = property_read(class, &variable.local);
            let key = string_literal(&variable.name);
            let value = converters.value_expression(&read, &shape);
            let line = match (variable.non_null, &variable.default_value) {
                (true, _) => format!("put({key}, {value})"),
                (false, Some(default)) => format!(
                    "put({key}, if ({read} == null) {} else {value})",
                    variable_literal(default)
                ),
                (false, None) => format!("if ({read} != null) put({key}, {value})"),
            };
            writer.line(format!("    {line}"));
        }
    });
}

/// `equals` and `hashCode`, by the variables alone: two values run with
/// the same variables are one operation, wherever they stand.
fn equality(writer: &mut Writer, operation: &OperationValue, class: &str) {
    // The parameter of `equals` hides a variable named `other`, which the
    // comparison then reads through `this`.
    let own = |variable: &VariableValue| {
        if variable.local == "other" {
            "this.other".to_string()
        } else {
            variable.local.clone()
        }
    };
    let comparisons: Vec<String> = std::iter::once(format!("other is {class}"))
        .chain(
            operation
                .variables
                .iter()
                .map(|variable| format!("other.{} == {}", variable.local, own(variable))),
        )
        .collect();
    writer.line(format!(
        "override fun equals(other: Any?): Boolean = {}",
        comparisons.join(" && ")
    ));
    if operation.variables.is_empty() {
        writer.line("override fun hashCode(): Int = 0");
        return;
    }
    let values: Vec<&str> = operation
        .variables
        .iter()
        .map(|variable| variable.local.as_str())
        .collect();
    writer.line(format!(
        "override fun hashCode(): Int = listOf({}).hashCode()",
        values.join(", ")
    ));
}

/// The `onError` value's case of `ErrorBehavior`.
fn error_behavior_case(behavior: OnError) -> &'static str {
    match behavior {
        OnError::Propagate => "PROPAGATE",
        OnError::Null => "NULL",
        OnError::Abort => "ABORT",
    }
}

/// The companion: the operation's name, document, kind and the flags its
/// directives set, its plan and each selection of it, and the root lens.
fn companion(writer: &mut Writer, operation: &OperationValue, shared: &Shared) {
    let kind = match operation.kind {
        OperationKind::Query => "QUERY",
        OperationKind::Mutation => "MUTATION",
        OperationKind::Subscription => "SUBSCRIPTION",
    };
    writer.block("companion object : OperationType<Data>", |writer| {
        writer.line(format!(
            "override val name = {}",
            string_literal(&operation.name)
        ));
        // Text or id, never both: the build decided, and the binary holds no
        // text to fall back to under `persistConfig`.
        let document = match &operation.id {
            Some(id) => format!("Document.Id({})", string_literal(id)),
            None => format!("Document.Text({})", string_literal(&operation.text)),
        };
        writer.line(format!("override val document: Document = {document}"));
        writer.line(format!("override val kind = OperationKind.{kind}"));
        if let Some(behavior) = operation.error_behavior {
            writer.line(format!(
                "override val errorBehavior: ErrorBehavior? = ErrorBehavior.{}",
                error_behavior_case(behavior)
            ));
        }
        if let Some(seconds) = operation.cache_expiration {
            writer.line(format!(
                "override val cacheExpirationSeconds: Double? = {seconds:?}"
            ));
        }
        let flags = [
            ("throwsOnFieldError", operation.throws_on_field_error),
            ("bubbles", operation.bubbles),
            ("hasDeferred", operation.has_deferred),
        ];
        for (flag, set) in flags {
            if set {
                writer.line(format!("override val {flag} = true"));
            }
        }
        // A module with transient types or fields has every plan name its
        // rule set, so the registry learns them before any plan writes a row.
        let transient = if shared.transient_types.is_empty() && shared.transient_fields.is_empty() {
            ""
        } else {
            ", transient = Types.transient"
        };
        let selections = PlanSelections::new(&operation.normalization, writer.depth() + 1, shared);
        writer.line(format!(
            "override val plan: Plan by lazy {{ Plan(root = {}{transient}) }}",
            selections.root()
        ));
        for (name, initializer) in selections.declarations() {
            writer.block(format!("private val {name}: Selection by lazy"), |writer| {
                writer.line(initializer);
            });
        }
        writer.blank();
        writer.line("override fun data(anchor: Anchor): Data = Data(anchor)");
    });
}
