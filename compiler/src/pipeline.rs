//! The front end: Relay's parser, schema, IR, validations and transforms,
//! driven by Baton and lowered into Baton's plan IR.
//!
//! Everything in this file up to `lower` is Relay's; everything after is ours.
//! The plan IR is the seam: emitters never see Relay types.

use std::collections::BTreeMap;
use std::sync::Arc;
use std::time::{Duration, Instant};

use common::{Diagnostic, DirectiveName, NamedItem, NoopPerfLogger, SourceLocationKey};
use graphql_ir::{
    ConditionValue, Field, FragmentDefinition, FragmentDefinitionNameSet, Program, Selection,
};
use graphql_syntax::OperationKind as SyntaxOperationKind;
use graphql_text_printer::{PrinterOptions, print_full_operation};
use intern::Lookup;
use intern::string_key::Intern;
use relay_config::ProjectConfig;
use relay_transforms::{
    CATCH_DIRECTIVE_NAME, CHILDREN_CAN_BUBBLE_METADATA_KEY, CatchMetadataDirective, CatchTo,
    FragmentAliasMetadata, Programs, RefetchableMetadata, RequiredAction as RelayRequiredAction,
    RequiredMetadataDirective, apply_transforms, disallow_reserved_aliases,
    disallow_typename_on_root, extract_connection_metadata_from_directive,
    extract_handle_field_directives, extract_values_from_handle_field_directive,
    validate_connections, validate_global_variable_names, validate_no_double_underscore_alias,
    validate_no_unselectable_selections, validate_relay_directives, validate_static_args,
    validate_unused_fragment_variables, validate_unused_variables,
};
use schema::{SDLSchema, Schema, Type, TypeReference};

use crate::config::Config;
use crate::documents::Document;

/// Where time went, for the gates in the roadmap.
#[derive(Debug, Default, Clone, serde::Serialize)]
pub struct Timings {
    pub schema: Duration,
    pub parse: Duration,
    pub ir: Duration,
    pub validate: Duration,
    pub transform: Duration,
    pub lower: Duration,
}

impl Timings {
    pub fn total(&self) -> Duration {
        self.schema + self.parse + self.ir + self.validate + self.transform + self.lower
    }
}

/// The plan IR for one compilation: every fragment's reader shape and every
/// operation's reader shape, normalization shape, text and id.
#[derive(Debug, Default, Clone, serde::Serialize)]
pub struct Plan {
    pub fragments: Vec<FragmentPlan>,
    pub operations: Vec<OperationPlan>,
    /// The schema's root types the store knows by another name, such as
    /// `QueryRoot` by `Query`.
    #[serde(skip_serializing_if = "BTreeMap::is_empty")]
    pub root_names: BTreeMap<String, String>,
    /// The MD5 of the schema's text, which an app passes as its image's
    /// version so a new schema starts the image again.
    #[serde(skip)]
    pub schema_digest: String,
}

/// The names the store types its three root records by, whatever the schema
/// calls its root types, as Relay's root record is a `__Root` in any schema.
const ROOT_NAMES: [(SyntaxOperationKind, &str); 3] = [
    (SyntaxOperationKind::Query, "Query"),
    (SyntaxOperationKind::Mutation, "Mutation"),
    (SyntaxOperationKind::Subscription, "Subscription"),
];

#[derive(Debug, Clone, serde::Serialize)]
pub struct FragmentPlan {
    pub name: String,
    /// The file the fragment was declared in.
    pub source: String,
    /// Which of the file's documents declared it, as the scanner numbered
    /// them.
    pub document: usize,
    pub type_condition: String,
    /// Whether the type condition is an interface or union.
    pub type_is_abstract: bool,
    /// The concrete types the type condition admits, sorted.
    pub possible_types: Vec<String>,
    /// `@argumentDefinitions`, with defaults.
    pub arguments: Vec<VariablePlan>,
    /// `@refetchable`: the generated query and how to bind it.
    pub refetch: Option<RefetchPlan>,
    /// `@throwOnFieldError`: a field error anywhere inside throws at the spread.
    pub throws_on_field_error: bool,
    /// Whether a `@required` field of the fragment can null the whole fragment.
    pub bubbles: bool,
    pub reader: Vec<SelectionPlan>,
}

/// How a `@refetchable` fragment is fetched again: the generated query, the
/// variable carrying the owner's id, and the connection it paginates.
#[derive(Debug, Clone, serde::Serialize)]
pub struct RefetchPlan {
    pub operation: String,
    /// The query's variable names: the fragment's arguments and the globals it uses.
    pub variables: Vec<String>,
    /// The variable the owner's id is passed as (`id`), when the query roots at `node`.
    pub identifier: Option<String>,
    pub connection: Option<PaginationPlan>,
}

/// The variables a fragment's one connection paginates by.
#[derive(Debug, Clone, serde::Serialize)]
pub struct PaginationPlan {
    pub path: Vec<String>,
    pub first: Option<String>,
    pub after: Option<String>,
    pub last: Option<String>,
    pub before: Option<String>,
}

#[derive(Debug, Clone, serde::Serialize)]
pub struct OperationPlan {
    pub name: String,
    /// The file the operation was declared in.
    pub source: String,
    /// Which of the file's documents declared it, as the scanner numbered
    /// them; a refetch query is its fragment's.
    pub document: usize,
    pub kind: OperationKind,
    pub root_type: String,
    pub variables: Vec<VariablePlan>,
    pub text: String,
    pub id: String,
    /// `@throwOnFieldError`: an uncaught field error fails the operation.
    pub throws_on_field_error: bool,
    /// Whether a `@required` field at the root can null the whole result.
    pub bubbles: bool,
    /// Whether any part of the response may arrive incrementally.
    pub has_deferred: bool,
    /// The `onError` value `baton.json` names, as `Baton.ErrorBehavior`'s case.
    pub error_behavior: Option<String>,
    pub reader: Vec<SelectionPlan>,
    pub normalization: Vec<SelectionPlan>,
}

/// Relay's three kinds of operation.
#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize)]
#[serde(rename_all = "lowercase")]
pub enum OperationKind {
    Query,
    Mutation,
    Subscription,
}

impl OperationKind {
    /// The keyword GraphQL writes the operation with.
    pub fn keyword(self) -> &'static str {
        match self {
            OperationKind::Query => "query",
            OperationKind::Mutation => "mutation",
            OperationKind::Subscription => "subscription",
        }
    }
}

impl std::fmt::Display for OperationKind {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(self.keyword())
    }
}

#[derive(Debug, Clone, serde::Serialize)]
pub struct VariablePlan {
    pub name: String,
    /// The GraphQL type, e.g. `Int`, `ID!`, `[String!]`.
    pub type_name: String,
    /// The innermost named type.
    pub base_type: String,
    pub base_kind: TypeKind,
    pub non_null: bool,
    pub list: bool,
    pub default_value: Option<ConstantPlan>,
}

/// What kind of named type a field or variable has.
#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize)]
#[serde(rename_all = "snake_case")]
pub enum TypeKind {
    String,
    Id,
    Int,
    Float,
    Boolean,
    CustomScalar,
    Enum,
    Object,
    Interface,
    Union,
    InputObject,
}

/// A GraphQL constant, as a fragment argument or a variable default.
#[derive(Debug, Clone, PartialEq, serde::Serialize)]
#[serde(tag = "kind", content = "value", rename_all = "snake_case")]
pub enum ConstantPlan {
    Null,
    Bool(bool),
    Int(i64),
    Float(f64),
    String(String),
    List(Vec<ConstantPlan>),
    Object(Vec<(String, ConstantPlan)>),
}

/// An argument value: a variable of the enclosing scope, a constant, or a
/// list or object whose items may be either.
#[derive(Debug, Clone, PartialEq, serde::Serialize)]
#[serde(tag = "kind", content = "value", rename_all = "snake_case")]
pub enum ArgumentValuePlan {
    Variable(String),
    Constant(ConstantPlan),
    List(Vec<ArgumentValuePlan>),
    Object(Vec<(String, ArgumentValuePlan)>),
}

#[derive(Debug, Clone, PartialEq, serde::Serialize)]
pub struct ArgumentPlan {
    pub name: String,
    pub value: ArgumentValuePlan,
}

/// Relay's storage key, as a tree: the field name and its arguments, sorted
/// by name. The emitter writes it as the runtime renders one; nothing parses
/// it again.
#[derive(Debug, Clone, PartialEq, serde::Serialize)]
pub struct StorageKeyPlan {
    pub name: String,
    pub arguments: Vec<ArgumentPlan>,
}

/// A root field that returns an entity addressable by one of its arguments,
/// so a cached entity can satisfy the field before it was ever fetched.
#[derive(Debug, Clone, PartialEq, serde::Serialize)]
pub struct LookupPlan {
    /// `None` resolves by id among `possible_types`.
    pub type_name: Option<String>,
    /// The concrete types the field returns, for a lookup without a type.
    pub possible_types: Vec<String>,
    pub argument: String,
    /// The argument's value in the document.
    pub value: ArgumentValuePlan,
}

/// A `@connection` field: the client record pages merge into, and the cursor
/// arguments that decide whether a page replaces, appends or prepends.
#[derive(Debug, Clone, PartialEq, serde::Serialize)]
pub struct ConnectionPlan {
    pub key: String,
    /// Relay's handle key with the filters: `__Key_connection(states:"OPEN")`.
    pub storage_key: StorageKeyPlan,
    pub edge_type: String,
    pub page_info_type: String,
    pub after: Option<ArgumentValuePlan>,
    pub before: Option<ArgumentValuePlan>,
}

/// An edge directive on a mutation payload field, as Relay's handle.
#[derive(Debug, Clone, PartialEq, serde::Serialize)]
pub struct HandlePlan {
    pub kind: HandleKind,
    pub connections: Option<ArgumentValuePlan>,
    pub edge_type_name: Option<String>,
}

/// The edge directives, by the names of Relay's handles, which the
/// runtime's cases share.
#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub enum HandleKind {
    AppendEdge,
    PrependEdge,
    AppendNode,
    PrependNode,
    DeleteEdge,
    DeleteRecord,
}

impl HandleKind {
    /// The kind of Relay's handle `name`; `None` for a handle that is not an
    /// edge directive.
    fn of(name: &str) -> Option<HandleKind> {
        Some(match name {
            "appendEdge" => HandleKind::AppendEdge,
            "prependEdge" => HandleKind::PrependEdge,
            "appendNode" => HandleKind::AppendNode,
            "prependNode" => HandleKind::PrependNode,
            "deleteEdge" => HandleKind::DeleteEdge,
            "deleteRecord" => HandleKind::DeleteRecord,
            _ => return None,
        })
    }

    /// Relay's name for the handle, which the runtime's case shares.
    pub fn name(self) -> &'static str {
        match self {
            HandleKind::AppendEdge => "appendEdge",
            HandleKind::PrependEdge => "prependEdge",
            HandleKind::AppendNode => "appendNode",
            HandleKind::PrependNode => "prependNode",
            HandleKind::DeleteEdge => "deleteEdge",
            HandleKind::DeleteRecord => "deleteRecord",
        }
    }
}

/// `@required(action:)`: the action and Relay's dotted path for messages.
#[derive(Debug, Clone, serde::Serialize)]
pub struct RequiredPlan {
    pub action: RequiredAction,
    pub path: String,
}

/// What a `@required` field does when it is null.
#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize)]
#[serde(rename_all = "UPPERCASE")]
pub enum RequiredAction {
    /// Nulls the enclosing lens.
    None,
    /// Nulls the enclosing lens and reports the path.
    Log,
    /// Throws at the field's read.
    Throw,
}

/// `@catch(to:)`.
#[derive(Debug, Clone, serde::Serialize)]
pub struct CatchPlan {
    pub to: CatchTarget,
}

/// What a `@catch` reads an error as.
#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize)]
#[serde(rename_all = "UPPERCASE")]
pub enum CatchTarget {
    /// A `Result` whose failure holds the errors.
    Result,
    /// Null.
    Null,
}

/// The plan IR is built once per compilation and read by the emitters, so the
/// size difference between a scalar and a linked field is of no account.
#[allow(clippy::large_enum_variant)]
#[derive(Debug, Clone, serde::Serialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum SelectionPlan {
    Scalar {
        name: String,
        alias: Option<String>,
        type_name: String,
        base_type: String,
        base_kind: TypeKind,
        non_null: bool,
        /// `@semanticNonNull` in the schema: null only when an error occurred.
        semantic_non_null: bool,
        list: bool,
        storage_key: StorageKeyPlan,
        handle: Option<HandlePlan>,
        required: Option<RequiredPlan>,
        catch: Option<CatchPlan>,
        /// Whether the field or an ancestor carries `@catch`, so an error on
        /// it does not fail a `@throwOnFieldError` operation.
        caught: bool,
    },
    Linked {
        name: String,
        alias: Option<String>,
        type_name: String,
        base_type: String,
        base_kind: TypeKind,
        non_null: bool,
        semantic_non_null: bool,
        plural: bool,
        /// Whether the target type defines an `id` field (identity by typename and id).
        has_id: bool,
        /// Whether the target type is an interface or union: records are then
        /// keyed and sloted by the payload's `__typename`.
        is_abstract: bool,
        /// The concrete types the target type admits, sorted: itself for an
        /// object type.
        possible_types: Vec<String>,
        storage_key: StorageKeyPlan,
        lookup: Option<LookupPlan>,
        connection: Option<ConnectionPlan>,
        handle: Option<HandlePlan>,
        required: Option<RequiredPlan>,
        catch: Option<CatchPlan>,
        caught: bool,
        /// Whether a `@required` child can null this field.
        bubbles: bool,
        selections: Vec<SelectionPlan>,
    },
    Inline {
        type_condition: Option<String>,
        /// The concrete types the type condition admits, sorted.
        condition_types: Option<Vec<String>>,
        /// How the type condition stands to the parent's possible types.
        condition_class: Option<ConditionClass>,
        /// An explicit `@alias(as:)` name.
        alias: Option<String>,
        /// `@defer`: the label the incremental part carries.
        deferred: Option<String>,
        catch: Option<CatchPlan>,
        bubbles: bool,
        selections: Vec<SelectionPlan>,
    },
    Spread {
        fragment: String,
        type_condition: String,
        /// `@arguments`, bound by the parent lens into the child's scope.
        arguments: Vec<ArgumentPlan>,
    },
    Condition {
        variable: Option<String>,
        passing: bool,
        selections: Vec<SelectionPlan>,
    },
}

/// How an inline fragment's type condition stands to the types its parent
/// admits: every one of them satisfies it, one does, or several do.
#[derive(Debug, Clone, PartialEq, serde::Serialize)]
#[serde(tag = "kind", content = "type", rename_all = "snake_case")]
pub enum ConditionClass {
    /// The fields fold into the parent's lens.
    Always,
    /// A record of this concrete type, and only of it, satisfies it.
    Concrete(String),
    /// Records of several concrete types satisfy it.
    Set,
}

/// Output of a successful compilation.
pub struct Compiled {
    pub plan: Plan,
    pub timings: Timings,
}

/// Compiles a schema and documents to a plan, or returns the front end's
/// diagnostics. Every phase's duration is recorded.
pub fn compile(
    schema_sdl: &str,
    schema_path: &str,
    documents: &[Document],
    config: &Config,
) -> Result<Compiled, Vec<Diagnostic>> {
    let mut timings = Timings::default();

    let started = Instant::now();
    let schema = relay_schema::build_schema_with_extensions_parallel(
        &[(schema_sdl, SourceLocationKey::standalone(schema_path))],
        &[] as &[(&str, SourceLocationKey)],
    )?;
    let schema = Arc::new(schema);
    timings.schema = started.elapsed();
    let errors = validate_lookups(&schema, config);
    if !errors.is_empty() {
        return Err(errors);
    }
    let root_names = root_names(&schema, schema_path)?;

    let started = Instant::now();
    let mut definitions = Vec::new();
    let mut diagnostics = Vec::new();
    for document in documents {
        let key = SourceLocationKey::embedded(&document.path.to_string_lossy(), document.index);
        match graphql_syntax::parse_executable(&document.text, key) {
            Ok(parsed) => {
                let marker = document.embedded.as_ref().map(|embedded| embedded.marker);
                diagnostics.extend(crate::directives::check(&parsed.definitions, key, marker));
                definitions.extend(parsed.definitions);
            }
            Err(errors) => diagnostics.extend(errors),
        }
    }
    timings.parse = started.elapsed();
    if !diagnostics.is_empty() {
        return Err(diagnostics);
    }

    let project_config = ProjectConfig::default();

    let started = Instant::now();
    let ir =
        graphql_ir::build_ir_in_relay_mode(&schema, &definitions, &project_config.feature_flags)?;
    let program = Program::from_definitions(Arc::clone(&schema), ir);
    timings.ir = started.elapsed();

    let started = Instant::now();
    validate(&program, &project_config)?;
    timings.validate = started.elapsed();

    let started = Instant::now();
    let programs = apply_transforms(
        &project_config,
        Arc::new(program),
        Arc::new(FragmentDefinitionNameSet::default()),
        Arc::new(NoopPerfLogger),
        None,
        None,
        Vec::new(),
    )?;
    timings.transform = started.elapsed();

    let started = Instant::now();
    let mut plan = lower(&schema, &programs, config)?;
    plan.root_names = root_names;
    plan.schema_digest = format!("{:x}", md5::compute(schema_sdl.as_bytes()));
    timings.lower = started.elapsed();

    Ok(Compiled { plan, timings })
}

/// A mutation's root fields keyed without their arguments: the payload is
/// read once by the caller, and a key that carried the input would number
/// a new slot for every distinct one. An aliased field keeps its alias in
/// the key, as `addNote(as:"first")`, so two fields never share a slot.
fn key_by_response(selections: &mut [SelectionPlan]) {
    for selection in selections {
        match selection {
            SelectionPlan::Scalar {
                name,
                alias,
                storage_key,
                ..
            }
            | SelectionPlan::Linked {
                name,
                alias,
                storage_key,
                ..
            } => {
                *storage_key = StorageKeyPlan {
                    name: name.clone(),
                    arguments: alias
                        .iter()
                        .map(|alias| ArgumentPlan {
                            name: "as".to_string(),
                            value: ArgumentValuePlan::Constant(ConstantPlan::String(alias.clone())),
                        })
                        .collect(),
                };
            }
            SelectionPlan::Inline { selections, .. }
            | SelectionPlan::Condition { selections, .. } => key_by_response(selections),
            SelectionPlan::Spread { .. } => {}
        }
    }
}

/// The schema's root types whose names differ from the store's. A slot is
/// numbered within its type, so every slot of a root field must belong to
/// the type the store's root record has; another type of the schema that
/// already has that name would share its numbering, and is an error.
fn root_names(
    schema: &SDLSchema,
    schema_path: &str,
) -> Result<BTreeMap<String, String>, Vec<Diagnostic>> {
    let location = common::Location::new(
        SourceLocationKey::standalone(schema_path),
        common::Span::new(0, 0),
    );
    let mut names = BTreeMap::new();
    let mut errors = Vec::new();
    for (kind, store_name) in ROOT_NAMES {
        let root = match kind {
            SyntaxOperationKind::Query => schema.query_type(),
            SyntaxOperationKind::Mutation => schema.mutation_type(),
            SyntaxOperationKind::Subscription => schema.subscription_type(),
        };
        let Some(root) = root else { continue };
        let name = schema.get_type_name(root).lookup().to_string();
        if name == store_name {
            continue;
        }
        if schema.get_type(store_name.intern()).is_some() {
            errors.push(Diagnostic::error(
                format!(
                    "the {kind} type is `{name}` and another type is named `{store_name}`: the store types its {kind} root `{store_name}`, so the two would share their fields"
                ),
                location,
            ));
            continue;
        }
        // Under an interface or union a record's type is the payload's
        // `__typename`, which would name the schema's type, not the store's.
        let abstract_member = match root {
            Type::Object(id) => {
                !schema.object(id).interfaces.is_empty()
                    || schema.unions().any(|union| union.members.contains(&id))
            }
            _ => false,
        };
        if abstract_member {
            errors.push(Diagnostic::error(
                format!(
                    "the {kind} type `{name}` implements an interface or belongs to a union: the store types its {kind} root `{store_name}`, which a payload's `__typename` would not name"
                ),
                location,
            ));
            continue;
        }
        names.insert(name, store_name.to_string());
    }
    if errors.is_empty() {
        Ok(names)
    } else {
        Err(errors)
    }
}

/// Checks each lookup in `baton.json` against the schema: the root field
/// exists and takes the argument, and `type` is the field's concrete return
/// type, omitted only when the field returns an interface or a union.
fn validate_lookups(schema: &SDLSchema, config: &Config) -> Vec<Diagnostic> {
    let location = common::Location::new(
        SourceLocationKey::standalone(&config.path.to_string_lossy()),
        common::Span::new(0, 0),
    );
    let mut errors = Vec::new();
    for lookup in &config.lookups {
        let mut fail = |message: String| errors.push(Diagnostic::error(message, location));
        let Some((type_name, field_name)) = lookup.field.split_once('.') else {
            fail(format!(
                "the lookup `{}` names no field: write `Type.field`",
                lookup.field
            ));
            continue;
        };
        let Some(parent) = schema.get_type(type_name.intern()) else {
            fail(format!(
                "the lookup `{}` names the type `{type_name}`, which the schema does not have",
                lookup.field
            ));
            continue;
        };
        let Some(field) = schema.named_field(parent, field_name.intern()) else {
            fail(format!(
                "the lookup `{}` names a field `{type_name}` does not have",
                lookup.field
            ));
            continue;
        };
        let field = schema.field(field);
        if field
            .arguments
            .named(common::ArgumentName(lookup.argument.as_str().intern()))
            .is_none()
        {
            fail(format!(
                "the lookup `{}` takes `{}`, which the field has no argument of",
                lookup.field, lookup.argument
            ));
        }
        let returns = field.type_.inner();
        let returned = schema.get_type_name(returns).lookup();
        match (&lookup.type_name, returns.is_abstract_type()) {
            (Some(named), false) if named == returned => {}
            (Some(named), false) => fail(format!(
                "the lookup `{}` names the type `{named}`, but the field returns `{returned}`",
                lookup.field
            )),
            (Some(_), true) => fail(format!(
                "`{}` returns `{returned}`, an interface or union: the lookup takes no `type`, and finds the id among its types",
                lookup.field
            )),
            (None, false) => fail(format!(
                "`{}` returns `{returned}`: name it as the lookup's `type`",
                lookup.field
            )),
            (None, true) => {}
        }
    }
    errors
}

/// The subset of Relay's validations that apply to Baton's directive set,
/// run to completion so every error is reported at once.
fn validate(program: &Program, project_config: &ProjectConfig) -> Result<(), Vec<Diagnostic>> {
    let schema_config = &project_config.schema_config;
    let results = [
        validate_unused_variables(program),
        validate_unused_fragment_variables(program),
        validate_connections(program, &schema_config.connection_interface),
        validate_relay_directives(program),
        validate_global_variable_names(program),
        disallow_reserved_aliases(program, schema_config),
        validate_no_unselectable_selections(program, schema_config),
        validate_no_double_underscore_alias(program),
        disallow_typename_on_root(program),
        validate_static_args(program),
    ];
    let diagnostics: Vec<Diagnostic> = results
        .into_iter()
        .filter_map(Result::err)
        .flatten()
        .collect();
    if diagnostics.is_empty() {
        Ok(())
    } else {
        Err(diagnostics)
    }
}

/// Which program a selection set comes from. The reader reads a connection
/// through Relay's handle key and carries the required and catch metadata; the
/// normalization writes the server field, carries the handle beside it, and
/// keeps the raw `@catch` for the error accounting.
#[derive(Clone, Copy, PartialEq, Eq)]
enum Side {
    Reader,
    Normalization,
}

struct Lowering<'a> {
    schema: &'a SDLSchema,
    programs: &'a Programs,
    config: &'a Config,
    /// Errors found while lowering, reported together at the end.
    diagnostics: std::cell::RefCell<Vec<Diagnostic>>,
}

fn directive_name(name: &str) -> DirectiveName {
    DirectiveName(name.intern())
}

/// Lowers Relay's reader and normalization programs into the plan IR.
fn lower(
    schema: &SDLSchema,
    programs: &Programs,
    config: &Config,
) -> Result<Plan, Vec<Diagnostic>> {
    let lowering = Lowering {
        schema,
        programs,
        config,
        diagnostics: std::cell::RefCell::new(Vec::new()),
    };
    let mut plan = Plan::default();
    for fragment in programs.reader.fragments() {
        plan.fragments.push(lowering.fragment(fragment));
    }
    plan.fragments
        .sort_by(|left, right| left.name.cmp(&right.name));

    for operation in programs.normalization.operations() {
        let name = operation.name.item.0.lookup();
        let root_type = schema.get_type_name(operation.type_).lookup().to_string();
        let reader_operation = programs.reader.operation(operation.name.item);
        let reader = reader_operation
            .map(|reader_operation| {
                lowering.selections(
                    &reader_operation.selections,
                    operation.type_,
                    Side::Reader,
                    false,
                )
            })
            .unwrap_or_else(|| {
                lowering.internal(
                    "the reader program has no such operation",
                    operation.name.location,
                );
                Vec::new()
            });
        let text = programs
            .operation_text
            .operation(operation.name.item)
            .map(|text_operation| {
                print_full_operation(
                    &programs.operation_text,
                    text_operation,
                    PrinterOptions::default(),
                )
            })
            .unwrap_or_else(|| {
                lowering.internal(
                    "the operation has no printable text",
                    operation.name.location,
                );
                String::new()
            })
            // Trimmed once, here: the id is the hash of the very text the
            // app holds and sends.
            .trim_end()
            .to_string();
        let mut normalization = lowering.selections(
            &operation.selections,
            operation.type_,
            Side::Normalization,
            false,
        );
        let mut reader = reader;
        if operation.kind == SyntaxOperationKind::Mutation {
            key_by_response(&mut normalization);
            key_by_response(&mut reader);
        }
        // A mutation's payload and a subscription's event each arrive whole:
        // neither is read as a stream of parts.
        if operation.kind != SyntaxOperationKind::Query && has_deferred(&normalization) {
            lowering.diagnostics.borrow_mut().push(Diagnostic::error(
                format!(
                    "`@defer` in the {} `{name}`: its response arrives in one part, so nothing can be deferred",
                    operation.kind
                ),
                operation.name.location,
            ));
        }
        plan.operations.push(OperationPlan {
            name: name.to_string(),
            source: operation.name.location.source_location().path().to_string(),
            document: document_index(operation.name.location),
            kind: match operation.kind {
                SyntaxOperationKind::Query => OperationKind::Query,
                SyntaxOperationKind::Mutation => OperationKind::Mutation,
                SyntaxOperationKind::Subscription => OperationKind::Subscription,
            },
            root_type,
            variables: lowering.variables(&operation.variable_definitions),
            id: format!("{:x}", md5::compute(text.as_bytes())),
            text,
            throws_on_field_error: operation
                .directives
                .named(directive_name("throwOnFieldError"))
                .is_some(),
            bubbles: reader_operation.is_some_and(|reader_operation| {
                reader_operation
                    .directives
                    .named(*CHILDREN_CAN_BUBBLE_METADATA_KEY)
                    .is_some()
            }),
            has_deferred: has_deferred(&normalization),
            error_behavior: config
                .on_error
                .map(|behavior| behavior.swift_case().to_string()),
            reader,
            normalization,
        });
    }
    plan.operations
        .sort_by(|left, right| left.name.cmp(&right.name));
    // An operation is lowered twice, as its reader and as its
    // normalization, so a selection's error is found twice: once is told.
    let mut diagnostics: Vec<Diagnostic> = Vec::new();
    for diagnostic in lowering.diagnostics.into_inner() {
        let repeated = diagnostics.iter().any(|told| {
            told.location() == diagnostic.location()
                && told.message().to_string() == diagnostic.message().to_string()
        });
        if !repeated {
            diagnostics.push(diagnostic);
        }
    }
    if diagnostics.is_empty() {
        Ok(plan)
    } else {
        Err(diagnostics)
    }
}

fn has_deferred(selections: &[SelectionPlan]) -> bool {
    selections.iter().any(|selection| match selection {
        SelectionPlan::Inline {
            deferred,
            selections,
            ..
        } => deferred.is_some() || has_deferred(selections),
        SelectionPlan::Linked { selections, .. } | SelectionPlan::Condition { selections, .. } => {
            has_deferred(selections)
        }
        _ => false,
    })
}

/// The place among its file's documents of the one a definition came from.
fn document_index(location: common::Location) -> usize {
    match location.source_location() {
        SourceLocationKey::Embedded { index, .. } => usize::from(index),
        _ => 0,
    }
}

impl Lowering<'_> {
    fn fragment(&self, fragment: &FragmentDefinition) -> FragmentPlan {
        let mut plan = FragmentPlan {
            name: fragment.name.item.0.lookup().to_string(),
            source: fragment.name.location.source_location().path().to_string(),
            document: document_index(fragment.name.location),
            type_condition: self
                .schema
                .get_type_name(fragment.type_condition)
                .lookup()
                .to_string(),
            type_is_abstract: fragment.type_condition.is_abstract_type(),
            possible_types: self.possible_types(fragment.type_condition),
            arguments: self.variables(&fragment.variable_definitions),
            refetch: self.refetch(fragment),
            throws_on_field_error: fragment
                .directives
                .named(directive_name("throwOnFieldError"))
                .is_some(),
            bubbles: fragment
                .directives
                .named(*CHILDREN_CAN_BUBBLE_METADATA_KEY)
                .is_some(),
            reader: self.selections(
                &fragment.selections,
                fragment.type_condition,
                Side::Reader,
                false,
            ),
        };
        // A fragment on the mutation type is only ever read at the mutation
        // root, whose fields the mutation writes by response key: it reads
        // them by the same keys.
        if self.schema.mutation_type() == Some(fragment.type_condition) {
            key_by_response(&mut plan.reader);
        }
        plan
    }

    /// The `@refetchable` metadata Relay attached: the generated query's name
    /// and variables, the id variable, and the one connection it paginates.
    fn refetch(&self, fragment: &FragmentDefinition) -> Option<RefetchPlan> {
        let metadata = RefetchableMetadata::find(&fragment.directives)?;
        let operation = metadata.operation_name.0.lookup().to_string();
        let variables = self
            .programs
            .normalization
            .operation(metadata.operation_name)
            .map(|query| {
                query
                    .variable_definitions
                    .iter()
                    .map(|variable| variable.name.item.0.lookup().to_string())
                    .collect()
            })
            .unwrap_or_else(|| {
                self.internal(
                    "the refetch query Relay generated is missing",
                    fragment.name.location,
                );
                Vec::new()
            });
        let connection = extract_connection_metadata_from_directive(&fragment.directives)
            .filter(|metadatas| metadatas.len() == 1)
            .and_then(|metadatas| {
                let metadata = &metadatas[0];
                let path = metadata.path.as_ref()?;
                Some(PaginationPlan {
                    path: path.iter().map(|part| part.lookup().to_string()).collect(),
                    first: metadata.first.map(|name| name.lookup().to_string()),
                    after: metadata.after.map(|name| name.lookup().to_string()),
                    last: metadata.last.map(|name| name.lookup().to_string()),
                    before: metadata.before.map(|name| name.lookup().to_string()),
                })
            });
        Some(RefetchPlan {
            operation,
            variables,
            identifier: metadata
                .identifier_info
                .as_ref()
                .map(|info| info.identifier_query_variable_name.lookup().to_string()),
            connection,
        })
    }

    fn variables(&self, definitions: &[graphql_ir::VariableDefinition]) -> Vec<VariablePlan> {
        definitions
            .iter()
            .map(|variable| VariablePlan {
                name: variable.name.item.0.lookup().to_string(),
                type_name: self.type_reference_name(&variable.type_),
                base_type: self
                    .schema
                    .get_type_name(variable.type_.inner())
                    .lookup()
                    .to_string(),
                base_kind: self.type_kind(variable.type_.inner()),
                non_null: variable.type_.is_non_null(),
                list: variable.type_.is_list(),
                default_value: variable
                    .default_value
                    .as_ref()
                    .map(|value| constant_plan(&value.item)),
            })
            .collect()
    }

    /// Whether objects of this type are keyed by `id`: the type has an `id`
    /// field, or it is abstract and a concrete type behind it has one; the
    /// payload's `__typename` then names the type to key by.
    fn type_has_id(&self, type_: Type) -> bool {
        match type_ {
            // An interface need not declare the `id` its implementers have:
            // GitHub's `Actor` does not, and its users are still entities.
            Type::Union(_) | Type::Interface(_) => {
                self.possible_objects(type_).into_iter().any(|object| {
                    self.schema
                        .named_field(Type::Object(object), "id".intern())
                        .is_some()
                })
            }
            _ => self.schema.named_field(type_, "id".intern()).is_some(),
        }
    }

    /// The concrete types a type admits, sorted by name: an object type is
    /// itself, an interface every object that implements it, a union its
    /// members.
    fn possible_types(&self, type_: Type) -> Vec<String> {
        let mut names: Vec<String> = self
            .possible_objects(type_)
            .into_iter()
            .map(|id| self.schema.object(id).name.item.0.lookup().to_string())
            .collect();
        names.sort();
        names
    }

    fn possible_objects(&self, type_: Type) -> Vec<schema::ObjectID> {
        match type_ {
            Type::Object(id) => vec![id],
            Type::Interface(id) => self
                .schema
                .interface(id)
                .recursively_implementing_objects(self.schema)
                .into_iter()
                .collect(),
            Type::Union(id) => self.schema.union(id).members.clone(),
            _ => Vec::new(),
        }
    }

    /// How a type condition stands to the parent's possible types.
    fn condition_class(&self, parent: Type, condition: Type) -> ConditionClass {
        let admitted = self.possible_types(condition);
        let satisfying: Vec<String> = self
            .possible_types(parent)
            .into_iter()
            .filter(|type_name| admitted.contains(type_name))
            .collect();
        if parent == condition || satisfying.len() == self.possible_types(parent).len() {
            ConditionClass::Always
        } else if let [only] = satisfying.as_slice() {
            ConditionClass::Concrete(only.clone())
        } else {
            ConditionClass::Set
        }
    }

    /// The named type of a field on `parent`, for the connection's edge and
    /// page info types.
    fn field_type_name(&self, parent: Type, field: &str, location: common::Location) -> String {
        self.schema
            .named_field(parent, field.intern())
            .map(|id| {
                self.schema
                    .get_type_name(self.schema.field(id).type_.inner())
                    .lookup()
                    .to_string()
            })
            .unwrap_or_else(|| {
                self.internal(
                    &format!("a connection Relay validated has no `{field}`"),
                    location,
                );
                String::new()
            })
    }

    /// The edge directive Relay attached to a field as its handle; none for
    /// a connection's handle, which `connection` reads.
    fn handle(&self, directives: &[graphql_ir::Directive]) -> Option<HandlePlan> {
        let directive = extract_handle_field_directives(directives).next()?;
        let values = extract_values_from_handle_field_directive(directive);
        let name = values.handle.lookup();
        if name == "connection" {
            return None;
        }
        let Some(kind) = HandleKind::of(name) else {
            self.internal(
                &format!("Relay attached the handle `{name}`, which is no edge directive"),
                directive.name.location,
            );
            return None;
        };
        let arguments = values.handle_args.unwrap_or_default();
        let connections = arguments
            .named(common::ArgumentName("connections".intern()))
            .and_then(|argument| {
                let value = argument_value_plan(&argument.value.item);
                if matches!(
                    value,
                    ArgumentValuePlan::List(_) | ArgumentValuePlan::Object(_)
                ) {
                    self.diagnostics.borrow_mut().push(Diagnostic::error(
                        "pass the connection ids as one variable or as a list of constants",
                        argument.value.location,
                    ));
                    return None;
                }
                Some(value)
            });
        Some(HandlePlan {
            kind,
            connections,
            edge_type_name: arguments
                .named(common::ArgumentName("edgeTypeName".intern()))
                .and_then(|argument| match &argument.value.item {
                    graphql_ir::Value::Constant(graphql_ir::ConstantValue::String(name)) => {
                        Some(name.lookup().to_string())
                    }
                    _ => None,
                }),
        })
    }

    /// The `@required` metadata the reader program carries.
    fn required(&self, directives: &[graphql_ir::Directive]) -> Option<RequiredPlan> {
        let metadata = RequiredMetadataDirective::find(directives)?;
        Some(RequiredPlan {
            action: match metadata.action {
                RelayRequiredAction::None => RequiredAction::None,
                RelayRequiredAction::Log => RequiredAction::Log,
                RelayRequiredAction::Throw
                | RelayRequiredAction::DangerouslyThrowOnSemanticallyNullableField => {
                    RequiredAction::Throw
                }
            },
            path: metadata.path.lookup().to_string(),
        })
    }

    /// The `@catch` metadata the reader program carries.
    fn catch(&self, directives: &[graphql_ir::Directive]) -> Option<CatchPlan> {
        let metadata = CatchMetadataDirective::find(directives)?;
        Some(CatchPlan {
            to: match metadata.to {
                CatchTo::Result => CatchTarget::Result,
                CatchTo::Null => CatchTarget::Null,
            },
        })
    }

    /// Whether the field carries `@catch` in whatever form the program keeps
    /// it: the reader's metadata, or the normalization's raw directive.
    fn is_caught(&self, directives: &[graphql_ir::Directive]) -> bool {
        CatchMetadataDirective::find(directives).is_some()
            || directives.named(*CATCH_DIRECTIVE_NAME).is_some()
    }

    fn bubbles(&self, directives: &[graphql_ir::Directive]) -> bool {
        directives
            .named(*CHILDREN_CAN_BUBBLE_METADATA_KEY)
            .is_some()
    }

    /// Reports a state of Relay's programs the lowering relies on never
    /// meeting: a fault of the compiler, said where it was met rather than
    /// lowered into an empty plan.
    fn internal(&self, what: &str, location: common::Location) {
        self.diagnostics.borrow_mut().push(Diagnostic::error(
            format!("internal error: {what}; please report it"),
            location,
        ));
    }

    /// `@semanticNonNull` makes a nullable field non-null in the absence of
    /// errors; under `onError: NULL` every field the schema types non-null is
    /// one too, since an error nulls it in place.
    fn semantic_non_null(&self, definition: &schema::definitions::Field) -> bool {
        if self.nulls_on_error() && definition.type_.is_non_null() {
            return true;
        }
        !definition.type_.is_non_null() && definition.semantic_type().is_non_null()
    }

    /// Whether a field the schema types non-null is non-null in the response:
    /// not under `onError: NULL`, where an error nulls it.
    fn non_null(&self, definition: &schema::definitions::Field) -> bool {
        definition.type_.is_non_null() && !self.nulls_on_error()
    }

    fn nulls_on_error(&self) -> bool {
        self.config.on_error == Some(crate::config::OnError::Null)
    }

    fn selections(
        &self,
        selections: &[Selection],
        parent_type: Type,
        side: Side,
        caught: bool,
    ) -> Vec<SelectionPlan> {
        selections
            .iter()
            .map(|selection| match selection {
                Selection::ScalarField(field) => {
                    let definition = self.schema.field(field.definition.item);
                    let field_caught = caught || self.is_caught(&field.directives);
                    SelectionPlan::Scalar {
                        name: definition.name.item.lookup().to_string(),
                        alias: field.alias.map(|alias| alias.item.lookup().to_string()),
                        type_name: self.type_reference_name(&definition.type_),
                        base_type: self
                            .schema
                            .get_type_name(definition.type_.inner())
                            .lookup()
                            .to_string(),
                        base_kind: self.type_kind(definition.type_.inner()),
                        non_null: self.non_null(definition),
                        semantic_non_null: self.semantic_non_null(definition),
                        list: definition.type_.is_list(),
                        storage_key: storage_key(definition.name.item.lookup(), &field.arguments),
                        handle: self.handle(&field.directives),
                        required: self.required(&field.directives),
                        catch: self.catch(&field.directives),
                        caught: field_caught,
                    }
                }
                Selection::LinkedField(field) => {
                    let definition = self.schema.field(field.definition.item);
                    let target = definition.type_.inner();
                    let name = definition.name.item.lookup();
                    let parent_name = self.schema.get_type_name(parent_type).lookup();
                    let lookup = self
                        .config
                        .lookups
                        .iter()
                        .find(|lookup| lookup.field == format!("{parent_name}.{name}"))
                        .and_then(|lookup| {
                            let argument = field
                                .arguments
                                .named(common::ArgumentName(lookup.argument.as_str().intern()));
                            let Some(argument) = argument else {
                                self.diagnostics.borrow_mut().push(Diagnostic::error(
                                    format!(
                                        "baton.json looks `{parent_name}.{name}` up by `{}`, which this selection does not pass",
                                        lookup.argument
                                    ),
                                    field.alias_or_name_location(),
                                ));
                                return None;
                            };
                            let value = argument_value_plan(&argument.value.item);
                            if matches!(value, ArgumentValuePlan::List(_) | ArgumentValuePlan::Object(_)) {
                                self.diagnostics.borrow_mut().push(Diagnostic::error(
                                    format!(
                                        "the lookup argument `{}` of `{parent_name}.{name}` must be a variable or a constant",
                                        lookup.argument
                                    ),
                                    argument.value.location,
                                ));
                                return None;
                            }
                            Some(LookupPlan {
                                type_name: lookup.type_name.clone(),
                                possible_types: self.possible_types(target),
                                argument: lookup.argument.clone(),
                                value,
                            })
                        });
                    let handle = self.handle(&field.directives);
                    let mut connection = None;
                    let mut field_storage_key = storage_key(name, &field.arguments);
                    let connection_handle = extract_handle_field_directives(&field.directives)
                        .next()
                        .map(extract_values_from_handle_field_directive)
                        .filter(|values| values.handle.lookup() == "connection");
                    if let Some(values) = connection_handle {
                        let handle_name = format!("__{}_connection", values.key.lookup());
                        // Relay's reader keeps only the filter arguments; the
                        // normalization keeps them all, and the connection
                        // record's key is the handle with the filters.
                        let filtered: Vec<graphql_ir::Argument> = field
                            .arguments
                            .iter()
                            .filter(|argument| match &values.filters {
                                Some(filters) => filters.contains(&argument.name.item.0),
                                None => false,
                            })
                            .cloned()
                            .collect();
                        let client_key = match side {
                            Side::Reader => storage_key(&handle_name, &field.arguments),
                            Side::Normalization => storage_key(&handle_name, &filtered),
                        };
                        if side == Side::Reader {
                            field_storage_key = client_key.clone();
                        }
                        let cursor = |argument: &str| {
                            field
                                .arguments
                                .named(common::ArgumentName(argument.intern()))
                                .map(|argument| argument_value_plan(&argument.value.item))
                                .filter(|value| {
                                    !matches!(
                                        value,
                                        ArgumentValuePlan::Constant(ConstantPlan::Null)
                                    )
                                })
                        };
                        connection = Some(ConnectionPlan {
                            key: values.key.lookup().to_string(),
                            storage_key: client_key,
                            edge_type: self.field_type_name(target, "edges", field.alias_or_name_location()),
                            page_info_type: self.field_type_name(
                                target,
                                "pageInfo",
                                field.alias_or_name_location(),
                            ),
                            after: cursor("after"),
                            before: cursor("before"),
                        });
                    }
                    let field_caught = caught || self.is_caught(&field.directives);
                    SelectionPlan::Linked {
                        name: name.to_string(),
                        alias: field.alias.map(|alias| alias.item.lookup().to_string()),
                        type_name: self.type_reference_name(&definition.type_),
                        base_type: self.schema.get_type_name(target).lookup().to_string(),
                        base_kind: self.type_kind(target),
                        non_null: self.non_null(definition),
                        semantic_non_null: self.semantic_non_null(definition),
                        plural: definition.type_.is_list(),
                        has_id: self.type_has_id(target),
                        is_abstract: target.is_abstract_type(),
                        possible_types: self.possible_types(target),
                        storage_key: field_storage_key,
                        lookup,
                        connection,
                        handle,
                        required: self.required(&field.directives),
                        catch: self.catch(&field.directives),
                        caught: field_caught,
                        bubbles: self.bubbles(&field.directives),
                        selections: self.selections(&field.selections, target, side, field_caught),
                    }
                }
                Selection::InlineFragment(inline) => {
                    let alias =
                        FragmentAliasMetadata::find(&inline.directives).and_then(|metadata| {
                            let alias = metadata.alias.item.lookup();
                            let default: Option<String> = if metadata.wraps_spread {
                                match inline.selections.first() {
                                    Some(Selection::FragmentSpread(spread)) => {
                                        Some(spread.fragment.item.0.lookup().to_string())
                                    }
                                    _ => None,
                                }
                            } else {
                                inline.type_condition.map(|type_| {
                                    self.schema.get_type_name(type_).lookup().to_string()
                                })
                            };
                            (default.as_deref() != Some(alias)).then(|| alias.to_string())
                        });
                    let deferred = inline
                        .directives
                        .named(directive_name("defer"))
                        .and_then(|directive| {
                            directive
                                .arguments
                                .named(common::ArgumentName("label".intern()))
                        })
                        .and_then(|label| match &label.value.item {
                            graphql_ir::Value::Constant(graphql_ir::ConstantValue::String(
                                text,
                            )) => Some(text.lookup().to_string()),
                            _ => None,
                        });
                    let inline_caught = caught || self.is_caught(&inline.directives);
                    SelectionPlan::Inline {
                        type_condition: inline
                            .type_condition
                            .map(|type_| self.schema.get_type_name(type_).lookup().to_string()),
                        condition_types: inline
                            .type_condition
                            .map(|type_| self.possible_types(type_)),
                        condition_class: inline
                            .type_condition
                            .map(|type_| self.condition_class(parent_type, type_)),
                        alias,
                        deferred,
                        catch: self.catch(&inline.directives),
                        bubbles: self.bubbles(&inline.directives),
                        selections: self.selections(
                            &inline.selections,
                            inline.type_condition.unwrap_or(parent_type),
                            side,
                            inline_caught,
                        ),
                    }
                }
                Selection::FragmentSpread(spread) => SelectionPlan::Spread {
                    fragment: spread.fragment.item.0.lookup().to_string(),
                    type_condition: self
                        .programs
                        .reader
                        .fragment(spread.fragment.item)
                        .map(|fragment| {
                            self.schema
                                .get_type_name(fragment.type_condition)
                                .lookup()
                                .to_string()
                        })
                        .unwrap_or_else(|| {
                            self.internal("the spread names a fragment the reader program lacks", spread.fragment.location);
                            String::new()
                        }),
                    arguments: spread
                        .arguments
                        .iter()
                        .map(|argument| ArgumentPlan {
                            name: argument.name.item.0.lookup().to_string(),
                            value: argument_value_plan(&argument.value.item),
                        })
                        .collect(),
                },
                Selection::Condition(condition) => SelectionPlan::Condition {
                    variable: match &condition.value {
                        ConditionValue::Variable(variable) => {
                            Some(variable.name.item.0.lookup().to_string())
                        }
                        ConditionValue::Constant(_) => None,
                    },
                    passing: condition.passing_value,
                    selections: self.selections(&condition.selections, parent_type, side, caught),
                },
            })
            .collect()
    }

    fn type_kind(&self, type_: Type) -> TypeKind {
        match type_ {
            Type::Scalar(_) => {
                if self.schema.is_string(type_) {
                    TypeKind::String
                } else if self.schema.is_id(type_) {
                    TypeKind::Id
                } else {
                    match self.schema.get_type_name(type_).lookup() {
                        "Int" => TypeKind::Int,
                        "Float" => TypeKind::Float,
                        "Boolean" => TypeKind::Boolean,
                        _ => TypeKind::CustomScalar,
                    }
                }
            }
            Type::Enum(_) => TypeKind::Enum,
            Type::Object(_) => TypeKind::Object,
            Type::Interface(_) => TypeKind::Interface,
            Type::Union(_) => TypeKind::Union,
            Type::InputObject(_) => TypeKind::InputObject,
        }
    }

    fn type_reference_name(&self, type_: &TypeReference<Type>) -> String {
        match type_ {
            TypeReference::Named(named) => self.schema.get_type_name(*named).lookup().to_string(),
            TypeReference::NonNull(inner) => format!("{}!", self.type_reference_name(inner)),
            TypeReference::List(inner) => format!("[{}]", self.type_reference_name(inner)),
        }
    }
}

/// Relay's storage key: the field name and its arguments sorted by name.
/// Variables stay symbolic; the runtime binds them.
fn storage_key(name: &str, arguments: &[graphql_ir::Argument]) -> StorageKeyPlan {
    let mut sorted: Vec<&graphql_ir::Argument> = arguments.iter().collect();
    sorted.sort_by_key(|argument| argument.name.item.0.lookup());
    StorageKeyPlan {
        name: name.to_string(),
        arguments: sorted
            .into_iter()
            .map(|argument| ArgumentPlan {
                name: argument.name.item.0.lookup().to_string(),
                value: argument_value_plan(&argument.value.item),
            })
            .collect(),
    }
}

fn constant_plan(value: &graphql_ir::ConstantValue) -> ConstantPlan {
    match value {
        graphql_ir::ConstantValue::Int(int) => ConstantPlan::Int(*int),
        graphql_ir::ConstantValue::Float(float) => ConstantPlan::Float(float.as_float()),
        graphql_ir::ConstantValue::String(string) | graphql_ir::ConstantValue::Enum(string) => {
            ConstantPlan::String(string.lookup().to_string())
        }
        graphql_ir::ConstantValue::Boolean(boolean) => ConstantPlan::Bool(*boolean),
        graphql_ir::ConstantValue::Null() => ConstantPlan::Null,
        graphql_ir::ConstantValue::List(items) => {
            ConstantPlan::List(items.iter().map(constant_plan).collect())
        }
        graphql_ir::ConstantValue::Object(fields) => ConstantPlan::Object(
            fields
                .iter()
                .map(|field| {
                    (
                        field.name.item.0.lookup().to_string(),
                        constant_plan(&field.value.item),
                    )
                })
                .collect(),
        ),
    }
}

/// An argument as the plan carries it: a variable name, a constant, or a
/// list or object of either.
fn argument_value_plan(value: &graphql_ir::Value) -> ArgumentValuePlan {
    match value {
        graphql_ir::Value::Constant(constant) => {
            ArgumentValuePlan::Constant(constant_plan(constant))
        }
        graphql_ir::Value::Variable(variable) => {
            ArgumentValuePlan::Variable(variable.name.item.0.lookup().to_string())
        }
        graphql_ir::Value::List(items) => {
            ArgumentValuePlan::List(items.iter().map(argument_value_plan).collect())
        }
        graphql_ir::Value::Object(fields) => ArgumentValuePlan::Object(
            fields
                .iter()
                .map(|field| {
                    (
                        field.name.item.0.lookup().to_string(),
                        argument_value_plan(&field.value.item),
                    )
                })
                .collect(),
        ),
    }
}

#[cfg(test)]
#[path = "tests/pipeline_tests.rs"]
mod tests;
