//! The operation half of the decide pass: an operation value's variables and
//! the names it declares, and a mutation's optimistic-response builders.

use std::collections::BTreeSet;

use super::reader::{ReaderPlan, Readers, scalar_reader};
use super::{NormalizationField, NormalizationKind, NormalizationSelection};
use crate::names::{Kind, NameError, Reserved, Scope, Written, escape};
use crate::pipeline::{OperationKind, OperationPlan, TypeKind, VariablePlan};

/// An operation's value type: its variables, its static data, its plan, its
/// root lens and, for a mutation, its optimistic-response builder.
#[derive(Debug, Clone, PartialEq)]
pub struct OperationValue {
    pub name: String,
    /// The file the operation was declared in.
    pub source: String,
    pub kind: OperationKind,
    pub variables: Vec<VariableValue>,
    pub id: String,
    pub text: String,
    /// `Baton.ErrorBehavior`'s case.
    pub error_behavior: Option<String>,
    pub throws_on_field_error: bool,
    pub bubbles: bool,
    pub has_deferred: bool,
    pub normalization: NormalizationSelection,
    pub data: ReaderPlan,
    pub optimistic: Option<BuilderPlan>,
}

/// A variable as the value's stored property and initializer parameter.
#[derive(Debug, Clone, PartialEq)]
pub struct VariableValue {
    /// The GraphQL name, which the property and the request share.
    pub name: String,
    pub swift_type: String,
    /// A nullable variable's parameter defaults to nil.
    pub non_null: bool,
    /// The name its value goes by as a parameter.
    pub local: String,
}

/// A builder of a partial response: one struct per selection set, every
/// field optional, rendering to JSON.
#[derive(Debug, Clone, PartialEq)]
pub struct BuilderPlan {
    pub name: String,
    pub fields: Vec<BuilderField>,
    pub nested: Vec<BuilderPlan>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct BuilderField {
    /// The response key: the property's name and the JSON's.
    pub key: String,
    /// The name its value goes by as a parameter or a local.
    pub local: String,
    pub value: BuilderValue,
}

#[derive(Debug, Clone, PartialEq)]
pub enum BuilderValue {
    Scalar { swift_type: String },
    Object { builder: String, plural: bool },
}

/// An operation's value, its root lens decided by `readers`; the names it
/// would declare twice go to `duplicates`.
pub(super) fn operation(
    operation: &OperationPlan,
    readers: &mut Readers,
    builder_names: &Reserved,
    duplicates: &mut Vec<NameError>,
) -> OperationValue {
    let resolves = operation.kind != OperationKind::Mutation;
    duplicates.extend(operation_scope(operation, resolves));
    let names: Vec<&str> = operation
        .variables
        .iter()
        .map(|variable| variable.name.as_str())
        .collect();
    let variables = operation
        .variables
        .iter()
        .map(|variable| VariableValue {
            name: variable.name.clone(),
            swift_type: variable_type(variable),
            non_null: variable.non_null,
            local: local_name(&variable.name, &names),
        })
        .collect();
    let normalization = super::normalization(&operation.root_type, &operation.normalization);
    let data = readers.operation(operation);
    let optimistic = (operation.kind == OperationKind::Mutation).then(|| {
        let path = format!("{}.OptimisticResponse", operation.name);
        builder(
            &path,
            "OptimisticResponse",
            &normalization,
            builder_names,
            duplicates,
        )
    });
    OperationValue {
        name: operation.name.clone(),
        source: operation.source.clone(),
        kind: operation.kind,
        variables,
        id: operation.id.clone(),
        text: operation.text.clone(),
        error_behavior: operation.error_behavior.clone(),
        throws_on_field_error: operation.throws_on_field_error,
        bubbles: operation.bubbles,
        has_deferred: operation.has_deferred,
        normalization,
        data,
        optimistic,
    }
}

/// The names an operation's value would declare twice: its variables beside
/// what every operation value has.
fn operation_scope(operation: &OperationPlan, resolves: bool) -> Vec<NameError> {
    let none = Reserved::none();
    let mut scope = Scope::new(operation.name.as_str(), &none);
    for variable in &operation.variables {
        scope.declare_written(
            &variable.name,
            Kind::Instance,
            format!("the variable `${}`", variable.name),
            variable.origin.clone().map(|origin| Written {
                origin,
                remedy: "rename the variable",
            }),
        );
    }
    scope.declare("variables", Kind::Instance, "the operation's `variables`");
    if resolves {
        scope.declare("resolution", Kind::Instance, "the operation's `resolution`");
    }
    for name in ["name", "persistedID", "text", "plan"] {
        scope.declare(name, Kind::Static, format!("the operation's `{name}`"));
    }
    let flags = [
        ("errorBehavior", operation.error_behavior.is_some()),
        ("throwsOnFieldError", operation.throws_on_field_error),
        ("bubbles", operation.bubbles),
        ("hasDeferred", operation.has_deferred),
    ];
    for (name, declared) in flags {
        if declared {
            scope.declare(name, Kind::Static, format!("the operation's `{name}`"));
        }
    }
    scope.declare("Data", Kind::Type, "the operation's root lens `Data`");
    if operation.kind == OperationKind::Mutation {
        scope.declare("Action", Kind::Type, "the mutation's `Action`");
        scope.declare(
            "OptimisticResponse",
            Kind::Type,
            "the mutation's `OptimisticResponse`",
        );
    }
    scope.finish()
}

/// The builder named `name` for `selection`, and those nested in it.
fn builder(
    path: &str,
    name: &str,
    selection: &NormalizationSelection,
    builder_names: &Reserved,
    duplicates: &mut Vec<NameError>,
) -> BuilderPlan {
    // Every field any variant reads, once: the response is written for
    // whichever type it names.
    let mut seen = BTreeSet::new();
    let fields: Vec<&NormalizationField> = selection
        .variants
        .iter()
        .flat_map(|variant| &variant.fields)
        .filter(|field| seen.insert(field.response_key.clone()))
        .collect();
    let mut scope = Scope::new(path, builder_names);
    scope.declare(
        "variable",
        Kind::Instance,
        "the optimistic response's `variable`",
    );
    for field in &fields {
        scope.declare_written(
            &field.response_key,
            Kind::Instance,
            format!("the field `{}`", field.response_key),
            field.written.clone(),
        );
    }
    let keys: Vec<&str> = fields
        .iter()
        .map(|field| field.response_key.as_str())
        .collect();
    let mut nested: Vec<(String, &NormalizationSelection)> = Vec::new();
    let mut builder_fields = Vec::new();
    for field in &fields {
        let key = field.response_key.clone();
        let value = match &field.kind {
            NormalizationKind::Scalar { base_kind, list } => BuilderValue::Scalar {
                swift_type: scalar_reader(*base_kind, *list).1,
            },
            NormalizationKind::Linked {
                plural,
                selection: child,
                ..
            } => {
                let builder = scope.nested_type(&key, format!("the builder of `{key}`"));
                nested.push((builder.clone(), child));
                BuilderValue::Object {
                    builder,
                    plural: *plural,
                }
            }
        };
        builder_fields.push(BuilderField {
            local: local_name(&key, &keys),
            key,
            value,
        });
    }
    duplicates.extend(scope.finish());
    let nested = nested
        .into_iter()
        .map(|(name, child)| {
            builder(
                &format!("{path}.{name}"),
                &name,
                child,
                builder_names,
                duplicates,
            )
        })
        .collect();
    BuilderPlan {
        name: name.to_string(),
        fields: builder_fields,
        nested,
    }
}

/// The name a property's value goes by as a parameter or a local: the
/// property's own, escaped, except for `self`, which as a parameter or a
/// local would hide the instance. It goes by `selfValue`, numbered past the
/// names in `taken`.
fn local_name(property: &str, taken: &[&str]) -> String {
    if property != "self" {
        return escape(property);
    }
    let mut name = "selfValue".to_string();
    let mut number = 2;
    while taken.contains(&name.as_str()) {
        name = format!("selfValue{number}");
        number += 1;
    }
    name
}

/// A variable's Swift type: the scalars as the accessors read them, an
/// input object as a `Baton.Variable`.
fn variable_type(variable: &VariablePlan) -> String {
    let base = match variable.base_kind {
        TypeKind::Int => "Int",
        TypeKind::Float => "Double",
        TypeKind::Boolean => "Bool",
        TypeKind::String | TypeKind::Id | TypeKind::Enum | TypeKind::CustomScalar => "String",
        _ => "Baton.Variable",
    };
    let shape = if variable.list {
        format!("[{base}]")
    } else {
        base.to_string()
    };
    if variable.non_null {
        shape
    } else {
        format!("{shape}?")
    }
}
