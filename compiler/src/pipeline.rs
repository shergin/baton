//! The front end: Relay's parser, schema, IR, validations and transforms,
//! driven by Baton and lowered into Baton's plan IR.
//!
//! This file drives Relay's front end and checks what Baton adds to the
//! schema: its lookups and the names of its root types. `plan` is the plan
//! IR, the seam: emitters never see Relay types. `lower` turns Relay's
//! programs into it.

mod identity;
mod lower;
mod plan;

pub use plan::{
    ArgumentPlan, ArgumentValuePlan, CatchTarget, ConditionClass, ConnectionPlan, ConstantPlan,
    EditPlan, FragmentPlan, LookupPlan, OperationKind, OperationPlan, Origin, Plan, RefetchPlan,
    RequiredAction, RequiredPlan, SelectionPlan, StorageKeyPlan, TypeKind, TypePlan, VariablePlan,
};

use std::collections::BTreeMap;
use std::sync::Arc;
use std::time::{Duration, Instant};

use common::{Diagnostic, NoopPerfLogger, SourceLocationKey};
use graphql_ir::{FragmentDefinitionNameSet, Program};
use graphql_syntax::OperationKind as SyntaxOperationKind;
use intern::Lookup;
use intern::string_key::Intern;
use relay_config::ProjectConfig;
use relay_transforms::{
    apply_transforms, disallow_reserved_aliases, disallow_typename_on_root, validate_connections,
    validate_global_variable_names, validate_no_double_underscore_alias,
    validate_no_unselectable_selections, validate_relay_directives, validate_static_args,
    validate_unused_fragment_variables, validate_unused_variables,
};
use schema::{SDLSchema, Schema, Type};

use crate::config::Config;
use crate::documents::Document;

use lower::lower;

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

/// The names the store types its three root records by, whatever the schema
/// calls its root types, as Relay's root record is a `__Root` in any schema.
const ROOT_NAMES: [(SyntaxOperationKind, &str); 3] = [
    (SyntaxOperationKind::Query, "Query"),
    (SyntaxOperationKind::Mutation, "Mutation"),
    (SyntaxOperationKind::Subscription, "Subscription"),
];

/// What Baton adds to the schema for Relay's front end to validate: the one
/// directive that is not Relay's, a query's cache expiration
/// (`docs/decisions/an-operation-states-its-expiration.md`). Declared as an
/// extension, so Relay's text transforms leave it out of the operation text
/// a server receives, as they do its own client directives.
const BATON_DIRECTIVES: &str = "directive @cacheExpiration(seconds: Int!) on QUERY\n";

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
        &[(BATON_DIRECTIVES, SourceLocationKey::Generated)],
    )?;
    let schema = Arc::new(schema);
    timings.schema = started.elapsed();
    let keys = identity::Keys::resolve(&schema, &config.identity, config_location(config))?;
    let errors = validate_lookups(&schema, config, &keys);
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
    let mut programs = apply_transforms(
        &project_config,
        Arc::new(program),
        Arc::new(FragmentDefinitionNameSet::default()),
        Arc::new(NoopPerfLogger),
        None,
        None,
        Vec::new(),
    )?;
    // The key fields join what the server is asked for and what the ingest
    // reads, after Relay's own `id`, and never a lens: a lens reads what its
    // author selected.
    programs.normalization = Arc::new(identity::select_key_fields(&programs.normalization, &keys)?);
    programs.operation_text = Arc::new(identity::select_key_fields(
        &programs.operation_text,
        &keys,
    )?);
    timings.transform = started.elapsed();

    let started = Instant::now();
    let mut plan = lower(&schema, &programs, config, &keys)?;
    plan.root_names = root_names;
    plan.schema_digest = schema_digest(schema_sdl, &config.identity);
    timings.lower = started.elapsed();

    Ok(Compiled { plan, timings })
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

/// The digest an image is versioned by: the schema's text, and the identity
/// configuration when it is not the default, so that records keyed another
/// way are a miss and not a merge of two keyings. The default leaves the
/// digest what it was before identity could be configured.
fn schema_digest(schema_sdl: &str, identity: &crate::config::Identity) -> String {
    if identity.is_default() {
        return format!("{:x}", md5::compute(schema_sdl.as_bytes()));
    }
    let mut text = schema_sdl.to_string();
    text.push_str("\n# identity\n");
    text.push_str(&identity.canonical());
    format!("{:x}", md5::compute(text.as_bytes()))
}

/// Where a diagnostic about the configuration points: the file itself.
fn config_location(config: &Config) -> common::Location {
    common::Location::new(
        SourceLocationKey::standalone(&config.path.to_string_lossy()),
        common::Span::new(0, 0),
    )
}

/// Checks each lookup in `baton.json` against the schema and the keys: the
/// root field exists and takes the arguments, one per field of the type's
/// key in its order, and `type` is the field's concrete return type, omitted
/// only when the field returns an interface or a union, which one argument
/// then finds an id among.
fn validate_lookups(schema: &SDLSchema, config: &Config, keys: &identity::Keys) -> Vec<Diagnostic> {
    let location = config_location(config);
    let mut errors = Vec::new();
    for lookup in &config.lookups {
        let mut fail = |message: String| errors.push(Diagnostic::error(message, location));
        let arguments = lookup.arguments();
        if arguments.is_empty() {
            fail(format!(
                "the lookup `{}` names its argument neither as `argument` nor as `arguments`, or as both",
                lookup.field
            ));
            continue;
        }
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
        for argument in &arguments {
            if field
                .arguments
                .named(common::ArgumentName(argument.intern()))
                .is_none()
            {
                fail(format!(
                    "the lookup `{}` takes `{argument}`, which the field has no argument of",
                    lookup.field
                ));
            }
        }
        let returns = field.type_.inner();
        let returned = schema.get_type_name(returns).lookup();
        match (&lookup.type_name, returns.is_abstract_type()) {
            (Some(named), false) if named == returned => match keys.of(named) {
                Some(key) if key.len() != arguments.len() => fail(format!(
                    "the lookup `{}` passes {} argument{}, but `{named}` is keyed by {} field{}: pass one per field, in the key's order",
                    lookup.field,
                    arguments.len(),
                    if arguments.len() == 1 { "" } else { "s" },
                    key.len(),
                    if key.len() == 1 { "" } else { "s" },
                )),
                Some(_) => {}
                None => fail(format!(
                    "the lookup `{}` names `{named}`, which has no key: a lookup finds an entity",
                    lookup.field
                )),
            },
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
            (None, true) if arguments.len() > 1 => fail(format!(
                "`{}` returns `{returned}`, an interface or union: the lookup finds an id among its types by one argument",
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

#[cfg(test)]
#[path = "tests/pipeline_tests.rs"]
mod tests;
