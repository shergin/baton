//! Lowering: Relay's reader and normalization programs into the plan IR.
//! Everything here reads Relay's types and writes Baton's.

use std::collections::BTreeMap;

use common::{Diagnostic, DirectiveName, NamedItem, SourceLocationKey};
use graphql_ir::{
    Condition, ConditionValue, Field, FragmentDefinition, FragmentSpread, InlineFragment,
    LinkedField, OperationDefinition, ScalarField, Selection,
};
use graphql_syntax::OperationKind as SyntaxOperationKind;
use graphql_text_printer::{PrinterOptions, print_full_operation};
use intern::Lookup;
use intern::string_key::Intern;
use relay_transforms::CLIENT_EXTENSION_DIRECTIVE_NAME;
use relay_transforms::{
    CATCH_DIRECTIVE_NAME, CHILDREN_CAN_BUBBLE_METADATA_KEY, CatchMetadataDirective, CatchTo,
    FragmentAliasMetadata, Programs, RefetchableMetadata, RequiredAction as RelayRequiredAction,
    RequiredMetadataDirective, extract_connection_metadata_from_directive,
    extract_handle_field_directives, extract_values_from_handle_field_directive,
};
use schema::{SDLSchema, Schema, Type, TypeReference};

use super::identity::Keys;
use super::plan::{
    ArgumentPlan, ArgumentValuePlan, CatchPlan, CatchTarget, ConditionClass, ConnectionPlan,
    ConstantPlan, EditKind, EditPlan, FragmentPlan, InputFieldPlan, LookupArgumentPlan, LookupPlan,
    OperationKind, OperationPlan, Origin, PaginationPlan, Plan, RefetchPlan, RequiredAction,
    RequiredPlan, SelectionPlan, StorageKeyPlan, TypeKind, TypePlan, VariablePlan,
};

use crate::config::Config;

/// Marks the fields of the input objects whose type reaches the input they
/// belong to through other inputs' fields, outside lists: a Swift value type
/// cannot contain itself, so the generated struct boxes such a field. Every
/// edge of a cycle is marked, so no cycle is left whole.
fn mark_indirect(inputs: &mut BTreeMap<String, Vec<InputFieldPlan>>) {
    // The inputs each input's fields name directly, outside lists.
    let direct: BTreeMap<String, Vec<String>> = inputs
        .iter()
        .map(|(name, fields)| {
            let named = fields
                .iter()
                .filter(|field| {
                    field.type_.base_kind() == TypeKind::InputObject && !field.type_.is_list()
                })
                .map(|field| field.type_.base_name().to_string())
                .collect();
            (name.clone(), named)
        })
        .collect();
    fn reaches(
        from: &str,
        target: &str,
        direct: &BTreeMap<String, Vec<String>>,
        seen: &mut Vec<String>,
    ) -> bool {
        if from == target {
            return true;
        }
        if seen.iter().any(|name| name == from) {
            return false;
        }
        seen.push(from.to_string());
        direct
            .get(from)
            .map(|named| named.iter().any(|next| reaches(next, target, direct, seen)))
            .unwrap_or(false)
    }
    for (name, fields) in inputs.iter_mut() {
        for field in fields.iter_mut() {
            if field.type_.base_kind() != TypeKind::InputObject || field.type_.is_list() {
                continue;
            }
            field.indirect = reaches(field.type_.base_name(), name, &direct, &mut Vec::new());
        }
    }
}

/// Which program a selection set comes from. The reader reads a connection
/// through Relay's handle key and carries the required and catch metadata; the
/// normalization writes the server field, carries the edit beside it, and
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
    /// The key fields of each keyed object type.
    keys: &'a Keys,
    /// Errors found while lowering, reported together at the end.
    diagnostics: std::cell::RefCell<Vec<Diagnostic>>,
    /// The enums the documents' types name, with their values.
    enums: std::cell::RefCell<BTreeMap<String, Vec<String>>>,
    /// The input objects the documents' variables name, with their fields.
    inputs: std::cell::RefCell<BTreeMap<String, Vec<InputFieldPlan>>>,
}

fn directive_name(name: &str) -> DirectiveName {
    DirectiveName(name.intern())
}

/// Lowers Relay's reader and normalization programs into the plan IR.
pub(super) fn lower(
    schema: &SDLSchema,
    programs: &Programs,
    config: &Config,
    keys: &Keys,
) -> Result<Plan, Vec<Diagnostic>> {
    let lowering = Lowering {
        schema,
        programs,
        config,
        keys,
        diagnostics: std::cell::RefCell::new(Vec::new()),
        enums: std::cell::RefCell::new(BTreeMap::new()),
        inputs: std::cell::RefCell::new(BTreeMap::new()),
    };
    let mut plan = Plan::default();
    for fragment in programs.reader.fragments() {
        plan.fragments.push(lowering.fragment(fragment));
    }
    plan.fragments
        .sort_by(|left, right| left.name.cmp(&right.name));

    for operation in programs.normalization.operations() {
        plan.operations.push(lowering.operation(operation));
    }
    plan.operations
        .sort_by(|left, right| left.name.cmp(&right.name));
    plan.enums = lowering.enums.borrow().clone();
    plan.inputs = lowering.inputs.borrow().clone();
    mark_indirect(&mut plan.inputs);
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

impl Origin {
    /// The origin of a name at `location`; none for a name Relay generated.
    fn of(location: common::Location) -> Option<Origin> {
        let (path, document) = match location.source_location() {
            SourceLocationKey::Embedded { path, index } => (path, usize::from(index)),
            SourceLocationKey::Standalone { path } => (path, 0),
            SourceLocationKey::Generated => return None,
        };
        Some(Origin {
            path: path.lookup().to_string(),
            document,
            offset: location.span().start,
        })
    }
}

impl Lowering<'_> {
    fn fragment(&self, fragment: &FragmentDefinition) -> FragmentPlan {
        let mut plan = FragmentPlan {
            name: fragment.name.item.0.lookup().to_string(),
            origin: Origin::of(fragment.name.location),
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

    /// An operation: its reader and normalization selections, its text and
    /// id, and the policies the runtime reads from it.
    fn operation(&self, operation: &OperationDefinition) -> OperationPlan {
        let name = operation.name.item.0.lookup();
        let root_type = self
            .schema
            .get_type_name(operation.type_)
            .lookup()
            .to_string();
        let reader_operation = self.programs.reader.operation(operation.name.item);
        let reader = reader_operation
            .map(|reader_operation| {
                self.selections(
                    &reader_operation.selections,
                    operation.type_,
                    Side::Reader,
                    false,
                    false,
                )
            })
            .unwrap_or_else(|| {
                self.internal(
                    "the reader program has no such operation",
                    operation.name.location,
                );
                Vec::new()
            });
        let text = self
            .programs
            .operation_text
            .operation(operation.name.item)
            .map(|text_operation| {
                print_full_operation(
                    &self.programs.operation_text,
                    text_operation,
                    PrinterOptions::default(),
                )
            })
            .unwrap_or_else(|| {
                // Relay's text transforms leave the client fields out and drop
                // an operation left with none: one of client fields alone
                // would ask a server for nothing.
                self.diagnostics.borrow_mut().push(Diagnostic::error(
                    format!(
                        "`{}` selects client fields only; a server answers one field at least, so select a server field beside them",
                        operation.name.item
                    ),
                    operation.name.location,
                ));
                String::new()
            })
            // Trimmed once, here: the id is the hash of the very text the
            // app holds and sends.
            .trim_end()
            .to_string();
        let mut normalization = self.selections(
            &operation.selections,
            operation.type_,
            Side::Normalization,
            false,
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
            self.diagnostics.borrow_mut().push(Diagnostic::error(
                format!(
                    "`@defer` in the {} `{name}`: its response arrives in one part, so nothing can be deferred",
                    operation.kind
                ),
                operation.name.location,
            ));
        }
        OperationPlan {
            name: name.to_string(),
            origin: Origin::of(operation.name.location),
            source: operation.name.location.source_location().path().to_string(),
            document: document_index(operation.name.location),
            kind: match operation.kind {
                SyntaxOperationKind::Query => OperationKind::Query,
                SyntaxOperationKind::Mutation => OperationKind::Mutation,
                SyntaxOperationKind::Subscription => OperationKind::Subscription,
            },
            root_type,
            variables: self.variables(&operation.variable_definitions),
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
            error_behavior: self
                .config
                .on_error
                .map(|behavior| behavior.swift_case().to_string()),
            cache_expiration: self.cache_expiration(operation),
            reader,
            normalization,
        }
    }

    /// `@cacheExpiration(seconds:)`: a constant of the operation, which the
    /// store reads with the operation's age. The schema types it `Int!`, so a
    /// variable is the one other value Relay admits.
    fn cache_expiration(&self, operation: &OperationDefinition) -> Option<f64> {
        let directive = operation
            .directives
            .named(directive_name("cacheExpiration"))?;
        let argument = directive
            .arguments
            .named(common::ArgumentName("seconds".intern()))?;
        match &argument.value.item {
            graphql_ir::Value::Constant(graphql_ir::ConstantValue::Int(seconds)) => {
                Some(*seconds as f64)
            }
            graphql_ir::Value::Constant(graphql_ir::ConstantValue::Float(seconds)) => {
                Some(seconds.as_float())
            }
            _ => {
                self.diagnostics.borrow_mut().push(Diagnostic::error(
                    "`@cacheExpiration(seconds:)` takes a constant: how old the data may be is the document's to say, not a variable's",
                    argument.value.location,
                ));
                None
            }
        }
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
                origin: Origin::of(variable.name.location),
                type_: self.type_plan(&variable.type_),
                default_value: variable
                    .default_value
                    .as_ref()
                    .map(|value| constant_plan(&value.item)),
            })
            .collect()
    }

    /// Whether `transient` names the field: a root field whose cell, key and
    /// operations never reach the image.
    fn transient_field(&self, parent_type: Type, definition: &schema::definitions::Field) -> bool {
        let parent_name = self.schema.get_type_name(parent_type).lookup();
        let name = definition.name.item.lookup();
        self.config
            .transient
            .fields
            .iter()
            .any(|field| field == &format!("{parent_name}.{name}"))
    }

    /// The key fields of each keyed concrete type behind the type: the type
    /// itself, or, for an interface or union, every member with a key; the
    /// payload's `__typename` then names the type to key by.
    fn keys_of(&self, type_: Type) -> BTreeMap<String, Vec<String>> {
        let mut keys = BTreeMap::new();
        for name in self.possible_types(type_) {
            if let Some(key) = self.keys.of(&name) {
                keys.insert(name, key.to_vec());
            }
        }
        keys
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
    fn edit(&self, directives: &[graphql_ir::Directive]) -> Option<EditPlan> {
        let directive = extract_handle_field_directives(directives).next()?;
        let values = extract_values_from_handle_field_directive(directive);
        let name = values.handle.lookup();
        if name == "connection" {
            return None;
        }
        let Some(kind) = EditKind::of(name) else {
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
        Some(EditPlan {
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
        client: bool,
    ) -> Vec<SelectionPlan> {
        selections
            .iter()
            .map(|selection| match selection {
                Selection::ScalarField(field) => {
                    self.scalar_field(field, parent_type, caught, client)
                }
                Selection::LinkedField(field) => {
                    self.linked_field(field, parent_type, side, caught, client)
                }
                Selection::InlineFragment(inline) => {
                    self.inline_fragment(inline, parent_type, side, caught, client)
                }
                Selection::FragmentSpread(spread) => {
                    // Relay inlines every spread of the normalization program,
                    // and the normalization collector skips what it would not
                    // know how to write.
                    if side == Side::Normalization {
                        self.internal(
                            "a fragment spread reached the normalization program, which inlines them",
                            spread.fragment.location,
                        );
                    }
                    self.fragment_spread(spread)
                }
                Selection::Condition(condition) => {
                    self.condition(condition, parent_type, side, caught, client)
                }
            })
            .collect()
    }

    /// A list of lists is refused: the plan says of a field's type that it
    /// is a list or not, so a deeper type would be lowered to a flat list
    /// and read wrong. The refusal stands until the plan carries a type
    /// that can say the depth.
    fn refuse_nested_list(&self, field: &impl Field, definition: &schema::definitions::Field) {
        if list_depth(&definition.type_) < 2 {
            return;
        }
        self.diagnostics.borrow_mut().push(Diagnostic::error(
            format!(
                "`{}` is a list of lists, `{}`, which the runtime cannot hold; leave it out of the selection",
                definition.name.item.lookup(),
                self.type_reference_name(&definition.type_)
            ),
            field.alias_or_name_location(),
        ));
    }

    fn scalar_field(
        &self,
        field: &ScalarField,
        parent_type: Type,
        caught: bool,
        client: bool,
    ) -> SelectionPlan {
        let definition = self.schema.field(field.definition.item);
        self.refuse_nested_list(field, definition);
        let field_caught = caught || self.is_caught(&field.directives);
        SelectionPlan::Scalar {
            client: client || definition.is_extension,
            extension: definition.is_extension,
            transient: self.transient_field(parent_type, definition),
            name: definition.name.item.lookup().to_string(),
            alias: field.alias.map(|alias| alias.item.lookup().to_string()),
            origin: Origin::of(field.alias_or_name_location()),
            type_: self.type_plan(&definition.type_),
            non_null: self.non_null(definition),
            semantic_non_null: self.semantic_non_null(definition),
            storage_key: storage_key(definition.name.item.lookup(), &field.arguments),
            edit: self.edit(&field.directives),
            required: self.required(&field.directives),
            catch: self.catch(&field.directives),
            caught: field_caught,
        }
    }

    /// A linked field, its lookup when `baton.json` names one, and its
    /// connection when it is one.
    fn linked_field(
        &self,
        field: &LinkedField,
        parent_type: Type,
        side: Side,
        caught: bool,
        client: bool,
    ) -> SelectionPlan {
        let definition = self.schema.field(field.definition.item);
        let client = client || definition.is_extension;
        self.refuse_nested_list(field, definition);
        let target = definition.type_.inner();
        let name = definition.name.item.lookup();
        let lookup = self.lookup(field, name, parent_type, target);
        let edit = self.edit(&field.directives);
        let connection = self.connection(field, target, side);
        // The reader reads a connection through its handle's key.
        let field_storage_key = match (&connection, side) {
            (Some(connection), Side::Reader) => connection.storage_key.clone(),
            _ => storage_key(name, &field.arguments),
        };
        let field_caught = caught || self.is_caught(&field.directives);
        SelectionPlan::Linked {
            name: name.to_string(),
            alias: field.alias.map(|alias| alias.item.lookup().to_string()),
            origin: Origin::of(field.alias_or_name_location()),
            type_: self.type_plan(&definition.type_),
            non_null: self.non_null(definition),
            semantic_non_null: self.semantic_non_null(definition),
            keys: self.keys_of(target),
            is_abstract: target.is_abstract_type(),
            possible_types: self.possible_types(target),
            storage_key: field_storage_key,
            lookup,
            connection,
            edit,
            required: self.required(&field.directives),
            catch: self.catch(&field.directives),
            caught: field_caught,
            client,
            extension: definition.is_extension,
            transient: self.transient_field(parent_type, definition),
            bubbles: self.bubbles(&field.directives),
            selections: self.selections(&field.selections, target, side, field_caught, client),
        }
    }

    /// The lookup `baton.json` names for the field, and the value the
    /// selection passes its argument: an error when it passes none, or a
    /// list or an object.
    fn lookup(
        &self,
        field: &LinkedField,
        name: &str,
        parent_type: Type,
        target: Type,
    ) -> Option<LookupPlan> {
        let parent_name = self.schema.get_type_name(parent_type).lookup();
        self
            .config
            .lookups
            .iter()
            .find(|lookup| lookup.field == format!("{parent_name}.{name}"))
            .and_then(|lookup| {
                let mut arguments = Vec::new();
                for argument_name in lookup.arguments() {
                    let argument = field
                        .arguments
                        .named(common::ArgumentName(argument_name.intern()));
                    let Some(argument) = argument else {
                        self.diagnostics.borrow_mut().push(Diagnostic::error(
                            format!(
                                "baton.json looks `{parent_name}.{name}` up by `{argument_name}`, which this selection does not pass"
                            ),
                            field.alias_or_name_location(),
                        ));
                        return None;
                    };
                    let value = argument_value_plan(&argument.value.item);
                    if matches!(value, ArgumentValuePlan::List(_) | ArgumentValuePlan::Object(_)) {
                        self.diagnostics.borrow_mut().push(Diagnostic::error(
                            format!(
                                "the lookup argument `{argument_name}` of `{parent_name}.{name}` must be a variable or a constant"
                            ),
                            argument.value.location,
                        ));
                        return None;
                    }
                    arguments.push(LookupArgumentPlan {
                        name: argument_name.to_string(),
                        value,
                    });
                }
                // Without a type, one value is probed as the id of each type
                // the field returns, among those one value keys.
                let possible_types = self
                    .possible_types(target)
                    .into_iter()
                    .filter(|type_name| {
                        lookup.type_name.is_some()
                            || self.keys.of(type_name).is_some_and(|key| key.len() == 1)
                    })
                    .collect();
                Some(LookupPlan {
                    type_name: lookup.type_name.clone(),
                    possible_types,
                    arguments,
                })
            })
    }

    /// The connection of a field with `@connection`: the client record its
    /// pages merge into, the types of its edges and page info, and the
    /// cursors that pick the merge. None for any other field.
    fn connection(&self, field: &LinkedField, target: Type, side: Side) -> Option<ConnectionPlan> {
        let values = extract_handle_field_directives(&field.directives)
            .next()
            .map(extract_values_from_handle_field_directive)
            .filter(|values| values.handle.lookup() == "connection")?;
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
        let cursor = |argument: &str| {
            field
                .arguments
                .named(common::ArgumentName(argument.intern()))
                .map(|argument| argument_value_plan(&argument.value.item))
                .filter(|value| !matches!(value, ArgumentValuePlan::Constant(ConstantPlan::Null)))
        };
        Some(ConnectionPlan {
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
        })
    }

    fn inline_fragment(
        &self,
        inline: &InlineFragment,
        parent_type: Type,
        side: Side,
        caught: bool,
        client: bool,
    ) -> SelectionPlan {
        // Relay groups a selection's client fields under an inline fragment
        // it marks; everything under it is the client's.
        let client = client
            || inline
                .directives
                .named(*CLIENT_EXTENSION_DIRECTIVE_NAME)
                .is_some();
        // An alias that names what the selection is named by
        // anyway is no alias.
        let explicit = FragmentAliasMetadata::find(&inline.directives).filter(|metadata| {
            let default: Option<String> = if metadata.wraps_spread {
                match inline.selections.first() {
                    Some(Selection::FragmentSpread(spread)) => {
                        Some(spread.fragment.item.0.lookup().to_string())
                    }
                    _ => None,
                }
            } else {
                inline
                    .type_condition
                    .map(|type_| self.schema.get_type_name(type_).lookup().to_string())
            };
            default.as_deref() != Some(metadata.alias.item.lookup())
        });
        let alias = explicit.map(|metadata| metadata.alias.item.lookup().to_string());
        let deferred = inline
            .directives
            .named(directive_name("defer"))
            .and_then(|directive| {
                directive
                    .arguments
                    .named(common::ArgumentName("label".intern()))
            })
            .and_then(|label| match &label.value.item {
                graphql_ir::Value::Constant(graphql_ir::ConstantValue::String(text)) => {
                    Some(text.lookup().to_string())
                }
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
            origin: explicit.and_then(|metadata| Origin::of(metadata.alias.location)),
            deferred,
            catch: self.catch(&inline.directives),
            bubbles: self.bubbles(&inline.directives),
            selections: self.selections(
                &inline.selections,
                inline.type_condition.unwrap_or(parent_type),
                side,
                inline_caught,
                client,
            ),
        }
    }

    fn fragment_spread(&self, spread: &FragmentSpread) -> SelectionPlan {
        SelectionPlan::Spread {
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
                    self.internal(
                        "the spread names a fragment the reader program lacks",
                        spread.fragment.location,
                    );
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
        }
    }

    fn condition(
        &self,
        condition: &Condition,
        parent_type: Type,
        side: Side,
        caught: bool,
        client: bool,
    ) -> SelectionPlan {
        SelectionPlan::Condition {
            variable: match &condition.value {
                ConditionValue::Variable(variable) => {
                    Some(variable.name.item.0.lookup().to_string())
                }
                ConditionValue::Constant(_) => None,
            },
            passing: condition.passing_value,
            selections: self.selections(&condition.selections, parent_type, side, caught, client),
        }
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

    /// A type as the schema writes it, with nullability at every level: the
    /// one shape the reader side and the normalization side are lowered from.
    fn type_plan(&self, type_: &TypeReference<Type>) -> TypePlan {
        self.type_plan_wrapped(type_, false)
    }

    fn type_plan_wrapped(&self, type_: &TypeReference<Type>, non_null: bool) -> TypePlan {
        match type_ {
            TypeReference::NonNull(inner) => self.type_plan_wrapped(inner, true),
            TypeReference::List(inner) => TypePlan::List {
                element: Box::new(self.type_plan_wrapped(inner, false)),
                non_null,
            },
            TypeReference::Named(named) => {
                let name = self.schema.get_type_name(*named).lookup().to_string();
                let kind = self.type_kind(*named);
                if let Type::Enum(id) = named {
                    self.enums
                        .borrow_mut()
                        .entry(name.clone())
                        .or_insert_with(|| {
                            self.schema
                                .enum_(*id)
                                .values
                                .iter()
                                .map(|value| value.value.lookup().to_string())
                                .collect()
                        });
                }
                if let Type::InputObject(id) = named {
                    // The entry goes in before its fields are built, so an
                    // input that names itself through a field ends here.
                    let seen = self.inputs.borrow().contains_key(&name);
                    if !seen {
                        self.inputs.borrow_mut().insert(name.clone(), Vec::new());
                        let fields: Vec<InputFieldPlan> = self
                            .schema
                            .input_object(*id)
                            .fields
                            .iter()
                            .map(|argument| InputFieldPlan {
                                name: argument.name.item.0.lookup().to_string(),
                                type_: self.type_plan(&argument.type_),
                                indirect: false,
                            })
                            .collect();
                        self.inputs.borrow_mut().insert(name.clone(), fields);
                    }
                }
                let mapped = (kind == TypeKind::CustomScalar)
                    .then(|| self.config.custom_scalar_types.get(&name).cloned())
                    .flatten();
                TypePlan::Named {
                    name,
                    kind,
                    non_null,
                    mapped,
                }
            }
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

/// How many lists a type wraps its base in: 0 for `Int!`, 1 for `[Int!]!`,
/// 2 for `[[Int!]!]!`.
fn list_depth(type_: &TypeReference<Type>) -> usize {
    match type_ {
        TypeReference::Named(_) => 0,
        TypeReference::NonNull(inner) => list_depth(inner),
        TypeReference::List(inner) => 1 + list_depth(inner),
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
