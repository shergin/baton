//! The operation half of the decide pass: an operation value's variables and
//! the names it declares, and a mutation's optimistic-response builders.

use std::collections::BTreeSet;

use super::lens::{ListShape, Primitive, ReaderPlan, ScalarShape};
use super::reader::Readers;
use super::{NormalizationField, NormalizationKind, NormalizationSelection};
use crate::config::OnError;
use crate::naming::{Kind, NameError, Naming, Reserved, Scope, Spelled, Written, numbered};
use crate::pipeline::{FragmentPlan, OperationKind, OperationPlan, TypeKind, VariablePlan};

/// An operation's value type: its variables, its static data, its plan, its
/// root lens and, for a mutation, its optimistic-response builder.
#[derive(Debug, Clone, PartialEq)]
pub struct OperationValue {
    pub name: String,
    /// The file the operation was declared in.
    pub source: String,
    pub kind: OperationKind,
    pub variables: Vec<VariableValue>,
    /// The id the operation is sent by, under `persistConfig`.
    pub id: Option<String>,
    pub text: String,
    /// The `onError` value the operation sends.
    pub error_behavior: Option<OnError>,
    /// `@cacheExpiration(seconds:)`, when the query states one.
    pub cache_expiration: Option<f64>,
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
    pub shape: VariableShape,
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
    /// The local `variable` collects the fields in, named past the locals
    /// they bind their values to.
    pub collected: String,
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
    Scalar { shape: ScalarShape },
    Object { builder: String, plural: bool },
}

/// What a variable holds, in no language's terms.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct VariableShape {
    pub base: VariableBase,
    /// A list of the base, when the variable is one.
    pub list: Option<ListShape>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum VariableBase {
    /// A scalar, as the accessors read it.
    Scalar(Primitive),
    /// An input object, read as the type generated for it.
    Input(String),
}

/// An operation's value, its root lens decided by `readers`; the names it
/// would declare twice go to `duplicates`, and so do the program's
/// `fragments` its lenses spread that its own types would hide.
pub(super) fn operation(
    operation: &OperationPlan,
    fragments: &[FragmentPlan],
    readers: &mut Readers<'_>,
    builder_names: &Reserved,
    duplicates: &mut Vec<NameError>,
) -> OperationValue {
    let resolves = operation.kind != OperationKind::Mutation;
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
            shape: variable_shape(variable, readers.naming),
            non_null: variable.type_.non_null(),
            local: readers.naming.local(&variable.name, &names),
        })
        .collect();
    let normalization = super::normalization(&operation.root_type, &operation.normalization);
    let data = readers.operation(operation);
    let naming = readers.naming;
    duplicates.extend(operation_scope(
        operation,
        resolves,
        &data,
        &normalization,
        naming,
    ));
    duplicates.extend(nested_types(operation, &data, fragments, naming));
    let optimistic = (operation.kind == OperationKind::Mutation).then(|| {
        let name = naming.spelling(Spelled::OptimisticResponse);
        let path = format!("{}.{name}", operation.name);
        builder(
            &path,
            name,
            &normalization,
            builder_names,
            readers.naming,
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
        error_behavior: operation.error_behavior,
        cache_expiration: operation.cache_expiration,
        throws_on_field_error: operation.throws_on_field_error,
        bubbles: operation.bubbles,
        has_deferred: operation.has_deferred,
        normalization,
        data,
        optimistic,
    }
}

/// The names an operation's value would declare twice: its variables beside
/// what every operation value has, beside what the runtime's protocols give
/// a value of its kind, which a variable would take the place of, and
/// beside the names its code spells, which a variable would hide: the
/// runtime's module, the shared enums its plan and its root lens read
/// through or test conditions by, the type's own name, Swift's `Self`,
/// where a lens nested in it reaches a static member of its own, and a
/// mutation's action's own parameter.
fn operation_scope(
    operation: &OperationPlan,
    resolves: bool,
    data: &ReaderPlan,
    normalization: &NormalizationSelection,
    naming: &dyn Naming,
) -> Vec<NameError> {
    let none = Reserved::none(naming);
    let mut scope = Scope::new(operation.name.as_str(), &none);
    scope.declare_spelled(naming, Spelled::Runtime);
    let mut spelled = data.hideable_names();
    spelled.extend([Spelled::Types, Spelled::Slots]);
    if normalization.has_guards() {
        spelled.insert(Spelled::Guards);
    }
    for name in spelled {
        scope.declare_spelled(naming, name);
    }
    if operation.kind == OperationKind::Mutation {
        scope.declare(
            "optimistic",
            Kind::Instance,
            "the action's parameter `optimistic`",
        );
    }
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
    // A property the value declares takes the place of one a protocol
    // gives it, or stands beside it: `isStale` would read the variable
    // where a view meant the handle's state, silently when the two have
    // one type, and `hashValue` would make a read of either ambiguous.
    // Swift tells a property from a method by the call, so variables named
    // `refetch` or `retry` compile beside a query's `refetch()` and
    // `retry()`.
    scope.declare(
        "hashValue",
        Kind::Instance,
        "the `hashValue` every operation value has",
    );
    let given: &[&str] = match operation.kind {
        OperationKind::Query => &["phase", "isRefreshing", "isStale"],
        OperationKind::Subscription => &["subscription"],
        OperationKind::Mutation => &[],
    };
    for name in given {
        scope.declare(
            name,
            Kind::Instance,
            format!("the `{name}` every {} value has", operation.kind),
        );
    }
    for name in ["name", "document", "text", "plan"] {
        scope.declare(name, Kind::Static, format!("the operation's `{name}`"));
    }
    let flags = [
        ("errorBehavior", operation.error_behavior.is_some()),
        ("cacheExpiration", operation.cache_expiration.is_some()),
        ("throwsOnFieldError", operation.throws_on_field_error),
        ("bubbles", operation.bubbles),
        ("hasDeferred", operation.has_deferred),
    ];
    for (name, declared) in flags {
        if declared {
            scope.declare(name, Kind::Static, format!("the operation's `{name}`"));
        }
    }
    declare_nested_types(&mut scope, operation.kind, naming);
    scope.finish()
}

/// Declares the types an operation's value nests: `Data`, and a mutation's
/// `Action` and `OptimisticResponse`, as `naming` spells them.
fn declare_nested_types(scope: &mut Scope<'_>, kind: OperationKind, naming: &dyn Naming) {
    scope.declare_spelled(naming, Spelled::Data);
    if kind == OperationKind::Mutation {
        scope.declare_spelled(naming, Spelled::Action);
        scope.declare_spelled(naming, Spelled::OptimisticResponse);
    }
}

/// The clashes of the fragments an operation's lenses spread with the types
/// its value nests. Inside the value `Data`, and a mutation's `Action` and
/// `OptimisticResponse`, name its own types, so a spread's accessor would
/// read a fragment of one of those names as that type; no spelling inside
/// the value reaches the fragment.
fn nested_types(
    operation: &OperationPlan,
    data: &ReaderPlan,
    fragments: &[FragmentPlan],
    naming: &dyn Naming,
) -> Vec<NameError> {
    let none = Reserved::none(naming);
    let mut scope = Scope::new(operation.name.as_str(), &none);
    declare_nested_types(&mut scope, operation.kind, naming);
    for name in data.spread_fragments() {
        let origin = fragments
            .iter()
            .find(|fragment| fragment.name == name)
            .and_then(|fragment| fragment.origin.clone());
        scope.declare_written(
            name,
            Kind::Type,
            format!("the fragment `{name}`"),
            origin.map(|origin| Written {
                origin,
                remedy: "rename the fragment",
            }),
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
    naming: &dyn Naming,
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
            NormalizationKind::Scalar { type_ } => BuilderValue::Scalar {
                shape: ScalarShape::of(type_, naming),
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
            local: naming.local(&key, &keys),
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
                naming,
                duplicates,
            )
        })
        .collect();
    let locals: Vec<&str> = builder_fields
        .iter()
        .map(|field| field.local.as_str())
        .collect();
    BuilderPlan {
        name: name.to_string(),
        collected: numbered("fields", &locals),
        fields: builder_fields,
        nested,
    }
}

/// A variable's shape: the scalars as the accessors read them, anything
/// else as the request carries it.
fn variable_shape(variable: &VariablePlan, naming: &dyn Naming) -> VariableShape {
    let base = match variable.type_.base_kind() {
        TypeKind::Int
        | TypeKind::Float
        | TypeKind::Boolean
        | TypeKind::String
        | TypeKind::Id
        | TypeKind::Enum
        | TypeKind::CustomScalar => {
            VariableBase::Scalar(ScalarShape::primitive(&variable.type_, naming))
        }
        _ => VariableBase::Input(variable.type_.base_name().to_string()),
    };
    VariableShape {
        base,
        list: ListShape::of(&variable.type_),
    }
}
