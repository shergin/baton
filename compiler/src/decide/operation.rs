//! The operation half of the decide pass: an operation value's variables and
//! the names it declares, and its response builders: a mutation's optimistic
//! response, and the raw response a query or a subscription asks for.

use std::collections::{BTreeMap, BTreeSet};

use super::lens::{ListShape, Primitive, ReaderPlan, ScalarShape};
use super::reader::Readers;
use super::{NormalizationField, NormalizationKind, NormalizationSelection};
use crate::config::OnError;
use crate::naming::{
    Kind, LanguageNaming, NameError, Naming, Reserved, Scope, Spelled, Written, numbered,
};
use crate::pipeline::{
    ConstantPlan, DeletePlan, FragmentPlan, OperationKind, OperationPlan, TypeKind, VariablePlan,
};

/// An operation's value type: its variables, its static data, its plan, its
/// root lens and its response builder, a mutation's `OptimisticResponse`
/// or the `RawResponse` of a query or a subscription that asks for one.
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
    /// `@deletes(type:id:)`, the records a mutation deletes, each by its
    /// type and the variable its key is passed as.
    pub deletes: Vec<DeletePlan>,
    pub throws_on_field_error: bool,
    pub bubbles: bool,
    pub has_incremental: bool,
    /// A query of client fields alone, never sent.
    pub client_only: bool,
    pub normalization: NormalizationSelection,
    pub data: ReaderPlan,
    pub response: Option<BuilderPlan>,
}

/// A variable as the value's stored property and initializer parameter.
#[derive(Debug, Clone, PartialEq)]
pub struct VariableValue {
    /// The GraphQL name, which the property and the request share.
    pub name: String,
    pub shape: VariableShape,
    /// A nullable variable's parameter defaults to nil.
    pub non_null: bool,
    /// The default the document declares, sent when a nullable variable is
    /// left unset; a nullable variable without one is then left out of the
    /// request, as GraphQL distinguishes absent from null.
    pub default_value: Option<ConstantPlan>,
    /// The name its value goes by as a parameter.
    pub local: String,
}

/// What a response builder is for. A mutation's is its guess of the answer,
/// shown until the server's arrives; a raw response, Relay's word, is the
/// response itself written by hand, for the door or for a transport of the
/// app's own. The two are one builder: a payload in a response's shape.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ResponseKind {
    Optimistic,
    Raw,
}

impl ResponseKind {
    /// The builder an operation's value nests: a mutation's always, a
    /// query's or a subscription's under `@raw_response_type`, which on a
    /// mutation asks for what it already has.
    fn of(operation: &OperationPlan) -> Option<ResponseKind> {
        match operation.kind {
            OperationKind::Mutation => Some(ResponseKind::Optimistic),
            OperationKind::Query | OperationKind::Subscription => {
                operation.raw_response.then_some(ResponseKind::Raw)
            }
        }
    }

    fn spelled(self) -> Spelled {
        match self {
            ResponseKind::Optimistic => Spelled::OptimisticResponse,
            ResponseKind::Raw => Spelled::RawResponse,
        }
    }

    /// What a message calls the response.
    fn what(self) -> &'static str {
        match self {
            ResponseKind::Optimistic => "the optimistic response",
            ResponseKind::Raw => "the raw response",
        }
    }
}

/// A builder of a partial response: one struct per selection set, every
/// field optional, rendering to JSON.
#[derive(Debug, Clone, PartialEq)]
pub struct BuilderPlan {
    pub kind: ResponseKind,
    pub name: String,
    pub fields: Vec<BuilderField>,
    /// The local `variable` collects the fields in, named past the locals
    /// they bind their values to.
    pub collected: String,
    pub nested: Vec<BuilderPlan>,
    /// Whether the builder is the response's own, which renders a payload:
    /// a nested builder renders the value its parent collects.
    pub payload: bool,
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
    fragments: &BTreeMap<&str, &FragmentPlan>,
    readers: &mut Readers<'_>,
    builder_names: &Reserved,
    duplicates: &mut Vec<NameError>,
) -> OperationValue {
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
            default_value: variable.default_value.clone(),
            local: readers.naming.local(&variable.name, &names),
        })
        .collect();
    let normalization = super::normalization(&operation.root_type, &operation.normalization);
    let data = readers.operation(operation);
    let naming = readers.naming;
    duplicates.extend(operation_scope(operation, &data, &normalization, naming));
    duplicates.extend(nested_types(operation, &data, fragments, naming));
    let response = ResponseKind::of(operation).map(|kind| {
        let name = naming.spelling(kind.spelled());
        let path = format!("{}.{name}", operation.name);
        builder(
            kind,
            &path,
            name,
            &normalization,
            builder_names,
            readers.naming,
            duplicates,
            true,
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
        deletes: operation.deletes.clone(),
        throws_on_field_error: operation.throws_on_field_error,
        bubbles: operation.bubbles,
        has_incremental: operation.has_incremental,
        client_only: operation.client_only,
        normalization,
        data,
        response,
    }
}

/// The names an operation's value would declare twice: its variables beside
/// what `naming` says every value of its kind declares, which a variable
/// would take the place of, and beside the names its code spells, which a
/// variable would hide; `spelled` among them are the shared enums its plan
/// and its root lens read through or test conditions by.
fn operation_scope(
    operation: &OperationPlan,
    data: &ReaderPlan,
    normalization: &NormalizationSelection,
    naming: &LanguageNaming,
) -> Vec<NameError> {
    let none = Reserved::none(naming);
    let mut scope = Scope::new(operation.name.as_str(), &none);
    let mut spelled = data.hideable_names();
    spelled.extend([Spelled::Types, Spelled::Slots]);
    if normalization.has_guards() {
        spelled.insert(Spelled::Guards);
    }
    let names = naming.value_names(operation, &spelled);
    for declared in names.before {
        scope.declare_chosen(declared);
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
    for declared in names.after {
        scope.declare_chosen(declared);
    }
    scope.finish()
}

/// The clashes of the fragments an operation's lenses spread with the types
/// its value nests. Inside the value `Data`, a mutation's `Action` and
/// `OptimisticResponse`, and a `RawResponse`, name its own types, so a
/// spread's accessor would read a fragment of one of those names as that
/// type; no spelling inside the value reaches the fragment.
fn nested_types(
    operation: &OperationPlan,
    data: &ReaderPlan,
    fragments: &BTreeMap<&str, &FragmentPlan>,
    naming: &LanguageNaming,
) -> Vec<NameError> {
    let none = Reserved::none(naming);
    let mut scope = Scope::new(operation.name.as_str(), &none);
    for spelled in naming.value_types(operation) {
        scope.declare_spelled(naming, spelled);
    }
    for name in data.spread_fragments() {
        let origin = fragments
            .get(name)
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

/// The builder named `name` for `selection`, and those nested in it;
/// `payload` for the response's own, which renders a payload.
#[allow(clippy::too_many_arguments)]
fn builder(
    kind: ResponseKind,
    path: &str,
    name: &str,
    selection: &NormalizationSelection,
    builder_names: &Reserved,
    naming: &LanguageNaming,
    duplicates: &mut Vec<NameError>,
    payload: bool,
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
        format!("{}'s `variable`", kind.what()),
    );
    if payload {
        scope.declare(
            "payload",
            Kind::Instance,
            format!("{}'s `payload`", kind.what()),
        );
    }
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
                kind,
                &format!("{path}.{name}"),
                &name,
                child,
                builder_names,
                naming,
                duplicates,
                false,
            )
        })
        .collect();
    let locals: Vec<&str> = builder_fields
        .iter()
        .map(|field| field.local.as_str())
        .collect();
    BuilderPlan {
        kind,
        name: name.to_string(),
        collected: numbered("fields", &locals),
        fields: builder_fields,
        nested,
        payload,
    }
}

/// A variable's shape: the scalars as the accessors read them, anything
/// else as the request carries it.
fn variable_shape(variable: &VariablePlan, naming: &LanguageNaming) -> VariableShape {
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
