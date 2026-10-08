//! The normalization plan as Kotlin: each selection a `Selection` of its
//! own, built lazily in the operation's plan object, so that no initializer
//! grows past the size the JVM allows a method and a recurring selection is
//! built once.

use std::collections::HashMap;
use std::fmt::Write as _;

use super::literal::{keyed_types_reference, slot_path, string_literal, type_reference};
use super::shared::connection_member;
use crate::decide::{
    self, Guard, NormalizationField, NormalizationKind, NormalizationSelection, Shared, SlotRef,
};
use crate::kotlin_names::slot_name;
use crate::pipeline::{
    ArgumentValuePlan, ConnectionPlan, ConstantPlan, EditKind, EditPlan, LookupPlan,
    StorageKeyPlan, TypeKind,
};

/// The selections of a normalization plan, each written once, numbered
/// from the root as the Swift plan's are.
pub(super) struct PlanSelections<'a> {
    /// The initializer of each declaration, in the order written: a
    /// selection before any that refers to it, so the root is last.
    initializers: Vec<Initializer>,
    /// The index of each initializer written so far: an equal initializer
    /// is an equal selection.
    indices: HashMap<Initializer, usize>,
    /// The depth the initializers are written at.
    depth: usize,
    shared: &'a Shared,
}

/// A selection's initializer before its declarations are numbered: its text,
/// and where in it each selection it refers to goes, by the index that
/// selection was written at.
#[derive(Clone, PartialEq, Eq, Hash)]
struct Initializer {
    text: String,
    references: Vec<(usize, usize)>,
}

impl<'a> PlanSelections<'a> {
    /// The selections of the plan rooted at `root`, for initializers written
    /// at `depth`.
    pub(super) fn new(
        root: &NormalizationSelection,
        depth: usize,
        shared: &'a Shared,
    ) -> PlanSelections<'a> {
        let mut selections = PlanSelections {
            initializers: Vec::new(),
            indices: HashMap::new(),
            depth,
            shared,
        };
        selections.reference(root);
        selections
    }

    /// The name of the root selection, the plan's.
    pub(super) fn root() -> String {
        PlanSelections::name(0)
    }

    /// Each declaration's name and initializer, the root first.
    pub(super) fn declarations(&self) -> Vec<(String, String)> {
        let last = self.initializers.len() - 1;
        self.initializers
            .iter()
            .rev()
            .enumerate()
            .map(|(number, initializer)| {
                let mut text = String::with_capacity(initializer.text.len());
                let mut written = 0;
                for (offset, index) in &initializer.references {
                    text.push_str(&initializer.text[written..*offset]);
                    text.push_str(&PlanSelections::name(last - index));
                    written = *offset;
                }
                text.push_str(&initializer.text[written..]);
                (PlanSelections::name(number), text)
            })
            .collect()
    }

    /// The name of the declaration numbered `number` from the root, a
    /// member of the operation's plan object, where no variable and no lens
    /// reaches.
    fn name(number: usize) -> String {
        format!("selection{number}")
    }

    fn reference(&mut self, selection: &NormalizationSelection) -> usize {
        let mut initializer = Initializer {
            text: String::new(),
            references: Vec::new(),
        };
        self.write_selection(&mut initializer, selection);
        if let Some(index) = self.indices.get(&initializer) {
            return *index;
        }
        let index = self.initializers.len();
        self.indices.insert(initializer.clone(), index);
        self.initializers.push(initializer);
        index
    }

    /// Writes a selection: its fields when every type reads the same, else
    /// its variants.
    fn write_selection(&mut self, output: &mut Initializer, selection: &NormalizationSelection) {
        let pad = "    ".repeat(self.depth);
        let _ = write!(
            output.text,
            "Selection(type = {}, key = {}, isAbstract = {}",
            type_reference(&selection.type_name),
            key_expression(&selection.key),
            selection.is_abstract
        );
        if !selection.memberships.is_empty() {
            let answers: Vec<String> = selection
                .memberships
                .iter()
                .map(|(key, condition)| {
                    format!(
                        "Selection.MembershipAnswer({}, {})",
                        string_literal(key),
                        type_reference(condition)
                    )
                })
                .collect();
            let _ = write!(
                output.text,
                ", memberships = listOf({})",
                answers.join(", ")
            );
        }
        if let [only] = selection.variants.as_slice()
            && only.types.is_none()
            && selection.memberships.is_empty()
        {
            output.text.push_str(", fields = listOf(");
            self.plan_fields(output, only.slot_type(selection), &only.fields, 0);
            output.text.push_str("))");
            return;
        }
        output.text.push_str(", variants = listOf(");
        for variant in &selection.variants {
            let types = match &variant.types {
                Some(types) => {
                    let names: Vec<String> =
                        types.iter().map(|name| type_reference(name)).collect();
                    format!("listOf({})", names.join(", "))
                }
                None => "null".to_string(),
            };
            let key = variant
                .key
                .as_ref()
                .map(|key| format!(", key = {}", key_expression(key)))
                .unwrap_or_default();
            let condition = variant
                .condition
                .as_ref()
                .map(|condition| format!(", condition = {}", type_reference(condition)))
                .unwrap_or_default();
            let _ = write!(
                output.text,
                "\n{pad}    Selection.Variant(types = {types}{key}{condition}, fields = listOf("
            );
            self.plan_fields(output, variant.slot_type(selection), &variant.fields, 1);
            output.text.push_str(")),");
        }
        let _ = write!(output.text, "\n{pad}))");
    }

    /// The fields of one variant, their slots on `type_name`, `indent`
    /// levels inside the initializer.
    fn plan_fields(
        &mut self,
        output: &mut Initializer,
        type_name: &str,
        fields: &[NormalizationField],
        indent: usize,
    ) {
        let pad = "    ".repeat(self.depth + indent);
        for field in fields {
            let _ = write!(output.text, "\n{pad}    ");
            let slot = plan_key(type_name, &field.key);
            let edit_argument = field
                .edit
                .as_ref()
                .map(|edit| format!(", edit = {}", edit_expression(edit)))
                .unwrap_or_default();
            let deferred_argument = field
                .deferred
                .as_ref()
                .map(|label| format!(", deferred = {}", string_literal(label)))
                .unwrap_or_default();
            let caught_argument = if field.caught { ", caught = true" } else { "" };
            let client_argument = if field.client { ", client = true" } else { "" };
            let transient_argument = if field.transient {
                ", transient = true"
            } else {
                ""
            };
            let guards_argument = guards_expression(&field.guards);
            let flags = format!(
                "{edit_argument}{deferred_argument}{caught_argument}{client_argument}{transient_argument}{guards_argument}"
            );
            match &field.kind {
                NormalizationKind::Scalar { type_ } => {
                    let kind = match type_.base_kind() {
                        TypeKind::Int => "INT",
                        TypeKind::Float => "DOUBLE",
                        TypeKind::Boolean => "BOOL",
                        TypeKind::String | TypeKind::Id | TypeKind::Enum => "STRING",
                        _ => "CUSTOM",
                    };
                    let _ = write!(
                        output.text,
                        "PlanField.scalar({}, key = {slot}, kind = ScalarKind.{kind}, list = {}{flags}),",
                        string_literal(&field.response_key),
                        type_.is_list()
                    );
                }
                NormalizationKind::Linked {
                    plural,
                    lookup,
                    connection,
                    selection,
                } => {
                    let lookup_argument = lookup
                        .as_ref()
                        .map(|lookup| {
                            format!(
                                ", lookup = {}",
                                lookup_expression(lookup, &selection.type_name)
                            )
                        })
                        .unwrap_or_default();
                    let connection_argument = connection
                        .as_ref()
                        .map(|connection| {
                            format!(
                                ", connection = {}",
                                self.connection_expression(
                                    type_name,
                                    &selection.type_name,
                                    connection
                                )
                            )
                        })
                        .unwrap_or_default();
                    let _ = write!(
                        output.text,
                        "PlanField.linked({}, key = {slot}, plural = {plural}{lookup_argument}{connection_argument}{flags}, selection = ",
                        string_literal(&field.response_key)
                    );
                    let index = self.reference(selection);
                    output.references.push((output.text.len(), index));
                    output.text.push_str("),");
                }
            }
        }
        if !fields.is_empty() {
            let _ = write!(output.text, "\n{pad}");
        }
    }

    /// The plan's description of a connection: the client key on the
    /// parent type, the connection type's slots the shared file declares,
    /// and the cursors that pick the merge mode.
    fn connection_expression(
        &self,
        parent_type: &str,
        connection_type: &str,
        connection: &ConnectionPlan,
    ) -> String {
        let key = plan_key(parent_type, &connection.storage_key);
        let cursor = |value: &Option<ArgumentValuePlan>, label: &str| match value {
            Some(ArgumentValuePlan::Variable(name)) => {
                format!(
                    ", {label} = ConnectionCursor.Variable({})",
                    string_literal(name)
                )
            }
            Some(_) => format!(", {label} = ConnectionCursor.Literal"),
            None => String::new(),
        };
        format!(
            "ConnectionPlan(key = {key}, slots = Slots.{}.{}{}{})",
            slot_name(connection_type),
            connection_member(connection_type, self.shared),
            cursor(&connection.after, "after"),
            cursor(&connection.before, "before")
        )
    }
}

/// The response keys of the fields that key a record.
fn key_expression(key: &[String]) -> String {
    let fields: Vec<String> = key.iter().map(|field| string_literal(field)).collect();
    format!("listOf({})", fields.join(", "))
}

/// The key inside a plan: a fixed slot, or the key with variables an owner
/// renders.
fn plan_key(type_name: &str, storage_key: &StorageKeyPlan) -> String {
    let slot = SlotRef::new(type_name, storage_key);
    if slot.has_variables() {
        format!("StorageKey.Dynamic({})", slot_path(&slot))
    } else {
        format!("StorageKey.Fixed({})", slot_path(&slot))
    }
}

/// The lookup: the entity type, or for a field that returns an interface
/// or union the members one value keys, and the arguments' values in the
/// key's order, each a variable or a constant written as a record key
/// writes it: a string as itself, anything else as JSON.
fn lookup_expression(lookup: &LookupPlan, base_type: &str) -> String {
    let types = match &lookup.type_name {
        Some(type_name) => format!("type = {}", type_reference(type_name)),
        None => format!(
            "type = null, possibleTypes = {}",
            keyed_types_reference(base_type)
        ),
    };
    let parts: Vec<String> = lookup
        .arguments
        .iter()
        .map(|argument| match &argument.value {
            ArgumentValuePlan::Variable(name) => {
                format!("Lookup.Key.Variable({})", string_literal(name))
            }
            ArgumentValuePlan::Constant(ConstantPlan::String(text)) => {
                format!("Lookup.Key.Literal({})", string_literal(text))
            }
            ArgumentValuePlan::Constant(constant) => format!(
                "Lookup.Key.Literal({})",
                string_literal(&decide::constant_json(constant))
            ),
            ArgumentValuePlan::List(_) | ArgumentValuePlan::Object(_) => {
                unreachable!("lowering rejects a lookup argument that is a list or an object")
            }
        })
        .collect();
    format!("Lookup({types}, key = listOf({}))", parts.join(", "))
}

/// The plan's description of an edge directive.
fn edit_expression(edit: &EditPlan) -> String {
    let connections = match &edit.connections {
        Some(ArgumentValuePlan::Variable(name)) => format!(
            ", connections = Edit.Connections.Variable({})",
            string_literal(name)
        ),
        Some(ArgumentValuePlan::Constant(ConstantPlan::List(items))) => format!(
            ", connections = Edit.Connections.Literal(listOf({}))",
            items
                .iter()
                .map(|item| match item {
                    ConstantPlan::String(text) => string_literal(text),
                    other => string_literal(&constant_text(other)),
                })
                .collect::<Vec<_>>()
                .join(", ")
        ),
        Some(ArgumentValuePlan::Constant(other)) => format!(
            ", connections = Edit.Connections.Literal(listOf({}))",
            string_literal(&constant_text(other))
        ),
        Some(ArgumentValuePlan::List(_) | ArgumentValuePlan::Object(_)) => {
            unreachable!("lowering rejects connections given as a list with variables")
        }
        None => String::new(),
    };
    let edge_type = match &edit.edge_type_name {
        Some(name) => format!(", edgeType = {}", type_reference(name)),
        None => String::new(),
    };
    format!(
        "Edit(kind = Edit.Kind.{}{connections}{edge_type})",
        edit_kind(edit.kind)
    )
}

/// The runtime's name for an edit.
fn edit_kind(kind: EditKind) -> &'static str {
    match kind {
        EditKind::AppendEdge => "APPEND_EDGE",
        EditKind::PrependEdge => "PREPEND_EDGE",
        EditKind::AppendNode => "APPEND_NODE",
        EditKind::PrependNode => "PREPEND_NODE",
        EditKind::DeleteEdge => "DELETE_EDGE",
        EditKind::DeleteRecord => "DELETE_RECORD",
    }
}

/// A constant's text, for the rare constant list of connection ids.
fn constant_text(constant: &ConstantPlan) -> String {
    match constant {
        ConstantPlan::Null => "null".to_string(),
        ConstantPlan::Bool(boolean) => boolean.to_string(),
        ConstantPlan::Int(int) => int.to_string(),
        ConstantPlan::Float(float) => float.to_string(),
        ConstantPlan::String(text) => text.clone(),
        ConstantPlan::List(items) => format!(
            "[{}]",
            items
                .iter()
                .map(constant_text)
                .collect::<Vec<_>>()
                .join(",")
        ),
        ConstantPlan::Object(fields) => format!(
            "{{{}}}",
            fields
                .iter()
                .map(|(name, value)| format!("{name}:{}", constant_text(value)))
                .collect::<Vec<_>>()
                .join(",")
        ),
    }
}

/// The `guards` argument of a plan field: none when the field is always
/// fetched.
fn guards_expression(guards: &[Vec<Guard>]) -> String {
    if guards.is_empty() {
        return String::new();
    }
    let alternatives: Vec<String> = guards
        .iter()
        .map(|conjunction| {
            let conditions: Vec<String> = conjunction
                .iter()
                .map(|guard| {
                    format!(
                        "Guard({}, passing = {})",
                        string_literal(&guard.variable),
                        guard.passing
                    )
                })
                .collect();
            format!("listOf({})", conditions.join(", "))
        })
        .collect();
    format!(", guards = listOf({})", alternatives.join(", "))
}
