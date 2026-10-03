//! The front end: Relay's parser, schema, IR, validations and transforms,
//! driven by Baton and lowered into Baton's plan IR.
//!
//! Everything in this file up to `lower` is Relay's; everything after is ours.
//! The plan IR is the seam: emitters never see Relay types.

use std::sync::Arc;
use std::time::{Duration, Instant};

use common::{Diagnostic, NoopPerfLogger, SourceLocationKey};
use graphql_ir::{
    ConditionValue, FragmentDefinition, FragmentDefinitionNameSet, Program, Selection,
};
use graphql_syntax::OperationKind;
use graphql_text_printer::{PrinterOptions, print_full_operation};
use intern::Lookup;
use intern::string_key::Intern;
use relay_config::ProjectConfig;
use relay_transforms::{
    Programs, apply_transforms, disallow_reserved_aliases, disallow_typename_on_root,
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
}

#[derive(Debug, Clone, serde::Serialize)]
pub struct FragmentPlan {
    pub name: String,
    /// The file the fragment was declared in.
    pub source: String,
    pub type_condition: String,
    /// Whether the type condition is an interface or union.
    pub type_is_abstract: bool,
    pub arguments: Vec<VariablePlan>,
    pub reader: Vec<SelectionPlan>,
}

#[derive(Debug, Clone, serde::Serialize)]
pub struct OperationPlan {
    pub name: String,
    /// The file the operation was declared in.
    pub source: String,
    pub kind: String,
    pub root_type: String,
    pub variables: Vec<VariablePlan>,
    pub text: String,
    pub id: String,
    pub reader: Vec<SelectionPlan>,
    pub normalization: Vec<SelectionPlan>,
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

/// A root field that returns an entity addressable by one of its arguments,
/// so a cached entity can satisfy the field before it was ever fetched.
#[derive(Debug, Clone, serde::Serialize)]
pub struct LookupPlan {
    /// `None` resolves by id across types.
    pub type_name: Option<String>,
    pub argument: String,
}

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
        list: bool,
        storage_key: String,
    },
    Linked {
        name: String,
        alias: Option<String>,
        type_name: String,
        base_type: String,
        base_kind: TypeKind,
        non_null: bool,
        plural: bool,
        /// Whether the target type defines an `id` field (identity by typename and id).
        has_id: bool,
        /// Whether the target type is an interface or union: records are then
        /// keyed and sloted by the payload's `__typename`.
        is_abstract: bool,
        storage_key: String,
        lookup: Option<LookupPlan>,
        selections: Vec<SelectionPlan>,
    },
    Inline {
        type_condition: Option<String>,
        selections: Vec<SelectionPlan>,
    },
    Spread {
        fragment: String,
        type_condition: String,
    },
    Condition {
        variable: Option<String>,
        passing: bool,
        selections: Vec<SelectionPlan>,
    },
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

    let started = Instant::now();
    let mut definitions = Vec::new();
    let mut diagnostics = Vec::new();
    for document in documents {
        let key = SourceLocationKey::embedded(&document.path.to_string_lossy(), document.index);
        match graphql_syntax::parse_executable(&document.text, key) {
            Ok(parsed) => definitions.extend(parsed.definitions),
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
    let plan = lower(&schema, &programs, config);
    timings.lower = started.elapsed();

    Ok(Compiled { plan, timings })
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

struct Lowering<'a> {
    schema: &'a SDLSchema,
    programs: &'a Programs,
    config: &'a Config,
}

/// Lowers Relay's reader and normalization programs into the plan IR.
fn lower(schema: &SDLSchema, programs: &Programs, config: &Config) -> Plan {
    let lowering = Lowering {
        schema,
        programs,
        config,
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
        let reader = programs
            .reader
            .operation(operation.name.item)
            .map(|reader_operation| {
                lowering.selections(&reader_operation.selections, operation.type_)
            })
            .unwrap_or_default();
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
            .unwrap_or_default();
        plan.operations.push(OperationPlan {
            name: name.to_string(),
            source: operation.name.location.source_location().path().to_string(),
            kind: match operation.kind {
                OperationKind::Query => "query",
                OperationKind::Mutation => "mutation",
                OperationKind::Subscription => "subscription",
            }
            .to_string(),
            root_type,
            variables: lowering.variables(&operation.variable_definitions),
            id: format!("{:x}", md5::compute(text.as_bytes())),
            text,
            reader,
            normalization: lowering.selections(&operation.selections, operation.type_),
        });
    }
    plan.operations
        .sort_by(|left, right| left.name.cmp(&right.name));
    plan
}

impl Lowering<'_> {
    fn fragment(&self, fragment: &FragmentDefinition) -> FragmentPlan {
        FragmentPlan {
            name: fragment.name.item.0.lookup().to_string(),
            source: fragment.name.location.source_location().path().to_string(),
            type_condition: self
                .schema
                .get_type_name(fragment.type_condition)
                .lookup()
                .to_string(),
            type_is_abstract: fragment.type_condition.is_abstract_type(),
            arguments: self.variables(&fragment.variable_definitions),
            reader: self.selections(&fragment.selections, fragment.type_condition),
        }
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
            })
            .collect()
    }

    /// Whether objects of this type are keyed by `id`: the type has an `id`
    /// field, or it is abstract and a concrete type behind it has one; the
    /// payload's `__typename` then names the type to key by.
    fn type_has_id(&self, type_: Type) -> bool {
        match type_ {
            Type::Union(id) => self.schema.union(id).members.iter().any(|member| {
                self.schema
                    .named_field(Type::Object(*member), "id".intern())
                    .is_some()
            }),
            _ => self.schema.named_field(type_, "id".intern()).is_some(),
        }
    }

    fn selections(&self, selections: &[Selection], parent_type: Type) -> Vec<SelectionPlan> {
        selections
            .iter()
            .map(|selection| match selection {
                Selection::ScalarField(field) => {
                    let definition = self.schema.field(field.definition.item);
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
                        non_null: definition.type_.is_non_null(),
                        list: definition.type_.is_list(),
                        storage_key: storage_key(definition.name.item.lookup(), &field.arguments),
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
                        .map(|lookup| LookupPlan {
                            type_name: lookup.type_name.clone(),
                            argument: lookup.argument.clone(),
                        });
                    SelectionPlan::Linked {
                        name: name.to_string(),
                        alias: field.alias.map(|alias| alias.item.lookup().to_string()),
                        type_name: self.type_reference_name(&definition.type_),
                        base_type: self.schema.get_type_name(target).lookup().to_string(),
                        base_kind: self.type_kind(target),
                        non_null: definition.type_.is_non_null(),
                        plural: definition.type_.is_list(),
                        has_id: self.type_has_id(target),
                        is_abstract: target.is_abstract_type(),
                        storage_key: storage_key(name, &field.arguments),
                        lookup,
                        selections: self.selections(&field.selections, target),
                    }
                }
                Selection::InlineFragment(inline) => SelectionPlan::Inline {
                    type_condition: inline
                        .type_condition
                        .map(|type_| self.schema.get_type_name(type_).lookup().to_string()),
                    selections: self.selections(
                        &inline.selections,
                        inline.type_condition.unwrap_or(parent_type),
                    ),
                },
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
                        .unwrap_or_default(),
                },
                Selection::Condition(condition) => SelectionPlan::Condition {
                    variable: match &condition.value {
                        ConditionValue::Variable(variable) => {
                            Some(variable.name.item.0.lookup().to_string())
                        }
                        ConditionValue::Constant(_) => None,
                    },
                    passing: condition.passing_value,
                    selections: self.selections(&condition.selections, parent_type),
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

/// Relay's storage key: the field name, plus `(arg:value,...)` when the field
/// has arguments. Variables are kept symbolic; the runtime binds them.
fn storage_key(name: &str, arguments: &[graphql_ir::Argument]) -> String {
    if arguments.is_empty() {
        return name.to_string();
    }
    let mut sorted: Vec<&graphql_ir::Argument> = arguments.iter().collect();
    sorted.sort_by_key(|argument| argument.name.item.0.lookup());
    let rendered: Vec<String> = sorted
        .iter()
        .map(|argument| {
            format!(
                "{}:{}",
                argument.name.item.0.lookup(),
                render_value(&argument.value.item)
            )
        })
        .collect();
    format!("{}({})", name, rendered.join(","))
}

/// A constant argument as JSON, the way Relay's `formatStorageKey` renders it:
/// enums as strings, object keys in source order (the IR sorts them).
fn render_constant(value: &graphql_ir::ConstantValue) -> String {
    match value {
        graphql_ir::ConstantValue::Int(int) => int.to_string(),
        graphql_ir::ConstantValue::Float(float) => float.as_float().to_string(),
        graphql_ir::ConstantValue::String(string) | graphql_ir::ConstantValue::Enum(string) => {
            json_string(string.lookup())
        }
        graphql_ir::ConstantValue::Boolean(boolean) => boolean.to_string(),
        graphql_ir::ConstantValue::Null() => "null".to_string(),
        graphql_ir::ConstantValue::List(items) => {
            let items: Vec<String> = items.iter().map(render_constant).collect();
            format!("[{}]", items.join(","))
        }
        graphql_ir::ConstantValue::Object(fields) => {
            let mut sorted: Vec<&graphql_ir::ConstantArgument> = fields.iter().collect();
            sorted.sort_by_key(|field| field.name.item.0.lookup());
            let fields: Vec<String> = sorted
                .iter()
                .map(|field| {
                    format!(
                        "{}:{}",
                        json_string(field.name.item.0.lookup()),
                        render_constant(&field.value.item)
                    )
                })
                .collect();
            format!("{{{}}}", fields.join(","))
        }
    }
}

fn json_string(text: &str) -> String {
    let mut output = String::with_capacity(text.len() + 2);
    output.push('"');
    for character in text.chars() {
        match character {
            '"' => output.push_str("\\\""),
            '\\' => output.push_str("\\\\"),
            '\n' => output.push_str("\\n"),
            '\r' => output.push_str("\\r"),
            '\t' => output.push_str("\\t"),
            other if (other as u32) < 0x20 => output.push_str(&format!("\\u{:04x}", other as u32)),
            other => output.push(other),
        }
    }
    output.push('"');
    output
}

fn render_value(value: &graphql_ir::Value) -> String {
    match value {
        graphql_ir::Value::Constant(constant) => render_constant(constant),
        graphql_ir::Value::Variable(variable) => format!("${}", variable.name.item.0.lookup()),
        graphql_ir::Value::List(items) => {
            let items: Vec<String> = items.iter().map(render_value).collect();
            format!("[{}]", items.join(","))
        }
        graphql_ir::Value::Object(fields) => {
            let fields: Vec<String> = fields
                .iter()
                .map(|field| {
                    format!(
                        "{}:{}",
                        field.name.item.0.lookup(),
                        render_value(&field.value.item)
                    )
                })
                .collect();
            format!("{{{}}}", fields.join(","))
        }
    }
}
