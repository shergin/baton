//! The front end: Relay's parser, schema, IR, validations and transforms,
//! driven by Baton and lowered into Baton's plan IR.
//!
//! Everything in this file up to `lower` is Relay's; everything after is ours.
//! The plan IR is the seam: emitters never see Relay types.

use std::sync::Arc;
use std::time::{Duration, Instant};

use common::{Diagnostic, NoopPerfLogger, SourceLocationKey};
use graphql_ir::{
    ConditionValue, FragmentDefinition, FragmentDefinitionNameSet, OperationDefinition, Program,
    Selection,
};
use graphql_syntax::OperationKind;
use graphql_text_printer::{PrinterOptions, print_full_operation};
use intern::Lookup;
use relay_config::ProjectConfig;
use relay_transforms::{
    Programs, apply_transforms, disallow_reserved_aliases, disallow_typename_on_root,
    validate_connections, validate_global_variable_names, validate_no_double_underscore_alias,
    validate_no_unselectable_selections, validate_relay_directives, validate_static_args,
    validate_unused_fragment_variables, validate_unused_variables,
};
use schema::{SDLSchema, Schema, Type, TypeReference};

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
/// operation's normalization shape, text and id.
#[derive(Debug, Default, Clone, serde::Serialize)]
pub struct Plan {
    pub fragments: Vec<FragmentPlan>,
    pub operations: Vec<OperationPlan>,
}

#[derive(Debug, Clone, serde::Serialize)]
pub struct FragmentPlan {
    pub name: String,
    pub type_condition: String,
    pub arguments: Vec<VariablePlan>,
    pub reader: Vec<SelectionPlan>,
}

#[derive(Debug, Clone, serde::Serialize)]
pub struct OperationPlan {
    pub name: String,
    pub kind: String,
    pub variables: Vec<VariablePlan>,
    pub text: String,
    pub id: String,
    pub reader: Vec<SelectionPlan>,
    pub normalization: Vec<SelectionPlan>,
}

#[derive(Debug, Clone, serde::Serialize)]
pub struct VariablePlan {
    pub name: String,
    pub type_name: String,
}

#[derive(Debug, Clone, serde::Serialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum SelectionPlan {
    Scalar {
        name: String,
        alias: Option<String>,
        type_name: String,
        storage_key: String,
    },
    Linked {
        name: String,
        alias: Option<String>,
        type_name: String,
        storage_key: String,
        plural: bool,
        selections: Vec<SelectionPlan>,
    },
    Inline {
        type_condition: Option<String>,
        selections: Vec<SelectionPlan>,
    },
    Spread {
        fragment: String,
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
    let plan = lower(&schema, &programs);
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

/// Lowers Relay's reader and normalization programs into the plan IR.
fn lower(schema: &SDLSchema, programs: &Programs) -> Plan {
    let mut plan = Plan::default();
    for fragment in programs.reader.fragments() {
        plan.fragments.push(lower_fragment(schema, fragment));
    }
    plan.fragments
        .sort_by(|left, right| left.name.cmp(&right.name));

    for operation in programs.normalization.operations() {
        let name = operation.name.item.0.lookup();
        let reader = programs
            .reader
            .operation(operation.name.item)
            .map(|reader_operation| lower_selections(schema, &reader_operation.selections))
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
            kind: match operation.kind {
                OperationKind::Query => "query",
                OperationKind::Mutation => "mutation",
                OperationKind::Subscription => "subscription",
            }
            .to_string(),
            variables: lower_variables(schema, operation),
            id: format!("{:x}", md5::compute(text.as_bytes())),
            text,
            reader,
            normalization: lower_selections(schema, &operation.selections),
        });
    }
    plan.operations
        .sort_by(|left, right| left.name.cmp(&right.name));
    plan
}

fn lower_fragment(schema: &SDLSchema, fragment: &FragmentDefinition) -> FragmentPlan {
    FragmentPlan {
        name: fragment.name.item.0.lookup().to_string(),
        type_condition: schema
            .get_type_name(fragment.type_condition)
            .lookup()
            .to_string(),
        arguments: fragment
            .variable_definitions
            .iter()
            .map(|variable| VariablePlan {
                name: variable.name.item.0.lookup().to_string(),
                type_name: type_reference_name(schema, &variable.type_),
            })
            .collect(),
        reader: lower_selections(schema, &fragment.selections),
    }
}

fn lower_variables(schema: &SDLSchema, operation: &OperationDefinition) -> Vec<VariablePlan> {
    operation
        .variable_definitions
        .iter()
        .map(|variable| VariablePlan {
            name: variable.name.item.0.lookup().to_string(),
            type_name: type_reference_name(schema, &variable.type_),
        })
        .collect()
}

fn lower_selections(schema: &SDLSchema, selections: &[Selection]) -> Vec<SelectionPlan> {
    selections
        .iter()
        .map(|selection| match selection {
            Selection::ScalarField(field) => {
                let definition = schema.field(field.definition.item);
                SelectionPlan::Scalar {
                    name: definition.name.item.lookup().to_string(),
                    alias: field.alias.map(|alias| alias.item.lookup().to_string()),
                    type_name: type_reference_name(schema, &definition.type_),
                    storage_key: storage_key(definition.name.item.lookup(), &field.arguments),
                }
            }
            Selection::LinkedField(field) => {
                let definition = schema.field(field.definition.item);
                SelectionPlan::Linked {
                    name: definition.name.item.lookup().to_string(),
                    alias: field.alias.map(|alias| alias.item.lookup().to_string()),
                    type_name: type_reference_name(schema, &definition.type_),
                    storage_key: storage_key(definition.name.item.lookup(), &field.arguments),
                    plural: definition.type_.is_list(),
                    selections: lower_selections(schema, &field.selections),
                }
            }
            Selection::InlineFragment(inline) => SelectionPlan::Inline {
                type_condition: inline
                    .type_condition
                    .map(|type_| schema.get_type_name(type_).lookup().to_string()),
                selections: lower_selections(schema, &inline.selections),
            },
            Selection::FragmentSpread(spread) => SelectionPlan::Spread {
                fragment: spread.fragment.item.0.lookup().to_string(),
            },
            Selection::Condition(condition) => SelectionPlan::Condition {
                variable: match &condition.value {
                    ConditionValue::Variable(variable) => {
                        Some(variable.name.item.0.lookup().to_string())
                    }
                    ConditionValue::Constant(_) => None,
                },
                passing: condition.passing_value,
                selections: lower_selections(schema, &condition.selections),
            },
        })
        .collect()
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

fn render_value(value: &graphql_ir::Value) -> String {
    match value {
        graphql_ir::Value::Constant(constant) => format!("{constant:?}"),
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

fn type_reference_name(schema: &SDLSchema, type_: &TypeReference<Type>) -> String {
    match type_ {
        TypeReference::Named(named) => schema.get_type_name(*named).lookup().to_string(),
        TypeReference::NonNull(inner) => format!("{}!", type_reference_name(schema, inner)),
        TypeReference::List(inner) => format!("[{}]", type_reference_name(schema, inner)),
    }
}
